module("luci.controller.shpun", package.seeall)

local uci  = require("luci.model.uci").cursor()
local sys  = require "luci.sys"
local fs   = require "nixio.fs"
local http = require "luci.http"

local STATE_DIR      = "/etc/shpun"
local CODE_FILE      = STATE_DIR .. "/router_code"
local SUB_FILE       = STATE_DIR .. "/subscription_url"
local READY_FILE     = STATE_DIR .. "/vpn_ready"

function index()
  -- только API, без меню
  entry({"admin","network","shpun","api","state"},      call("api_state"),      nil).leaf = true
  entry({"admin","network","shpun","api","apply_wan"},  post("api_apply_wan"),  nil).leaf = true
  entry({"admin","network","shpun","api","apply_wifi"}, post("api_apply_wifi"), nil).leaf = true
end

local function json_ok(tbl)
  http.status(200, "OK")
  http.prepare_content("application/json")
  http.write_json(tbl)
end

function api_state()
  local code  = (fs.readfile(CODE_FILE) or ""):gsub("%s+$","")
  local sub   = fs.readfile(SUB_FILE)   or ""
  local ready = fs.readfile(READY_FILE) or ""
  json_ok({
    code             = code,
    has_sub          = (sub ~= ""),
    subscription_url = sub,
    vpn_ready        = (ready ~= "")
  })
end

function api_apply_wan()
  local proto = http.formvalue("proto") or "dhcp"
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
    local user = http.formvalue("user") or ""
    local pass = http.formvalue("pass") or ""
    if user == "" or pass == "" then return json_ok({ok=0,error="missing pppoe credentials"}) end
    uci:set("network","wan","proto","pppoe")
    uci:set("network","wan","username",user)
    uci:set("network","wan","password",pass)
    uci:delete("network","wan","ipaddr"); uci:delete("network","wan","netmask")
    uci:delete("network","wan","gateway"); uci:delete("network","wan","dns")
    uci:delete("network","wan","server")
  elseif proto == "static" then
    local ip  = http.formvalue("ipaddr")  or ""
    local msk = http.formvalue("netmask") or ""
    local gw  = http.formvalue("gateway") or ""
    local dns = http.formvalue("dns")     or ""
    if ip=="" or msk=="" or gw=="" then return json_ok({ok=0,error="missing static params"}) end
    uci:set("network","wan","proto","static")
    uci:set("network","wan","ipaddr",ip); uci:set("network","wan","netmask",msk)
    uci:set("network","wan","gateway",gw)
    if dns~="" then uci:set("network","wan","dns",dns) else uci:delete("network","wan","dns") end
    uci:delete("network","wan","username"); uci:delete("network","wan","password"); uci:delete("network","wan","server")
  elseif proto == "l2tp" then
    local srv  = http.formvalue("server") or ""
    local user = http.formvalue("user")   or ""
    local pass = http.formvalue("pass")   or ""
    if srv=="" or user=="" or pass=="" then return json_ok({ok=0,error="missing l2tp params"}) end
    uci:set("network","wan","proto","l2tp")
    uci:set("network","wan","server",srv)
    uci:set("network","wan","username",user)
    uci:set("network","wan","password",pass)
    uci:set("network","wan","peerdns","1"); uci:set("network","wan","defaultroute","1")
    uci:delete("network","wan","ipaddr"); uci:delete("network","wan","netmask")
    uci:delete("network","wan","gateway"); uci:delete("network","wan","dns")
  else
    return json_ok({ok=0,error="invalid proto"})
  end
  uci:commit("network")
  sys.call("/etc/init.d/network restart >/dev/null 2>&1 &")
  json_ok({ok=1})
end

function api_apply_wifi()
  local ssid = http.formvalue("ssid") or "Shpun-Router"
  local key  = http.formvalue("key")  or ""
  local changed=false
  uci:foreach("wireless","wifi-iface", function(s)
    if s.mode=="ap" then
      uci:set("wireless", s[".name"], "ssid", ssid)
      if key~="" then
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
  json_ok({ok=1})
end
