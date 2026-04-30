'use strict';

import { open, popen } from 'fs';

const DIR       = "/etc/shpun";
const CODE      = DIR + "/router_code";
const SUB       = DIR + "/subscription.json";
const READY     = DIR + "/vpn_ready";
const VERROR    = DIR + "/vpn_error";

const FW_CUR_NEW   = DIR + "/fw_current";
const FW_LAST_NEW  = DIR + "/fw_latest";
const FW_CUR_MAIN  = DIR + "/router_software_version";
const FW_LAST_MAIN = DIR + "/router_latest_version";
const FW_CUR_OLD   = DIR + "/router_version";

const LASTCHK   = DIR + "/last_sub_check";

const ROUTES_DIR      = DIR + "/routes";
const ROUTES_MODE     = ROUTES_DIR + "/mode";
const ROUTES_VER      = ROUTES_DIR + "/ru.version";
const ROUTES_LASTCHK  = ROUTES_DIR + "/last_check";
const ROUTES_CIDRS    = DIR + "/routes/ru.cidrs";
const ROUTING_SETTER  = DIR + "/set-routing-mode.sh";

const CUSTOM_FILE     = ROUTES_DIR + "/custom.json";
const CUSTOM_SCRIPT   = DIR + "/apply-custom-routes.sh";

function readfile(path) {
	try {
		let f = open(path, "r");
		if (!f) return "";
		let d = f.read("all");
		f.close();
		return d ? d : "";
	} catch(e) { return ""; }
}

function readcmd(cmd) {
	try {
		let p = popen(cmd);
		if (!p) return "";
		let d = p.read("all");
		p.close();
		return d ? d : "";
	} catch(e) { return ""; }
}

function norm(v) {
	if (v == null) return "";
	return '' + v;
}

function exists(path) {
	try {
		let f = open(path, "r");
		if (!f) return false;
		f.close();
		return true;
	} catch(e) { return false; }
}

function read_fw_current() {
	let v = "";
	if (exists(FW_CUR_NEW))       v = readfile(FW_CUR_NEW);
	else if (exists(FW_CUR_MAIN)) v = readfile(FW_CUR_MAIN);
	else if (exists(FW_CUR_OLD))  v = readfile(FW_CUR_OLD);
	return v || "";
}

function read_fw_latest() {
	let v = "";
	if (exists(FW_LAST_NEW))       v = readfile(FW_LAST_NEW);
	else if (exists(FW_LAST_MAIN)) v = readfile(FW_LAST_MAIN);
	return v || "";
}

function validate_ip_cidr(entry) {
	entry = trim(entry);
	if (!entry || length(entry) == 0) return false;

	let ip, prefix;
	let slash = index(entry, "/");

	if (slash >= 0) {
		ip     = substr(entry, 0, slash);
		prefix = int(substr(entry, slash + 1));
		if (prefix < 0 || prefix > 32) return false;
	} else {
		ip     = entry;
		prefix = 32;
	}

	let parts = split(ip, ".");
	if (length(parts) != 4) return false;

	for (let i = 0; i < 4; i++) {
		let octet = int(parts[i]);
		if (parts[i] != '' + octet) return false;
		if (octet < 0 || octet > 255) return false;
	}

	return true;
}

function json_array(arr) {
	let out = "[";
	for (let i = 0; i < length(arr); i++) {
		if (i > 0) out += ",";
		out += "\"" + arr[i] + "\"";
	}
	out += "]";
	return out;
}

