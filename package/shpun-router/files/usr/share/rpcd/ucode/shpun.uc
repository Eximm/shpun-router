'use strict';

import { open } from 'fs';
import { cursor } from 'uci';

/* пути */
const DIR    = "/etc/shpun";
const CODE   = DIR + "/router_code";
const SUB    = DIR + "/subscription.json";
const READY  = DIR + "/vpn_ready";
const VERROR = DIR + "/vpn_error";

const VPN_IP = "/tmp/shpun_vpn_ip";
const FW_CUR = DIR + "/router_version";
const FW_LAST = DIR + "/router_latest_version";



/* безопасное чтение файла */
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

/* проверка существования файла */
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

		state: {
			call: function(req) {
				try {
					let code_raw    = readfile(CODE);
					let sub_raw     = readfile(SUB);
					let err_raw     = readfile(VERROR);
					let vpn_raw     = readfile(VPN_IP);
					let fw_cur_raw  = readfile(FW_CUR);
					let fw_last_raw = readfile(FW_LAST);

					let code    = code_raw    ? code_raw    : "";
					let sub     = sub_raw     ? sub_raw     : "";
					let verr    = err_raw     ? err_raw     : "";
					let vpn_ip  = vpn_raw     ? vpn_raw     : "";
					let fw_cur  = fw_cur_raw  ? fw_cur_raw  : "";
					let fw_last = fw_last_raw ? fw_last_raw : "";

					let res = {
						code: code,
						has_sub: (sub != ""),
						subscription_url: sub,
						vpn_ready: exists(READY),
						vpn_error: verr
					};

					if (vpn_ip != "")
						res.vpn_ip = vpn_ip;

					if (fw_cur != "")
						res.fw_current = fw_cur;

					if (fw_last != "")
						res.fw_latest = fw_last;

					return res;
				}
				catch (e) {
					return { ok: 0, error: String(e) };
				}
			}
		},

		/* --- UPDATE_ROUTER --- */
		update_router: {
			call: function(req) {
				try {
					/* Проверка файла */
					let f = open(DIR + "/router_updater", "r");
					if (!f)
						return { ok: 0, error: "router_updater not found" };
					f.close();

					/* Запуск в фоне */
					os.execute("/etc/shpun/router_updater >/dev/null 2>&1 &");

					return { ok: 1, msg: "update started" };
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
						u.set("network", "wan", "server", server);
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
					let p = (request && request.args && request.args[0])
						? request.args[0]
						: (request && request.args) ? request.args : {};

					let u = cursor();
					u.load("wireless");

					let ssid = p.ssid || "";
					let key  = p.key  || "";

					if (!ssid || ssid == "")
						ssid = "Shpun-Router";

					/* 5 GHz */
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

					/* 2.4 GHz */
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

					/* включить radio */
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
