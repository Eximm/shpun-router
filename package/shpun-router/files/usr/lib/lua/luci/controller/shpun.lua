module("luci.controller.shpun", package.seeall)

local uci  = require("luci.model.uci").cursor()
local sys  = require "luci.sys"
local fs   = require "nixio.fs"
local http = require "luci.http"

local STATE_DIR      = "/etc/shpun"
local CODE_FILE      = STATE_DIR .. "/router_code"
local SUB_FILE       = STATE_DIR .. "/subscription_url"
local READY_FILE     = STATE_DIR .. "/vpn_ready"
local FIRST_RUN_FILE = STATE_DIR .. "/first_run"

function index()
	-- API endpoints, UI теперь чистый JS-view
	entry({"admin", "network", "shpun", "api", "state"},
		call("api_state")).leaf = true

	entry({"admin", "network", "shpun", "api", "apply_wan"},
		call("api_apply_wan")).leaf = true

	entry({"admin", "network", "shpun", "api", "apply_wifi"},
		call("api_apply_wifi")).leaf = true
end

-- ===== API: состояние роутера / кода / подписки =====

function api_state()
	local code  = fs.readfile(CODE_FILE) or ""
	local sub   = fs.readfile(SUB_FILE) or ""
	local ready = fs.readfile(READY_FILE) or ""

	code = code:gsub("%s+$", "")

	http.prepare_content("application/json")
	http.write_json({
		code             = code,
		has_sub          = (sub ~= "" and sub ~= nil),
		subscription_url = sub,
		vpn_ready        = (ready ~= "" and ready ~= nil),
	})
end

-- ===== API: применение настроек WAN =====

function api_apply_wan()
	local proto = http.formvalue("proto") or "dhcp"

	if proto == "dhcp" then
		uci:set("network", "wan", "proto", "dhcp")
	elseif proto == "pppoe" then
		uci:set("network", "wan", "proto", "pppoe")
		uci:set("network", "wan", "username", http.formvalue("user") or "")
		uci:set("network", "wan", "password", http.formvalue("pass") or "")
	else
		http.status(400, "Bad Request")
		http.prepare_content("application/json")
		http.write_json({ ok = 0, error = "invalid proto" })
		return
	end

	uci:commit("network")
	sys.call("/etc/init.d/network restart >/dev/null 2>&1 &")

	http.prepare_content("application/json")
	http.write_json({ ok = 1 })
end

-- ===== API: применение настроек Wi-Fi =====

function api_apply_wifi()
	local ssid = http.formvalue("ssid") or "Shpun-Router"
	local key  = http.formvalue("key") or ""

	local changed = false

	uci:foreach("wireless", "wifi-iface", function(s)
		if s.mode == "ap" then
			uci:set("wireless", s[".name"], "ssid", ssid)

			if key ~= "" then
				uci:set("wireless", s[".name"], "encryption", "psk2")
				uci:set("wireless", s[".name"], "key", key)
			else
				uci:delete("wireless", s[".name"], "encryption")
				uci:delete("wireless", s[".name"], "key")
			end

			changed = true
		end
	end)

	if changed then
		uci:commit("wireless")
		sys.call("/etc/init.d/network restart >/dev/null 2>&1 &")
	end

	http.prepare_content("application/json")
	http.write_json({ ok = 1 })
end