return {
	shpun: {
		ping: {
			call: function(req) {
				return { ok: 1, msg: "shpun ucode pong" };
			}
		},

		state: {
			call: function(req) {
				try {
					let code_raw = readfile(CODE);
					let sub_raw  = readfile(SUB);
					let err_raw  = readfile(VERROR);
					let fw_cur   = read_fw_current();
					let fw_last  = read_fw_latest();

					let res = {
						code:             code_raw || "",
						has_sub:          (sub_raw != ""),
						subscription_url: sub_raw || "",
						vpn_ready:        exists(READY),
						vpn_error:        err_raw || ""
					};

					if (fw_cur  != "") res.fw_current = fw_cur;
					if (fw_last != "") res.fw_latest  = fw_last;

					return res;
				} catch(e) {
					return { ok: 0, error: String(e) };
				}
			}
		},

		routing_get: {
			call: function(req) {
				try {
					let mode = readfile(ROUTES_MODE) || "";
					let ver  = readfile(ROUTES_VER) || "";
					let ts   = readfile(ROUTES_LASTCHK) || "";
					let cnt  = 0;

					if (exists(ROUTES_CIDRS)) {
						let out = readcmd("wc -l < " + ROUTES_CIDRS + " 2>/dev/null");
						if (out != "") cnt = +out;
					}

					return {
						ok:             1,
						mode:           mode != "" ? mode : "full",
						routes_version: ver  != "" ? ver  : "0",
						last_check:     ts   != "" ? ts   : "0",
						routes_count:   cnt,
						has_routes:     exists(ROUTES_CIDRS) && cnt > 0
					};
				} catch(e) {
					return { ok: 0, error: String(e) };
				}
			}
		},

		routing_set: {
			args: { mode: "example" },
			call: function(req) {
				try {
					let mode = "";
					if (req && req.args && req.args.mode)
						mode = norm(req.args.mode);

					if (mode != "full" && mode != "split_ru")
						return { ok: 0, error: "invalid mode", got: mode };

					if (!exists(ROUTING_SETTER))
						return { ok: 0, error: "set-routing-mode.sh not found" };

					let p = popen(ROUTING_SETTER + " " + mode + " 2>/dev/null");
					let out = "";
					if (p) { out = p.read("all") || ""; p.close(); }

					let applied = norm(readfile(ROUTES_MODE)).replace(/[\r\n]+/g, "");

					if (applied != mode)
						return {
							ok: 0,
							error: "routing mode was not applied",
							requested: mode,
							applied: applied,
							output: out
						};

					return { ok: 1, mode: mode, applied_mode: applied };
				} catch(e) {
					return { ok: 0, error: String(e) };
				}
			}
		},

		custom_routes_get: {
			call: function(req) {
				try {
					if (!exists(CUSTOM_FILE))
						return { ok: 1, vpn: [], direct: [] };

					let raw = readfile(CUSTOM_FILE);
					if (!raw || length(raw) == 0)
						return { ok: 1, vpn: [], direct: [] };

					let data = json(raw);
					if (!data)
						return { ok: 1, vpn: [], direct: [] };

					return {
						ok:     1,
						vpn:    data.vpn    || [],
						direct: data.direct || []
					};
				} catch(e) {
					return { ok: 0, error: String(e) };
				}
			}
		},

		custom_routes_set: {
			args: { vpn: [], direct: [] },
			call: function(req) {
				try {
					let vpn_in    = (req && req.args && req.args.vpn)    ? req.args.vpn    : [];
					let direct_in = (req && req.args && req.args.direct) ? req.args.direct : [];

					if (type(vpn_in)    != "array") vpn_in    = [];
					if (type(direct_in) != "array") direct_in = [];

					let vpn_ok    = [];
					let direct_ok = [];
					let errors    = [];

					for (let i = 0; i < length(vpn_in); i++) {
						let e = trim(norm(vpn_in[i]));
						if (!e) continue;

						if (validate_ip_cidr(e))
							push(vpn_ok, e);
						else
							push(errors, e);
					}

					for (let i = 0; i < length(direct_in); i++) {
						let e = trim(norm(direct_in[i]));
						if (!e) continue;

						if (validate_ip_cidr(e))
							push(direct_ok, e);
						else
							push(errors, e);
					}

					if (length(errors) > 0)
						return {
							ok:     0,
							error:  "invalid entries (only IPv4 and CIDR accepted)",
							errors: errors
						};

					let mkd = popen("mkdir -p " + ROUTES_DIR + " 2>/dev/null");
					if (mkd) mkd.close();

					let json_str = "{\"vpn\":" + json_array(vpn_ok) + ",\"direct\":" + json_array(direct_ok) + "}";

					let f = open(CUSTOM_FILE, "w");
					if (!f)
						return { ok: 0, error: "cannot write " + CUSTOM_FILE };

					f.write(json_str);
					f.close();

					let applied = false;
					let apply_output = "";
					let warning = null;

					if (exists(CUSTOM_SCRIPT)) {
						let p = popen(CUSTOM_SCRIPT + " apply 2>&1");
						if (p) {
							apply_output = p.read("all") || "";
							p.close();
						}
						applied = true;
					} else {
						warning = "apply-custom-routes.sh not found — routes saved but not applied";
					}

					return {
						ok:           1,
						vpn_count:    length(vpn_ok),
						direct_count: length(direct_ok),
						applied:      applied,
						apply_output: apply_output,
						warning:      warning
					};
				} catch(e) {
					return { ok: 0, error: String(e) };
				}
			}
		},

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
				} catch(e) {
					return { ok: 0, error: String(e) };
				}
			}
		},

		ota_install: {
			call: function(req) {
				try {
					if (!exists(DIR + "/router_updater"))
						return { ok: 0, error: "router_updater not found" };

					let p = popen("/etc/shpun/router_updater >/dev/null 2>&1 &");
					if (p) p.close();

					return { ok: 1, msg: "ota install started" };
				} catch(e) {
					return { ok: 0, error: String(e) };
				}
			}
		},

		refresh_connection: {
			call: function(req) {
				try {
					if (!exists(CODE)) return { ok: 0, error: "router_code not found" };
					if (!exists(SUB))  return { ok: 0, error: "subscription.json not found" };
					if (!exists("/etc/init.d/shpun-agent"))
						return { ok: 0, error: "shpun-agent init script not found" };

					let p = popen("/etc/init.d/shpun-agent restart >/dev/null 2>&1 &");
					if (p) p.close();

					return { ok: 1, msg: "connection refresh started" };
				} catch(e) {
					return { ok: 0, error: String(e) };
				}
			}
		},

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

					let p3 = popen(
						"rm -f " + CODE + " " + SUB + " " +
						DIR + "/xray.json " + READY + " " + VERROR + " " + LASTCHK +
						" >/dev/null 2>&1"
					);
					if (p3) p3.close();

					let p4 = popen("/etc/init.d/shpun-agent start >/dev/null 2>&1 &");
					if (p4) p4.close();

					return { ok: 1, msg: "vpn reset to initial state" };
				} catch(e) {
					return { ok: 0, error: String(e) };
				}
			}
		}
	}
};