module("luci.controller.shpun", package.seeall)

local uci  = require "luci.model.uci".cursor()
local sys  = require "luci.sys"
local fs   = require "nixio.fs"
local http = require "luci.http"

local STATE_DIR       = "/etc/shpun"
local CODE_FILE       = STATE_DIR .. "/router_code"
local SUB_FILE        = STATE_DIR .. "/subscription_url"
local READY_FILE      = STATE_DIR .. "/vpn_ready"
local FIRST_RUN_FILE  = STATE_DIR .. "/first_run"

function index()
	-- Главный пункт Shpun в меню
	-- ТЕПЕРЬ он идёт не на firstchild(), а в нашу функцию action_index
	entry({"admin", "shpun"}, call("action_index"), _("Shpun VPN"), 10).dependent = false

	-- Отдельный пункт для мастера (можно вызывать вручную)
	entry({"admin", "shpun", "wizard"}, template("shpun/wizard"), _("Мастер Shpun"), 1)

	-- API endpoints
	entry({"admin", "shpun", "api", "state"},      call("api_state")).leaf      = true
	entry({"admin", "shpun", "api", "apply_wan"},  call("api_apply_wan")).leaf  = true
	entry({"admin", "shpun", "api", "apply_wifi"}, call("api_apply_wifi")).leaf = true
end

-- Что происходит при заходе в "Shpun VPN" в меню
function action_index()
	-- Если это ПЕРВЫЙ запуск (есть /etc/shpun/first_run) – сразу показываем мастер
	if fs.access(FIRST_RUN_FILE) then
		luci.template.render("shpun/wizard")
		return
	end

	-- Если не первый запуск:
	-- тут можно будет сделать отдельную страницу статуса (shpun/status),
	-- но пока для простоты тоже открываем мастер
	luci.template.render("shpun/wizard")
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
