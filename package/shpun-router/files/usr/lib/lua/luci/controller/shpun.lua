module("luci.controller.shpun", package.seeall)

-- Dependencies
local uci  = require("luci.model.uci").cursor()
local sys  = require "luci.sys"
local fs   = require "nixio.fs"
local http = require "luci.http"
local jsonc = require "luci.jsonc"

-- State files
local STATE_DIR      = "/etc/shpun"
local CODE_FILE      = STATE_DIR .. "/router_code"
local SUB_FILE       = STATE_DIR .. "/subscription_url"
local READY_FILE     = STATE_DIR .. "/vpn_ready"

function index()
  -- API-only (no menu)
  entry({"admin","network","shpun","api","state"},      call("api_state"),      nil).leaf = true
  entry({"admin","network","shpun","api","apply_wan"},  post("api_apply_wan"),  nil).leaf = true
  entry({"admin","network","shpun","api","apply_wifi"}, post("api_apply_wifi"), nil).leaf = true
end

-- Utility: write JSON response
local function write_json(status, obj)
  http.status(status)
  http.prepare_content("application/json")
  http.write_json(obj or {})
end

-- Utility: parse JSON body (returns table or {})
local function parse_body_json()
  local raw = http.content() or ""
  if not raw or raw == "" then return {} end
  local ok, t = pcall(jsonc.parse, raw)
  if ok and type(t) == "table" then return t end
  return {}
end

-- Utility: get parameter from JSON body OR www-form-urlencoded
local function param(name, default)
  local body = parse_body_json()
  if body[name] ~= nil then return body[name] end
  local v = http.formvalue(name)
  if v ~= nil then return v end
  return default
end

-- GET: current state for wizard
function api_state()
  local code  = (fs.readfile(CODE_FILE) or ""):gsub("%s+$","")
  local sub   = fs.readfile(SUB_FILE)   or ""
  local ready = fs.readfile(READY_FILE) or ""
  write_json(200, {
    code             = code,
    has_sub          = (sub ~= ""),
    subscription_url = sub,
    vpn_ready        = (ready ~= "")
  })
end

-- POST: apply WAN settings
function api_apply_wan()
  local proto = tostring(param("proto", "dhcp"))

  if proto == "dhcp" then
    uci:set("network","wan","proto","dhcp")
    uci:delete("network","wan","username")
    uci:delete("network","wan","password")
    uci:delete("network","wan","ipaddr")
    uci:delete("network","wan","netmask")
    uci:delete("network","wan","gateway")
    uci:delete("network","wan","dns")
    uci:delete("network","wan","server")

  elseif proto == "pppoe" then
    local user = tostring(param("user", "") or "")
    local pass = tostring(param("pass", "") or "")
    if user == "" or pass == "" then
      return write_json(400, {ok=0, error="missing pppoe credentials"})
    end
    uci:set("network","wan","proto","pppoe")
    uci:set("network","wan","username",user)
    uci:set("network","wan","password",pass)
    uci:delete("network","wan","ipaddr");   uci:delete("network","wan","netmask")
    uci:delete("network","wan","gateway");  uci:delete("network","wan","dns")
    uci:delete("network","wan","server")

  elseif proto == "static" then
    local ip  = tostring(param("ipaddr", "") or "")
    local msk = tostring(param("netmask","") or "")
    local gw  = tostring(param("gateway","") or "")
    local dns = param("dns","") -- may be string or array
    if ip=="" or msk=="" or gw=="" then
      return write_json(400, {ok=0, error="missing static params"})
    end
    uci:set("network","wan","proto","static")
    uci:set("network","wan","ipaddr",ip)
    uci:set("network","wan","netmask",msk)
    uci:set("network","wan","gateway",gw)
    if type(dns) == "table" then
      uci:set_list("network","wan","dns", dns)
    elseif type(dns) == "string" and dns ~= "" then
      uci:set("network","wan","dns", dns)
    else
      uci:delete("network","wan","dns")
    end
    uci:delete("network","wan","username"); uci:delete("network","wan","password"); uci:delete("network","wan","server")

  elseif proto == "l2tp" then
    local srv  = tostring(param("server","") or "")
    local user = tostring(param("user","") or "")
    local pass = tostring(param("pass","") or "")
    if srv=="" or user=="" or pass=="" then
      return write_json(400, {ok=0, error="missing l2tp params"})
    end
    uci:set("network","wan","proto","l2tp")
    uci:set("network","wan","server",srv)
    uci:set("network","wan","username",user)
    uci:set("network","wan","password",pass)
    uci:set("network","wan","peerdns","1")
    uci:set("network","wan","defaultroute","1")
    uci:delete("network","wan","ipaddr");   uci:delete("network","wan","netmask")
    uci:delete("network","wan","gateway");  uci:delete("network","wan","dns")

  else
    return write_json(400, {ok=0, error="invalid proto"})
  end

  uci:commit("network")
  -- Restart network in background
  sys.call("/etc/init.d/network restart >/dev/null 2>&1 &")
  write_json(200, {ok=1})
end

-- POST: apply Wi‑Fi settings (AP)
function api_apply_wifi()
  local ssid = tostring(param("ssid","Shpun-Router") or "Shpun-Router")
  local key  = tostring(param("key","") or "")
  local changed=false

  uci:foreach("wireless","wifi-iface", function(s)
    if s.mode=="ap" then
      uci:set("wireless", s[".name"], "ssid", ssid)
      if key ~= "" then
        uci:set("wireless", s[".name"], "encryption", "psk2")
        uci:set("wireless", s[".name"], "key", key)
      else
        uci:delete("wireless", s[".name"], "encryption")
        uci:delete("wireless", s[".name"], "key")
      end
      changed=true
    end
  end)

  if changed then
    uci:commit("wireless")
    sys.call("/etc/init.d/network restart >/dev/null 2>&1 &")
  end

  write_json(200, {ok=1})
end
