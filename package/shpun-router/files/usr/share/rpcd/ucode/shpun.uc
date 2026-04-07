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

		/* --- REFRESH_CONNECTION: обновить текущую подписку через router_config по текущему коду --- */
		refresh_connection: {
			call: function(req) {
				try {
					if (!exists(CODE))
						return { ok: 0, error: "router_code not found" };

					if (!exists(SUB))
						return { ok: 0, error: "subscription.json not found" };

					if (!exists("/etc/init.d/shpun-agent"))
						return { ok: 0, error: "shpun-agent init script not found" };

					let cmd =
						"sh -c '" +
							"STATE_DIR=\"/etc/shpun\"; " +
							"CODE_FILE=\"$STATE_DIR/router_code\"; " +
							"SUB_FILE=\"$STATE_DIR/subscription.json\"; " +
							"VPN_READY_FILE=\"$STATE_DIR/vpn_ready\"; " +
							"VERROR_FILE=\"$STATE_DIR/vpn_error\"; " +
							"LAST_CHECK_FILE=\"$STATE_DIR/last_sub_check\"; " +
							"CONF=\"$STATE_DIR/agent.conf\"; " +
							"LOG_TAG=\"shpun-refresh\"; " +
							"API_URL_DEFAULT=\"https://bill.shpyn.online/shm/v1/public/router_public\"; " +
							"log(){ logger -t \"$LOG_TAG\" \"$*\"; }; " +

							"[ -f \"$CONF\" ] && . \"$CONF\"; " +
							"[ -z \"$API_URL\" ] && API_URL=\"$API_URL_DEFAULT\"; " +

							"if [ ! -s \"$CODE_FILE\" ]; then log \"router_code missing\"; exit 1; fi; " +
							"if [ ! -s \"$SUB_FILE\" ]; then log \"subscription.json missing\"; exit 1; fi; " +
							"if ! command -v jsonfilter >/dev/null 2>&1; then log \"jsonfilter not found\"; exit 1; fi; " +

							"CODE=\"$(cat \"$CODE_FILE\" 2>/dev/null | tr -d \"\\r\\n\")\"; " +
							"CLEAN_CODE=\"$(printf %s \"$CODE\" | tr \"[:lower:]\" \"[:upper:]\" | tr -dc \"A-Z0-9\")\"; " +
							"if [ -z \"$CLEAN_CODE\" ]; then log \"clean code is empty\"; exit 1; fi; " +

							"UID_SUB=\"$(jsonfilter -i \"$SUB_FILE\" -e \"@.uid\" 2>/dev/null || echo \"\")\"; " +
							"USI_SUB=\"$(jsonfilter -i \"$SUB_FILE\" -e \"@.usi\" 2>/dev/null || echo \"\")\"; " +
							"if [ -z \"$UID_SUB\" ] || [ -z \"$USI_SUB\" ]; then log \"uid/usi missing in subscription.json\"; exit 1; fi; " +

							"HTTP_BIN=\"\"; " +
							"if command -v curl >/dev/null 2>&1; then HTTP_BIN=\"curl\"; " +
							"elif command -v wget >/dev/null 2>&1; then HTTP_BIN=\"wget\"; " +
							"elif command -v uclient-fetch >/dev/null 2>&1; then HTTP_BIN=\"uclient-fetch\"; " +
							"fi; " +
							"if [ -z \"$HTTP_BIN\" ]; then log \"no HTTP client (curl/wget/uclient-fetch)\"; exit 1; fi; " +

							"BASE_URL=\"${API_URL%/shm/v1/public/router_public}\"; " +
							"CHECK_URL=\"$BASE_URL/shm/v1/public/router_config?uid=$UID_SUB&usi=$USI_SUB&code=$CLEAN_CODE&format=json\"; " +
							"TMP_SUB=\"$SUB_FILE.refresh.tmp\"; " +
							"TMP_ERR=\"$VERROR_FILE.refresh.tmp\"; " +

							"log \"refreshing subscription via $CHECK_URL\"; " +

							"case \"$HTTP_BIN\" in " +
								"curl) curl -fsS \"$CHECK_URL\" -o \"$TMP_SUB\" ;; " +
								"wget) wget -qO \"$TMP_SUB\" \"$CHECK_URL\" ;; " +
								"uclient-fetch) uclient-fetch -qO \"$TMP_SUB\" \"$CHECK_URL\" ;; " +
								"*) log \"unsupported HTTP_BIN=$HTTP_BIN\"; exit 1 ;; " +
							"esac || { log \"failed to fetch router_config\"; rm -f \"$TMP_SUB\"; exit 1; }; " +

							"if [ ! -s \"$TMP_SUB\" ]; then log \"router_config response is empty\"; rm -f \"$TMP_SUB\"; exit 1; fi; " +

							"OK=\"$(jsonfilter -i \"$TMP_SUB\" -e \"@.ok\" 2>/dev/null || echo \"\")\"; " +
							"if [ \"$OK\" != \"1\" ]; then " +
								"ERR=\"$(jsonfilter -i \"$TMP_SUB\" -e \"@.error\" 2>/dev/null || echo \"unknown_error\")\"; " +
								"log \"router_config error: ok=$OK, error=$ERR\"; " +
								"printf %s \"$ERR\" > \"$TMP_ERR\"; " +
								"rm -f \"$TMP_SUB\"; " +
								"mv \"$TMP_ERR\" \"$VERROR_FILE\" 2>/dev/null || true; " +
								"exit 1; " +
							"fi; " +

							"mv \"$TMP_SUB\" \"$SUB_FILE\"; " +
							"date +%s > \"$LAST_CHECK_FILE\"; " +
							"log \"subscription refreshed successfully\"; " +

							"/etc/init.d/shpun-vpn stop >/dev/null 2>&1 || true; " +
							"if [ -x \"$STATE_DIR/firewall-xray.sh\" ]; then \"$STATE_DIR/firewall-xray.sh\" stop >/dev/null 2>&1 || true; fi; " +
							"/etc/init.d/shpun-agent stop >/dev/null 2>&1 || true; " +

							"rm -f \"$STATE_DIR/xray.json\" \"$VPN_READY_FILE\" \"$VERROR_FILE\" >/dev/null 2>&1 || true; " +

							"/etc/init.d/shpun-agent start >/dev/null 2>&1 || true; " +
							"log \"refresh_connection lifecycle restarted\"; " +
						"' &";

					let p = popen(cmd);
					if (p) p.close();

					return { ok: 1, msg: "connection refresh started" };
				}
				catch (e) {
					return { ok: 0, error: String(e) };
				}
			}
		},

		/* --- RESET_VPN: полный сброс к начальному состоянию без отката версии ПО --- */
		reset_vpn: {
			call: function(req) {
				try {
					let p1 = popen("/etc/init.d/shpun-vpn stop >/dev/null 2>&1");
					if (p1) p1.close();

					let p2 = popen("/etc/init.d/shpun-agent stop >/dev/null 2>&1");
					if (p2) p2.close();

					if (exists(DIR + "/firewall-xray.sh")) {
						let p_fw = popen(DIR + "/firewall-xray.sh stop >/dev/null 2>&1");
						if (p_fw) p_fw.close();
					}

					let cmd =
						"rm -f " +
						CODE + " " +
						SUB + " " +
						DIR + "/xray.json " +
						READY + " " +
						VERROR + " " +
						LASTCHK + " " +
						">/dev/null 2>&1";

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