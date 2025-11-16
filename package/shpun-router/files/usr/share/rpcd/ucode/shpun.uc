'use strict';

import { open } from 'fs';
import { cursor } from 'uci';

/* пути */
const DIR   = "/etc/shpun";
const CODE  = DIR + "/router_code";
const SUB   = DIR + "/subscription.json";
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

/* проверка существования файла (для vpn_ready) */
function exists(path) {
	try {
		let f = open(path, "r");
		if (!f)
			return false;
		f.close();
		return true;
	} catch (e) {
		return false;
	}
}

return {
	shpun: {

		/* --- PING --- */
		ping: {
			call: function(req) {
				return { ok: 1, msg: "shpun ucode pong" };
			}
		},

        /* --- STATE --- */
        state: {
            call: function(req) {
                try {
                    let code_raw = readfile(CODE);
                    let sub_raw  = readfile(SUB);

                    /* убираем \n и пробелы в конце кода */
                    let code = code_raw ? code_raw.replace(/\s+$/, "") : "";

                    /* subscription.json целиком, как есть */
                    let sub  = sub_raw ? sub_raw : "";

                    return {
                        code: code,
                        has_sub: (sub != ""),
                        subscription_url: sub,
                        /* vpn_ready по факту существования файла, а не по содержимому */
                        vpn_ready: exists(READY)
                    };
                }
                catch (e) {
                    return { ok: 0, error: String(e) };
                }
            }
        },


		/* --- APPLY_WAN --- */
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
			call: function(request) {
				try {
					/* поддерживаем и объект, и массив args[0] */
					let p = (request && request.args && request.args[0])
						? request.args[0]
						: (request && request.args) ? request.args : {};
					let u = cursor();

					u.load("network");

					let proto    = p.proto    || "dhcp";
					let username = p.username || "";
					let password = p.password || "";
					let ipaddr   = p.ipaddr   || "";
					let netmask  = p.netmask  || "";
					let gateway  = p.gateway  || "";
					let dns      = p.dns      || "";
					let server   = p.server   || "";

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

		/* --- APPLY_WIFI --- */
		apply_wifi: {
			args: {
				ssid: "String",
				key:  "String"
			},
			call: function(request) {
				try {
					/* поддерживаем и объект, и массив args[0] */
					let p = (request && request.args && request.args[0])
						? request.args[0]
						: (request && request.args) ? request.args : {};
					let u = cursor();
					u.load("wireless");

					let ssid = p.ssid || "";
					let key  = p.key  || "";

					if (!ssid || ssid == "")
						ssid = "Shpun-Router";

					/* 5 GHz: default_radio0, если есть и это AP */
					let mode0 = u.get("wireless", "default_radio0", "mode");
					if (mode0 == "ap") {
						u.set("wireless", "default_radio0", "ssid", ssid);
						if (key && key != "") {
							u.set("wireless", "default_radio0", "encryption", "psk2");
							u.set("wireless", "default_radio0", "key", key);
						}
						else {
							u.set("wireless", "default_radio0", "encryption", "none");
							u.delete("wireless", "default_radio0", "key");
						}
					}

					/* 2.4 GHz: default_radio1, если есть и это AP */
					let mode1 = u.get("wireless", "default_radio1", "mode");
					if (mode1 == "ap") {
						u.set("wireless", "default_radio1", "ssid", ssid);
						if (key && key != "") {
							u.set("wireless", "default_radio1", "encryption", "psk2");
							u.set("wireless", "default_radio1", "key", key);
						}
						else {
							u.set("wireless", "default_radio1", "encryption", "none");
							u.delete("wireless", "default_radio1", "key");
						}
					}

					/* включим оба radio на всякий случай */
					let r0 = u.get("wireless", "radio0", "disabled");
					if (r0 == "1" || r0 == 1)
						u.set("wireless", "radio0", "disabled", "0");

					let r1 = u.get("wireless", "radio1", "disabled");
					if (r1 == "1" || r1 == 1)
						u.set("wireless", "radio1", "disabled", "0");

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
