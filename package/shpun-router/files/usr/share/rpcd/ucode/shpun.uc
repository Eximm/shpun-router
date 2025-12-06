'use strict';

import { open, popen } from 'fs';
import { cursor } from 'uci';  /* можно не использовать, но пусть будет */

/* пути */
const DIR      = "/etc/shpun";
const CODE     = DIR + "/router_code";
const SUB      = DIR + "/subscription.json";
const READY    = DIR + "/vpn_ready";
const VERROR   = DIR + "/vpn_error";

const FW_CUR   = DIR + "/router_version";
const FW_LAST  = DIR + "/router_latest_version";
const LASTCHK  = DIR + "/last_sub_check";

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
					let fw_cur_raw  = readfile(FW_CUR);
					let fw_last_raw = readfile(FW_LAST);

					let code    = code_raw    ? code_raw    : "";
					let sub     = sub_raw     ? sub_raw     : "";
					let verr    = err_raw     ? err_raw     : "";
					let fw_cur  = fw_cur_raw  ? fw_cur_raw  : "";
					let fw_last = fw_last_raw ? fw_last_raw : "";

					let res = {
						code: code,
						has_sub: (sub != ""),
						subscription_url: sub,
						vpn_ready: exists(READY),
						vpn_error: verr
					};

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

		/* --- OTA_CHECK: обновить подписку с сервера и только вычислить fw_latest --- */
		ota_check: {
			call: function(req) {
				try {
					if (!exists("/etc/init.d/shpun-agent"))
						return { ok: 0, error: "shpun-agent init script not found" };

					if (!exists(DIR + "/router_updater"))
						return { ok: 0, error: "router_updater not found" };

					/* 1) сбрасываем last_sub_check и subscription.json,
					 * 2) рестартуем агента (он тянет свежий subscription.json),
					 * 3) ждём немного,
					 * 4) запускаем router_updater в режиме CHECK_ONLY=1,
					 *    чтобы он только записал router_latest_version.
					 */
					let cmd =
						"sh -c '" +
							"rm -f " + LASTCHK + " " + SUB + " >/dev/null 2>&1; " +
							"/etc/init.d/shpun-agent restart >/dev/null 2>&1; " +
							"sleep 10; " +
							"CHECK_ONLY=1 /etc/shpun/router_updater >/dev/null 2>&1" +
						"' &";

					let p = popen(cmd);
					if (p) p.close();

					return { ok: 1, msg: "ota check started" };
				}
				catch (e) {
					return { ok: 0, error: String(e) };
				}
			}
		},

		/* --- OTA_INSTALL: установить новую версию, если она есть --- */
		ota_install: {
			call: function(req) {
				try {
					if (!exists(DIR + "/router_updater"))
						return { ok: 0, error: "router_updater not found" };

					let p = popen("/etc/shpun/router_updater >/dev/null 2>&1 &");
					if (p) p.close();

					return { ok: 1, msg: "ota install started" };
				}
				catch (e) {
					return { ok: 0, error: String(e) };
				}
			}
		},

		/* --- RESET_VPN: полный сброс в состояние "только что поставили пакет" --- */
		reset_vpn: {
			call: function(req) {
				try {
					let p1 = popen("/etc/init.d/shpun-vpn stop >/dev/null 2>&1 &");
					if (p1) p1.close();

					let p2 = popen("/etc/init.d/shpun-agent stop >/dev/null 2>&1 &");
					if (p2) p2.close();

					let cmd =
						"rm -f " +
						CODE + " " +            /* router_code */
						SUB + " " +             /* subscription.json */
						DIR + "/xray.json " +   /* сгенерированный конфиг Xray */
						READY + " " +           /* vpn_ready */
						VERROR + " " +          /* vpn_error */
						FW_LAST +               /* последняя доступная версия */
						" >/dev/null 2>&1";

					let p3 = popen(cmd);
					if (p3) p3.close();

					let p4 = popen("/etc/init.d/shpun-agent start >/dev/null 2>&1 &");
					if (p4) p4.close();

					return { ok: 1, msg: "vpn reset to initial state" };
				}
				catch (e) {
					return { ok: 0, error: String(e) };
				}
			}
		}
	}
};
