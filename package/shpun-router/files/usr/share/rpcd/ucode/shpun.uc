'use strict';

import { open, popen } from 'fs';
import { cursor } from 'uci';  /* сейчас не нужен, но оставим, чтобы не трогать окружение */

/* пути */
const DIR      = "/etc/shpun";
const CODE     = DIR + "/router_code";
const SUB      = DIR + "/subscription.json";
const READY    = DIR + "/vpn_ready";
const VERROR   = DIR + "/vpn_error";

const VPN_IP   = "/tmp/shpun_vpn_ip";
const FW_CUR   = DIR + "/router_version";
const FW_LAST  = DIR + "/router_latest_version";

/* безопасное чтение файла */
function readfile(path) {
	try {
		let f = open(path, "r");
		if (!f)
			return "";
		let d = f.read("all");
		f.close();
		return d ? d : "";
	}
	catch (e) {
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
	}
	catch (e) {
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

		/* --- UPDATE_ROUTER (OTA) --- */
		update_router: {
			call: function(req) {
				try {
					/* Проверка наличия файла */
					if (!exists(DIR + "/router_updater"))
						return { ok: 0, error: "router_updater not found" };

					/* Запуск в фоне через fs.popen (shell-команда) */
					let proc = popen("/etc/shpun/router_updater >/dev/null 2>&1 &");
					if (proc)
						proc.close();

					return { ok: 1, msg: "update started" };
				}
				catch (e) {
					return { ok: 0, error: String(e) };
				}
			}
		}
	}
};
