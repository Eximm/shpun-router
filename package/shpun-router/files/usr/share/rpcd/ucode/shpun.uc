'use strict';

import { open, popen } from 'fs';

/* базовый каталог */
const DIR       = "/etc/shpun";

/* основные файлы состояния */
const CODE      = DIR + "/router_code";
const SUB       = DIR + "/subscription.json";
const READY     = DIR + "/vpn_ready";
const VERROR    = DIR + "/vpn_error";

/* новые файлы версий */
const FW_CUR_NEW   = DIR + "/fw_current";
const FW_LAST_NEW  = DIR + "/fw_latest";

/* старые/совместимые файлы версий */
const FW_CUR_MAIN  = DIR + "/router_software_version";
const FW_LAST_MAIN = DIR + "/router_latest_version";
const FW_CUR_OLD   = DIR + "/router_version";

const LASTCHK   = DIR + "/last_sub_check";

/* безопасное чтение файла (без trim) */
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

/* прочитать текущую версию прошивки (новые и старые файлы) */
function read_fw_current() {
	let v = "";

	if (exists(FW_CUR_NEW))
		v = readfile(FW_CUR_NEW);
	else if (exists(FW_CUR_MAIN))
		v = readfile(FW_CUR_MAIN);
	else if (exists(FW_CUR_OLD))
		v = readfile(FW_CUR_OLD);

	return v || "";
}

/* прочитать последнюю известную версию прошивки */
function read_fw_latest() {
	let v = "";

	if (exists(FW_LAST_NEW))
		v = readfile(FW_LAST_NEW);
	else if (exists(FW_LAST_MAIN))
		v = readfile(FW_LAST_MAIN);

	return v || "";
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
					let err_raw  = readfile(VERROR);

					let code = code_raw || "";
					let sub  = sub_raw  || "";
					let verr = err_raw  || "";

					let fw_cur  = read_fw_current();
					let fw_last = read_fw_latest();

					let res = {
						code: code,
						has_sub: (sub != ""),
						/* subscription_url сейчас виджету особо не нужен,
						 * но вернём содержимое для совместимости
						 */
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
					/* на всякий случай не роняем ubus */
					return { ok: 0, error: String(e) };
				}
			}
		},

		/* --- OTA_CHECK: форсируем проверку версии, не ломая привязку --- */
		ota_check: {
			call: function(req) {
				try {
					if (!exists("/etc/init.d/shpun-agent"))
						return { ok: 0, error: "shpun-agent init script not found" };

					if (!exists(DIR + "/router_updater"))
						return { ok: 0, error: "router_updater not found" };

					/* ЛОГИКА:
					 * 1) удаляем только last_sub_check;
					 * 2) перезапускаем shpun-agent;
					 * 3) ждём 10 секунд;
					 * 4) CHECK_ONLY=1 /etc/shpun/router_updater
					 *
					 * ВАЖНО: НЕ трогаем subscription.json и router_code.
					 */
					let cmd =
						"sh -c '" +
							"rm -f " + LASTCHK + " >/dev/null 2>&1; " +
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

		/* --- RESET_VPN: полный сброс VPN-состояния, но без отката версии ПО --- */
		reset_vpn: {
			call: function(req) {
				try {
					/* остановить сервисы */
					let p1 = popen("/etc/init.d/shpun-vpn stop >/dev/null 2>&1 &");
					if (p1) p1.close();

					let p2 = popen("/etc/init.d/shpun-agent stop >/dev/null 2>&1 &");
					if (p2) p2.close();

					/* удалить состояние VPN:
					 * - код роутера (чтобы при старте агент мог сгенерировать новый, если нужно),
					 * - подписку,
					 * - сгенерированный конфиг,
					 * - флаги готовности/ошибки,
					 * - last_sub_check.
					 *
					 * ВАЖНО: НЕ трогаем файлы версий (fw_current/fw_latest и старые имена),
					 * чтобы установленная версия пакета не "откатывалась" логически назад.
					 */
					let cmd =
						"rm -f " +
						CODE + " " +           /* router_code */ 
						SUB + " " +            /* subscription.json */
						DIR + "/xray.json " +  /* сгенерированный xray.json */
						READY + " " +          /* vpn_ready */
						VERROR + " " +         /* vpn_error */
						LASTCHK + " " +        /* last_sub_check */ 
						">/dev/null 2>&1";

					let p3 = popen(cmd);
					if (p3) p3.close();

					/* стартуем агента заново — он сгенерит новый код и пойдёт в router_public */
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
