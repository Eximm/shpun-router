module("luci.controller.shpun", package.seeall)

function index()
  entry({"admin", "shpun"}, firstchild(), "Shpun VPN", 10).dependent = false
  entry({"admin", "shpun", "wizard"}, template("shpun/wizard"), _("Мастер Shpun"), 1)

  entry({"admin", "shpun", "api", "state"}, call("api_state")).leaf = true
  entry({"admin", "shpun", "api", "apply_wan"}, call("api_apply_wan")).leaf = true
  entry({"admin", "shpun", "api", "apply_wifi"}, call("api_apply_wifi")).leaf = true
end

local uci = require "luci.model.uci".cursor()
local sys = require "luci.sys"
local fs  = require "nixio.fs"

function api_state()
  local code = fs.readfile("/etc/shpun/router_code") or ""
  local sub  = fs.readfile("/etc/shpun/subscription_url") or ""

  luci.http.prepare_content("application/json")
  luci.http.write_json({
    code = (code:gsub("%s+$","")),
    has_sub = (sub ~= ""),
    subscription_url = sub
  })
end

function api_apply_wan()
  local proto = luci.http.formvalue("proto") or "dhcp"
  if proto == "dhcp" then
    uci:set("network", "wan", "proto", "dhcp")
  elseif proto == "pppoe" then
    uci:set("network", "wan", "proto", "pppoe")
    uci:set("network", "wan", "username", luci.http.formvalue("user") or "")
    uci:set("network", "wan", "password", luci.http.formvalue("pass") or "")
  end
  uci:commit("network")
  sys.call("/etc/init.d/network restart >/dev/null 2>&1 &")

  luci.http.prepare_content("application/json")
  luci.http.write_json({ ok = 1 })
end

function api_apply_wifi()
  local ssid = luci.http.formvalue("ssid") or "Shpun-Router"
  local key  = luci.http.formvalue("key") or ""

  uci:foreach("wireless", "wifi-iface", function(s)
    if s.mode == "ap" then
      uci:set("wireless", s[".name"], "ssid", ssid)
      if key ~= "" then
        uci:set("wireless", s[".name"], "encryption", "psk2")
        uci:set("wireless", s[".name"], "key", key)
      end
    end
  end)

  uci:commit("wireless")
  sys.call("/etc/init.d/network restart >/dev/null 2>&1 &")

  luci.http.prepare_content("application/json")
  luci.http.write_json({ ok = 1 })
end
