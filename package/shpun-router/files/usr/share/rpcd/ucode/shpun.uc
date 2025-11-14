#!/usr/bin/ucode

'use strict';

import { cursor } from 'uci';

const STATE_DIR  = "/etc/shpun";
const CODE_FILE  = STATE_DIR + "/router_code";
const SUB_FILE   = STATE_DIR + "/subscription_url";
const READY_FILE = STATE_DIR + "/vpn_ready";

/* ===== helpers ===== */

function readfile(path) {
	const f = open(path, 'r');

	if (!f)
		return null;

	const data = f.read('all');
	f.close();

	return trim(data);
}

/* ===== ubus methods ===== */

const methods = {
	/* === shpun.state ===
	 * Возвращает состояние визарда / агента:
	 *  - code            : строка кода роутера (или пусто)
	 *  - has_sub         : true, если есть subscription_url
	 *  - subscription_url: сама ссылка (можно не использовать на фронте)
	 *  - vpn_ready       : true, если агент пометил vpn_ready
	 */
	state: {
		call: function(params) {
			const code  = readfile(CODE_FILE) ?? "";
			const sub   = readfile(SUB_FILE);
			const ready = readfile(READY_FILE);

			return {
				code: code,
				has_sub: sub != null && length(trim(sub)) > 0,
				subscription_url: sub ?? "",
				vpn_ready: ready != null && length(trim(ready)) > 0
			};
		}
	},

	/* === shpun.apply_wan ===
	 * Параметры (ожидаются из wizard.js):
	 *  - proto    : "dhcp" | "pppoe" | "static" | "l2tp"
	 *  - username : логин (pppoe/l2tp)
	 *  - password : пароль (pppoe/l2tp)
	 *  - ipaddr   : IP для static
	 *  - netmask  : маска для static
	 *  - gateway  : шлюз для static
	 *  - dns      : строка DNS (может быть пустой)
	 *  - server   : адрес сервера (l2tp)
	 */
	apply_wan: {
		call: function(params) {
			const u = cursor();

			const proto   = params.proto ?? "dhcp";
			const username = params.username ?? "";
			const password = params.password ?? "";
			const ipaddr   = params.ipaddr   ?? "";
			const netmask  = params.netmask  ?? "";
			const gateway  = params.gateway  ?? "";
			const dns      = params.dns      ?? "";
			const server   = params.server   ?? "";

			let opts = { proto: proto };

			if (proto == "pppoe") {
				opts.username = username;
				opts.password = password;
			}
			else if (proto == "static") {
				opts.ipaddr  = ipaddr;
				opts.netmask = netmask;
				opts.gateway = gateway;

				if (dns && length(trim(dns)))
					opts.dns = dns;
			}
			else if (proto == "l2tp") {
				/* стандартный l2tp-клиент OpenWrt */
				opts.server   = server;
				opts.username = username;
				opts.password = password;
			}
			else {
				/* всё остальное трактуем как dhcp */
				opts.proto = "dhcp";
			}

			u.set("network", "wan", opts);
			u.commit("network");
			u.unload();

			/* рестартуем сеть в фоне */
			const p = popen("/etc/init.d/network restart >/dev/null 2>&1 &", "r");
			if (p)
				p.close();

			return { ok: 1 };
		}
	},

	/* === shpun.apply_wifi ===
	 * Параметры:
	 *  - ssid : имя сети
	 *  - key  : пароль (если пусто, делаем открытой)
	 */
	apply_wifi: {
		call: function(params) {
			const u = cursor();

			const ssid = params.ssid ?? "";
			const key  = params.key  ?? "";

			let iface_name = null;

			/* ищем первое iface с mode="ap" */
			u.foreach("wireless", "wifi-iface", function(s) {
				if (s.mode == "ap" && !iface_name)
					iface_name = s[".name"];
			});

			if (!iface_name)
				return { ok: 0, error: "no_ap_iface" };

			let opts = {};

			if (ssid && length(trim(ssid)))
				opts.ssid = ssid;

			if (key && length(trim(key))) {
				opts.encryption = "psk2";
				opts.key = key;
			}
			else {
				/* открытая сеть */
				opts.encryption = "none";
				u.delete("wireless", iface_name, "key");
			}

			u.set("wireless", iface_name, opts);
			u.commit("wireless");
			u.unload();

			const p = popen("/etc/init.d/network reload >/dev/null 2>&1 &", "r");
			if (p)
				p.close();

			return { ok: 1 };
		}
	}
};

/* регистрируем ubus-объект "shpun" */
return { "shpun": methods };
