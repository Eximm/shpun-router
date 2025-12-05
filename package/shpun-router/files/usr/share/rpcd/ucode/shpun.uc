'use strict';

let fs = require("fs");

/* Пути */
const DIR   = "/etc/shpun";
const CODE  = DIR + "/router_code";
const SUB   = DIR + "/subscription.json";
const READY = DIR + "/vpn_ready";
const ERR   = DIR + "/vpn_error";

/* Запасной код на случай, если файл не прочитался */
const FIXED_CODE = "U7MD-IJM2";  /* можешь сменить/убрать позже */

/* ==== helpers: файлы ==== */

function file_exists(path) {
	try {
		let st = fs.stat(path);
		/* st == null, если файла нет */
		return !!st && st.type == "regular";
	} catch (e) {
		return false;
	}
}

/* безопасное чтение файла, учитываем разные форматы fs.readfile() */
function read_file(path) {
	try {
		let res = fs.readfile(path);

		/* вариант: { data: ... } */
		if (res && typeof(res) === "object" && "data" in res) {
			if (!res.data)
				return "";
			return ("" + res.data).trim();
		}

		/* вариант: сразу строка/буфер */
		if (res)
			return ("" + res).trim();

		return "";
	} catch (e) {
		return "";
	}
}

/* ==== helpers: UCI ==== */

function get_cursor() {
	let uci = require("uci");
	return uci.cursor();
}

/* нормализация аргументов:
 * поддерживаем как { proto:"dhcp", ... }, так и { args:[{...}] }
 */
function normalize_args(req) {
	if (!req)
		return {};

	if (req.args && typeof(req.args) === "object") {
		/* если args - массив и там есть 0-й элемент */
		if (req.args[0] && typeof(req.args[0]) === "object")
			return req.args[0];
		/* если args - просто объект с полями */
		return req.args;
	}

	return req;
}

/* ==== helpers: OS ==== */

function try_system(cmd) {
	try {
		let os = require("os");
		os.system(cmd);
	} catch (e) {
		/* если модуля os нет — просто молча игнорируем */
	}
}

/* ================================================================== */
/*                    RPC backend "shpun"                             */
/* ================================================================== */

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
					/* код: сначала пытаемся прочитать файл, если не получилось — FIXED_CODE */
					let code = FIXED_CODE;
					let file_code = read_file(CODE);
					if (file_code && file_code !== "")
						code = file_code;

					let sub  = read_file(SUB);
					let verr = read_file(ERR);

					return {
						code: code,
						has_sub: file_exists(SUB) ? 1 : 0,
						subscription_url: sub,
						vpn_ready: file_exists(READY) ? 1 : 0,
						vpn_error: verr
					};
				} catch (e) {
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
					let p = normalize_args(request);
					let u = get_cursor();

					let proto    = p.proto    || "dhcp";
					let username = p.username || "";
					let password = p.password || "";
					let ipaddr   = p.ipaddr   || "";
					let netmask  = p.netmask  || "";
					let gateway  = p.gateway  || "";
					let dns      = p.dns      || "";
					let server   = p.server   || "";

					u.load("network");

					u.set("network", "wan", "proto", proto);

					if (proto === "pppoe") {
						u.set("network", "wan", "username", username);
						u.set("network", "wan", "password", password);

						u.delete("network", "wan", "ipaddr");
						u.delete("network", "wan", "netmask");
						u.delete("network", "wan", "gateway");
						u.delete("network", "wan", "dns");
						u.delete("network", "wan", "server");
					}
					else if (proto === "static") {
						u.set("network", "wan", "ipaddr",  ipaddr);
						u.set("network", "wan", "netmask", netmask);
						u.set("network", "wan", "gateway", gateway);

						if (dns && dns !== "")
							u.set("network", "wan", "dns", dns);
						else
							u.delete("network", "wan", "dns");

						u.delete("network", "wan", "username");
						u.delete("network", "wan", "password");
						u.delete("network", "wan", "server");
					}
					else if (proto === "l2tp") {
						u.set("network", "wan", "server",   server);
						u.set("network", "wan", "username", username);
						u.set("network", "wan", "password", password);

						u.delete("network", "wan", "ipaddr");
						u.delete("network", "wan", "netmask");
						u.delete("network", "wan", "gateway");
						u.delete("network", "wan", "dns");
					}
					else {
						/* fallback: dhcp */
						u.set("network", "wan", "proto", "dhcp");
						u.delete("network", "wan", "username");
						u.delete("network", "wan", "password");
						u.delete("network", "wan", "ipaddr");
						u.delete("network", "wan", "netmask");
						u.delete("network", "wan", "gateway");
						u.delete("network", "wan", "dns");
						u.delete("network", "wan", "server");
					}

					u.commit("network");
					u.unload();

					/* мягкий перезапуск WAN, если получится */
					try_system("ifup wan &");

					return { ok: 1 };
				} catch (e) {
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
					let p = normalize_args(request);
					let u = get_cursor();

					let ssid = p.ssid || "";
					let key  = p.key  || "";

					if (!ssid || ssid === "")
						ssid = "Shpun-Router";

					u.load("wireless");

					/* 5 GHz: default_radio0, если есть и это AP */
					let mode0 = u.get("wireless", "default_radio0", "mode");
					if (mode0 === "ap") {
						u.set("wireless", "default_radio0", "ssid", ssid);
						if (key && key !== "") {
							u.set("wireless", "default_radio0", "encryption", "psk2");
							u.set("wireless", "default_radio0", "key", key);
						} else {
							u.set("wireless", "default_radio0", "encryption", "none");
							u.delete("wireless", "default_radio0", "key");
						}
					}

					/* 2.4 GHz: default_radio1, если есть и это AP */
					let mode1 = u.get("wireless", "default_radio1", "mode");
					if (mode1 === "ap") {
						u.set("wireless", "default_radio1", "ssid", ssid);
						if (key && key !== "") {
							u.set("wireless", "default_radio1", "encryption", "psk2");
							u.set("wireless", "default_radio1", "key", key);
						} else {
							u.set("wireless", "default_radio1", "encryption", "none");
							u.delete("wireless", "default_radio1", "key");
						}
					}

					/* включим оба radio на всякий случай */
					let r0 = u.get("wireless", "radio0", "disabled");
					if (r0 === "1" || r0 === 1)
						u.set("wireless", "radio0", "disabled", "0");

					let r1 = u.get("wireless", "radio1", "disabled");
					if (r1 === "1" || r1 === 1)
						u.set("wireless", "radio1", "disabled", "0");

					u.commit("wireless");
					u.unload();

					/* мягкий reload Wi-Fi, если возможно */
					try_system("/sbin/wifi reload_legacy 2>/dev/null || /sbin/wifi reload &");

					return { ok: 1 };
				} catch (e) {
					return { ok: 0, error: String(e) };
				}
			}
		},

		/* --- UPDATE_ROUTER: запуск обновления пакета shpun-router --- */
		update_router: {
			call: function(request) {
				try {
					/* асинхронный запуск shell-скрипта, чтобы не блокировать ubus */
					try_system("/etc/shpun/update-router.sh &");
					return { ok: 1 };
				} catch (e) {
					return { ok: 0, error: String(e) };
				}
			}
		}
	}
};
