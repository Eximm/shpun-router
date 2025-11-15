'use strict';

import { open } from 'fs';
import { cursor } from 'uci';

/* пути */
const DIR   = "/etc/shpun";
const CODE  = DIR + "/router_code";
const SUB   = DIR + "/subscription_url";
const READY = DIR + "/vpn_ready";

/* безопасное чтение файла, без ошибок */
function readfile(path) {
	try {
		let f = open(path, "r");
		if (!f)
			return "";
		let d = f.read("all");
		f.close();
		return d ? d : "";
	} catch (e) {
		return "";
	}
}

return {

	shpun: {

		/* --- PING --- */
		ping: {
			call: function(req, msg) {
				return { ok: 1, msg: "shpun ucode pong" };
			}
		},

		/* --- STATE (3-й шаг VPN / код роутера) --- */
		state: {
			call: function(req, msg) {
				try {
					let code_raw = readfile(CODE);
					let sub_raw  = readfile(SUB);
					let ready    = readfile(READY);

					let code = code_raw ? code_raw : "";
					let sub  = sub_raw  ? sub_raw  : "";

					return {
						code: code,
						has_sub: (sub != ""),
						subscription_url: sub,
						vpn_ready: (ready != "")
					};
				}
				catch (e) {
					return { ok: 0, error: String(e) };
				}
			}
		},

		/* --- APPLY_WAN (1-й шаг мастера) --- */
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
			call: function(req, p) {
				try {
					let u = cursor();

					u.load("network");

					let proto    = (p && p.proto)    ? p.proto    : "dhcp";
					let username = (p && p.username) ? p.username : "";
					let password = (p && p.password) ? p.password : "";
					let ipaddr   = (p && p.ipaddr)   ? p.ipaddr   : "";
					let netmask  = (p && p.netmask)  ? p.netmask  : "";
					let gateway  = (p && p.gateway)  ? p.gateway  : "";
					let dns      = (p && p.dns)      ? p.dns      : "";
					let server   = (p && p.server)   ? p.server   : "";

					/* на всякий случай убедимся, что секция wan существует */
					u.set("network", "wan", "proto", proto);

					if (proto == "pppoe") {
						u.set("network", "wan", "username", username);
						u.set("network", "wan", "password", password);

						u.delete("network", "wan", "ipaddr");
						u.delete("network", "wan", "netmask");
						u.delete("network", "wan", "gateway");
						u.delete("network", "wan", "dns");
						u.delete("network", "wan", "server");
					}
					else if (proto == "static") {
						u.set("network", "wan", "ipaddr",  ipaddr);
						u.set("network", "wan", "netmask", netmask);
						u.set("network", "wan", "gateway", gateway);

						if (dns != "")
							u.set("network", "wan", "dns", dns);
						else
							u.delete("network", "wan", "dns");

						u.delete("network", "wan", "username");
						u.delete("network", "wan", "password");
						u.delete("network", "wan", "server");
					}
					else if (proto == "l2tp") {
						u.set("network", "wan", "server",   server);
						u.set("network", "wan", "username", username);
						u.set("network", "wan", "password", password);

						u.delete("network", "wan", "ipaddr");
						u.delete("network", "wan", "netmask");
						u.delete("network", "wan", "gateway");
						u.delete("network", "wan", "dns");
					}
					else {
						/* dhcp по умолчанию */
						u.delete("network", "wan", "username");
						u.delete("network", "wan", "password");
						u.delete("network", "wan", "ipaddr");
						u.delete("network", "wan", "netmask");
						u.delete("network", "wan", "gateway");
						u.delete("network", "wan", "dns");
						u.delete("network", "wan", "server");
						u.set("network", "wan", "proto", "dhcp");
					}

					u.commit("network");
					u.unload();

					return { ok: 1 };
				}
				catch (e) {
					return { ok: 0, error: String(e) };
				}
			}
		},

		/* --- APPLY_WIFI (2-й шаг мастера) --- */
		apply_wifi: {
			args: {
				ssid: "String",
				key:  "String"
			},
			call: function(req, p) {
				try {
					let u = cursor();
					u.load("wireless");

					let ssid = (p && p.ssid) ? p.ssid : "";
					let key  = (p && p.key)  ? p.key  : "";

					if (!ssid || ssid == "")
						ssid = "Shpun-Router";

					let iface = null;

					/* включаем iface'ы и ищем первый AP */
					u.foreach("wireless", "wifi-iface", function(s) {
						if (!iface && s.mode == "ap")
							iface = s[".name"];

						if (s.disabled == "1" || s.disabled == 1)
							u.set("wireless", s[".name"], "disabled", "0");
					});

					/* включаем radio-устройства */
					u.foreach("wireless", "wifi-device", function(s) {
						if (s.disabled == "1" || s.disabled == 1)
							u.set("wireless", s[".name"], "disabled", "0");
					});

					if (!iface) {
						u.unload();
						return { ok: 0, error: "no_ap_iface" };
					}

					/* SSID + ключ / открытая сеть */
					u.set("wireless", iface, "ssid", ssid);

					if (key && key != "") {
						u.set("wireless", iface, "encryption", "psk2");
						u.set("wireless", iface, "key", key);
					}
					else {
						u.set("wireless", iface, "encryption", "none");
						u.delete("wireless", iface, "key");
					}

					u.commit("wireless");
					u.unload();

					return { ok: 1 };
				}
				catch (e) {
					return { ok: 0, error: String(e) };
				}
			}
		}
	}
};