#!/usr/bin/ucode

'use strict';

/*
 * Backend для Shpun Router:
 *  - state: читает файлы состояния в /etc/shpun
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
	/* ===== shpun.state ===== */
	state: {
		call: function() {
			const code_raw  = readfile(CODE_FILE);
			const sub_raw   = readfile(SUB_FILE);
			const ready_raw = readfile(READY_FILE);

			const code = code_raw ? code_raw : "";
			const sub  = sub_raw  ? sub_raw  : "";

			const has_sub = (sub != "");
			const vpn_ok  = (ready_raw != null);

			return {
				code: code,
				has_sub: has_sub,
				subscription_url: sub,
				vpn_ready: vpn_ok
			};
		}
	},

	/* ===== shpun.apply_wan ===== */
	apply_wan: {
		args: {
			proto:    "",
			username: "",
			password: "",
			ipaddr:   "",
			netmask:  "",
			gateway:  "",
			dns:      "",
			server:   ""
		},
		call: function(args, req) {
			let u = cursor();

			let proto    = args.proto    || "dhcp";
			let username = args.username || "";
			let password = args.password || "";
			let ipaddr   = args.ipaddr   || "";
			let netmask  = args.netmask  || "";
			let gateway  = args.gateway  || "";
			let dns      = args.dns      || "";
			let server   = args.server   || "";

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

			let p = popen("/etc/init.d/network restart >/dev/null 2>&1 &", "r");
			if (p) p.close();

			return { ok: 1 };
		}
	},

	/* ===== shpun.apply_wifi ===== */
	apply_wifi: {
		args: {
			ssid: "",
			key:  ""
		},
		call: function(args, req) {
			let u    = cursor();
			let ssid = args.ssid || "";
			let key  = args.key  || "";

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

			let p = popen("/sbin/wifi up >/dev/null 2>&1 || /etc/init.d/network reload >/dev/null 2>&1 &", "r");
			if (p) p.close();

			return { ok: 1 };
		}
	}
};

return { "shpun": methods };
