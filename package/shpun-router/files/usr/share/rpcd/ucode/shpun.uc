#!/usr/bin/ucode

'use strict';

/*
 * Backend для Shpun Router:
 *  - state: читает / генерирует код, смотрит подписку и vpn_ready
 *  - apply_wan: настраивает WAN через UCI
 *  - apply_wifi: включает Wi-Fi и задаёт SSID/ключ
 */

import { open } from 'fs';
import { cursor } from 'uci';

const STATE_DIR  = "/etc/shpun";
const CODE_FILE  = STATE_DIR + "/router_code";
const SUB_FILE   = STATE_DIR + "/subscription_url";
const READY_FILE = STATE_DIR + "/vpn_ready";

/* --- helpers --- */

function readfile(path) {
	const f = open(path, "r");
	if (!f)
		return null;

	let data = f.read("all");
	f.close();

	if (!data)
		return "";

	/* убираем \n/\r/пробелы по краям */
	return ucode.trim(data);
}

/* --- ubus methods --- */

const methods = {

	/* ===== shpun.state =====
	 *  code        : строка кода (если нет - генерируем через gen_code.sh)
	 *  has_sub     : есть ли subscription_url
	 *  subscription_url : сама ссылка
	 *  vpn_ready   : true, если файл vpn_ready существует
	 */
	state: {
		call: function() {
			let code = readfile(CODE_FILE);

			/* если кода ещё нет — пробуем сгенерировать */
			if (!code || code == "") {
				const p = popen("/etc/shpun/gen_code.sh", "r");
				if (p) {
					const out = p.read("all");
					p.close();
					if (out)
						code = ucode.trim(out);
				}
			}

			if (!code)
				code = "";

			const sub_raw   = readfile(SUB_FILE);
			const ready_raw = readfile(READY_FILE);

			const sub    = sub_raw ? sub_raw : "";
			const hasSub = (sub != "");
			const vpnOk  = (ready_raw != null); /* просто факт существования файла */

			return {
				code: code,
				has_sub: hasSub,
				subscription_url: sub,
				vpn_ready: vpnOk
			};
		}
	},

	/* ===== shpun.apply_wan =====
	 * Параметры:
	 *  proto    : "dhcp" | "pppoe" | "static" | "l2tp"
	 *  username : логин (pppoe/l2tp)
	 *  password : пароль (pppoe/l2tp)
	 *  ipaddr   : IP (static)
	 *  netmask  : маска (static)
	 *  gateway  : шлюз (static)
	 *  dns      : DNS (static)
	 *  server   : адрес сервера (l2tp)
	 */
	apply_wan: {
		args: {
			proto:    "String",
			username: "String",
			password: "String",
			ipaddr:   "String",
			netmask:  "String",
			gateway:  "String",
			dns:      "String",
			server:   "String"
		},
		call: function(params) {
			let u = cursor();

			let proto    = params.proto    || "dhcp";
			let username = params.username || "";
			let password = params.password || "";
			let ipaddr   = params.ipaddr   || "";
			let netmask  = params.netmask  || "";
			let gateway  = params.gateway  || "";
			let dns      = params.dns      || "";
			let server   = params.server   || "";

			let opts = { proto: proto };

			if (proto == "pppoe") {
				opts.username = username;
				opts.password = password;
			}
			else if (proto == "static") {
				opts.ipaddr  = ipaddr;
				opts.netmask = netmask;
				opts.gateway = gateway;

				if (dns && dns != "")
					opts.dns = dns;
			}
			else if (proto == "l2tp") {
				opts.server   = server;
				opts.username = username;
				opts.password = password;
			}
			else {
				opts.proto = "dhcp";
			}

			u.set("network", "wan", opts);
			u.commit("network");
			u.unload();

			const p = popen("/etc/init.d/network restart >/dev/null 2>&1 &", "r");
			if (p) p.close();

			return { ok: 1 };
		}
	},

	/* ===== shpun.apply_wifi =====
	 * Параметры:
	 *  ssid : имя сети
	 *  key  : пароль (может быть пустым)
	 */
	apply_wifi: {
		args: {
			ssid: "String",
			key:  "String"
		},
		call: function(params) {
			let u    = cursor();
			let ssid = params.ssid || "";
			let key  = params.key  || "";

			if (!ssid || ssid == "")
				return { ok: 0, error: "empty_ssid" };

			let iface_name = null;

			/* включаем wifi-iface и запоминаем первый AP */
			u.foreach("wireless", "wifi-iface", function(s) {
				if (!iface_name && s.mode == "ap")
					iface_name = s[".name"];

				if (s.disabled == "1" || s.disabled == 1)
					u.set("wireless", s[".name"], { disabled: "0" });
			});

			/* включаем wifi-device'ы */
			u.foreach("wireless", "wifi-device", function(s) {
				if (s.disabled == "1" || s.disabled == 1)
					u.set("wireless", s[".name"], { disabled: "0" });
			});

			if (!iface_name) {
				u.unload();
				return { ok: 0, error: "no_ap_iface" };
			}

			let opts = { ssid: ssid };

			if (key && key != "") {
				opts.encryption = "psk2";
				opts.key        = key;
			}
			else {
				opts.encryption = "none";
			}

			u.set("wireless", iface_name, opts);
			u.commit("wireless");
			u.unload();

			const p = popen("/sbin/wifi up >/dev/null 2>&1 || /etc/init.d/network reload >/dev/null 2>&1 &", "r");
			if (p) p.close();

			return { ok: 1 };
		}
	}
};

return { "shpun": methods };
