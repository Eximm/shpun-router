'use strict';

import { open, popen } from 'fs';

const DIR       = "/etc/shpun";
const CODE      = DIR + "/router_code";
const SUB       = DIR + "/subscription.json";
const SUB_URL   = DIR + "/subscription_url";
const SUB_MIRROR_URL = DIR + "/subscription_mirror_url";
const CONFIG_URL = DIR + "/router_config_url";
const READY     = DIR + "/vpn_ready";
const VERROR    = DIR + "/vpn_error";
const SELECTED_LINK = DIR + "/selected_link_index";
const CONFIG_PENDING = DIR + "/xray_config_pending";
const UDP_READY = DIR + "/udp_ready";
const HTTP_PROXY_PORT = 10809;
const TUNNEL_EXIT_IP = DIR + "/tunnel_exit_ip";
const TUNNEL_EXIT_CHECK_MS = DIR + "/tunnel_exit_check_ms";
const TUNNEL_EXIT_PING_MS = DIR + "/tunnel_exit_ping_ms";
const TUNNEL_EXIT_LAST_OK = DIR + "/tunnel_exit_last_ok";

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
const ROUTES_CIDRS    = ROUTES_DIR + "/ru.cidrs";
const ROUTER_PROFILE  = ROUTES_DIR + "/router_profile";
const ROUTING_SETTER  = DIR + "/set-routing-mode.sh";

const CUSTOM_FILE     = ROUTES_DIR + "/custom.json";
const CUSTOM_SCRIPT   = DIR + "/apply-custom-routes.sh";
const SERVER_SETTER   = DIR + "/switch-server.sh";

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

function version_part_num(v) {
	v = trim(norm(v));
	let out = "";
	for (let i = 0; i < length(v); i++) {
		let ch = substr(v, i, 1);
		if (index("0123456789", ch) < 0)
			break;
		out += ch;
	}
	return int(out || "0");
}

function compare_versions(a, b) {
	let pa = split(trim(norm(a)), ".");
	let pb = split(trim(norm(b)), ".");
	let len = length(pa) > length(pb) ? length(pa) : length(pb);
	if (len < 3)
		len = 3;

	for (let i = 0; i < len; i++) {
		let av = version_part_num(pa[i] || "0");
		let bv = version_part_num(pb[i] || "0");
		if (av < bv)
			return -1;
		if (av > bv)
			return 1;
	}

	return 0;
}

function validate_ip_cidr(entry) {
	entry = trim(entry);
	if (!entry || length(entry) == 0) return false;

	let ip, prefix;
	let slash = index(entry, "/");

	if (slash >= 0) {
		ip     = substr(entry, 0, slash);
		let prefix_raw = substr(entry, slash + 1);
		if (!prefix_raw || length(prefix_raw) == 0) return false;
		for (let i = 0; i < length(prefix_raw); i++) {
			if (index("0123456789", substr(prefix_raw, i, 1)) < 0)
				return false;
		}
		prefix = int(prefix_raw);
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

function validate_domain(entry) {
	entry = trim(entry);
	if (!entry || length(entry) == 0 || length(entry) > 253) return false;
	if (index(entry, "/") >= 0 || index(entry, ":") >= 0) return false;
	if (index(entry, "..") >= 0) return false;

	if (substr(entry, 0, 2) == "*.")
		entry = substr(entry, 2);

	if (index(entry, "*") >= 0) return false;
	if (substr(entry, 0, 1) == "." || substr(entry, length(entry) - 1) == ".") return false;
	if (index(entry, ".") < 0) return false;

	let allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-";
	let labels = split(entry, ".");
	for (let i = 0; i < length(labels); i++) {
		let label = labels[i];
		if (!label || length(label) == 0 || length(label) > 63) return false;
		if (substr(label, 0, 1) == "-" || substr(label, length(label) - 1) == "-") return false;

		for (let j = 0; j < length(label); j++) {
			if (index(allowed, substr(label, j, 1)) < 0)
				return false;
		}
	}

	return true;
}

function validate_route_entry(entry) {
	return validate_ip_cidr(entry) || validate_domain(entry);
}

function routes_have_domains(arr) {
	if (type(arr) != "array") return false;

	for (let i = 0; i < length(arr); i++) {
		let e = trim(norm(arr[i]));
		if (!validate_ip_cidr(e) && validate_domain(e))
			return true;
	}

	return false;
}

function custom_routes_have_domains(data) {
	if (!data) return false;
	return routes_have_domains(data.vpn || []) || routes_have_domains(data.direct || []);
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

function cleanup_server_name(name, proto) {
	name = trim(norm(name));
	while (index(name, "%20") >= 0) {
		let p = index(name, "%20");
		name = substr(name, 0, p) + " " + substr(name, p + 3);
	}
	name = trim(name);

	return name || "Server";
}

function parse_link_info(link, idx, selected) {
	link = trim(norm(link));

	let proto = "";
	let rest = link;
	let p = index(link, "://");
	if (p >= 0) {
		proto = substr(link, 0, p);
		rest = substr(link, p + 3);
	}

	let fragment = "";
	let hash = index(rest, "#");
	if (hash >= 0) {
		fragment = substr(rest, hash + 1);
		rest = substr(rest, 0, hash);
	}

	let no_query = rest;
	let q = index(no_query, "?");
	if (q >= 0)
		no_query = substr(no_query, 0, q);

	let hostport = no_query;
	let at = index(hostport, "@");
	if (at >= 0)
		hostport = substr(hostport, at + 1);

	let host = hostport;
	let port = "";
	let colon = -1;
	let i = length(hostport) - 1;
	while (i >= 0) {
		if (substr(hostport, i, 1) == ":") {
			colon = i;
			break;
		}
		i = i - 1;
	}
	if (colon >= 0) {
		host = substr(hostport, 0, colon);
		port = substr(hostport, colon + 1);
	}

	let name = cleanup_server_name(fragment || host || ("server " + idx), proto);

	return {
		index: idx,
		selected: selected,
		proto: proto,
		host: host,
		port: port,
		name: name
	};
}

function public_server_info(info) {
	if (!info)
		return null;

	return {
		index: info.index,
		selected: info.selected,
		proto: info.proto,
		name: info.name,
		host: info.host,
		port: info.port
	};
}

function get_current_server() {
	if (!exists(SUB))
		return null;

	let raw = readfile(SUB);
	let data = json(raw);
	if (!data)
		return null;

	let links = [];
	if (data.subscription && type(data.subscription.links) == "array")
		links = data.subscription.links;
	else if (type(data.links) == "array")
		links = data.links;

	if (length(links) < 1)
		return null;

	let selected = int(trim(readfile(SELECTED_LINK) || "0"));
	if (selected < 0 || selected >= length(links))
		selected = 0;

	return parse_link_info(links[selected], selected, true);
}

function is_safe_ping_host(host) {
	host = trim(norm(host));
	if (!host || length(host) > 253)
		return false;

	let allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-";
	for (let i = 0; i < length(host); i++) {
		if (index(allowed, substr(host, i, 1)) < 0)
			return false;
	}

	return index(host, ".") >= 0;
}

function tcp_ping_ms(host, port) {
	host = trim(norm(host));
	if (!is_safe_ping_host(host))
		return null;

	let cmd = "ping -c 1 -W 1 " + host + " 2>/dev/null | sed -n 's/.*time=\\([0-9.]*\\).*/\\1/p' | head -n 1";

	let out = trim(readcmd(cmd));
	if (!out)
		return null;

	let dot = index(out, ".");
	if (dot >= 0)
		out = substr(out, 0, dot);

	let ms = int(out);

	if (ms < 0 || ms > 10000)
		return null;

	return ms;
}

function safe_public_ip(ip) {
	ip = trim(norm(ip));
	if (!ip || length(ip) > 80)
		return "";

	let allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:.-";
	for (let i = 0; i < length(ip); i++) {
		if (index(allowed, substr(ip, i, 1)) < 0)
			return "";
	}

	return ip;
}

function seconds_to_ms(v) {
	v = trim(norm(v));
	if (!v)
		return null;

	let dot = index(v, ".");
	if (dot < 0)
		return int(v) * 1000;

	let whole = int(substr(v, 0, dot));
	let frac = substr(v, dot + 1);
	while (length(frac) < 3)
		frac += "0";
	if (length(frac) > 3)
		frac = substr(frac, 0, 3);

	return whole * 1000 + int(frac);
}

function exit_probe() {
	let proxy = "http://127.0.0.1:" + HTTP_PROXY_PORT;
	let cmd =
		"if command -v curl >/dev/null 2>&1; then " +
			"curl -sS -m 4 -x " + proxy + " -w '\\n%{time_total}' http://api.ipify.org 2>/dev/null; " +
		"else " +
			"START=$(cut -d' ' -f1 /proc/uptime 2>/dev/null); " +
			"IP=$(env http_proxy=" + proxy + " HTTP_PROXY=" + proxy + " " +
				"uclient-fetch -q -T 4 -Y on -O - http://api.ipify.org 2>/dev/null | tr -d '\\r\\n '); " +
			"RC=$?; END=$(cut -d' ' -f1 /proc/uptime 2>/dev/null); " +
			"[ \"$RC\" -eq 0 ] && [ -n \"$IP\" ] || exit 1; " +
			"printf '%s\\n' \"$IP\"; " +
			"awk -v s=\"$START\" -v e=\"$END\" 'BEGIN{printf \"%.3f\", e-s}'; " +
		"fi";

	let out = trim(readcmd(cmd));
	if (!out)
		return null;

	let lines = split(out, "\n");
	let ip = safe_public_ip(lines[0] || "");
	if (!ip)
		return null;

	let ms = null;
	if (length(lines) > 1)
		ms = seconds_to_ms(lines[1]);

	if (ms != null && (ms < 0 || ms > 30000))
		ms = null;

	return {
		ip: ip,
		check_ms: ms
	};
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
					let sub_url  = trim(readfile(SUB_URL));
					let err_raw  = readfile(VERROR);
					let fw_cur   = read_fw_current();
					let fw_last  = read_fw_latest();
					if (trim(fw_cur) && trim(fw_last) && compare_versions(fw_cur, fw_last) >= 0)
						fw_last = "";

					let res = {
						code:             code_raw || "",
						has_sub:          (sub_raw != ""),
						subscription_url: sub_url || "",
						vpn_ready:        exists(READY),
						udp_ready:        exists(UDP_READY),
						vpn_error:        err_raw || ""
					};
					let current_server = get_current_server();
					if (current_server) {
						let server_public = public_server_info(current_server);
						let exit = exit_probe();
						if (exit) {
							server_public.exit_ip = exit.ip;
							server_public.exit_check_ms = exit.check_ms;
							server_public.exit_ping_ms = tcp_ping_ms(exit.ip, 0);
						}

						if (!server_public.exit_ip) {
							let exit_ip = safe_public_ip(readfile(TUNNEL_EXIT_IP));
							if (exit_ip)
								server_public.exit_ip = exit_ip;
						}

						if (server_public.exit_check_ms == null) {
							let exit_check_ms = int(trim(readfile(TUNNEL_EXIT_CHECK_MS)));
							if (exit_check_ms >= 0 && exit_check_ms <= 30000)
								server_public.exit_check_ms = exit_check_ms;
						}

						if (server_public.exit_ping_ms == null) {
							let exit_ping_ms = int(trim(readfile(TUNNEL_EXIT_PING_MS)));
							if (exit_ping_ms >= 0 && exit_ping_ms <= 30000)
								server_public.exit_ping_ms = exit_ping_ms;
						}

						let exit_last_ok = int(trim(readfile(TUNNEL_EXIT_LAST_OK)));
						if (exit_last_ok > 0)
							server_public.exit_last_ok = exit_last_ok;

						res.current_server = server_public;
					}

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
						has_routes:     exists(ROUTES_CIDRS) && cnt > 0,
						router_profile: readfile(ROUTER_PROFILE) || ""
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

					if (mode != "full" && mode != "smart_ru" && mode != "split_ru")
						return { ok: 0, error: "invalid mode", got: mode };

					if (!exists(ROUTING_SETTER))
						return { ok: 0, error: "set-routing-mode.sh not found" };

					let p = popen(ROUTING_SETTER + " " + mode + " 2>/dev/null");
					let out = "";
					if (p) { out = p.read("all") || ""; p.close(); }

					let applied = trim(norm(readfile(ROUTES_MODE)));

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

						if (validate_route_entry(e))
							push(vpn_ok, e);
						else
							push(errors, e);
					}

					for (let i = 0; i < length(direct_in); i++) {
						let e = trim(norm(direct_in[i]));
						if (!e) continue;

						if (validate_route_entry(e))
							push(direct_ok, e);
						else
							push(errors, e);
					}

					if (length(errors) > 0)
						return {
							ok:     0,
							error:  "invalid entries (IPv4, CIDR and domains accepted)",
							errors: errors
						};

					let mkd = popen("mkdir -p " + ROUTES_DIR + " 2>/dev/null");
					if (mkd) mkd.close();

					let json_str = "{\"vpn\":" + json_array(vpn_ok) + ",\"direct\":" + json_array(direct_ok) + "}";
					let old_raw = readfile(CUSTOM_FILE) || "";
					let old_data = old_raw ? json(old_raw) : null;

					if (old_raw == json_str)
						return {
							ok:           1,
							vpn_count:    length(vpn_ok),
							direct_count: length(direct_ok),
							applied:      false,
							unchanged:    true
						};

					let f = open(CUSTOM_FILE, "w");
					if (!f)
						return { ok: 0, error: "cannot write " + CUSTOM_FILE };

					f.write(json_str);
					f.close();

					let applied = false;
					let apply_output = "";
					let warning = null;

					if (exists(CUSTOM_SCRIPT)) {
						let p = popen(CUSTOM_SCRIPT + " apply >/dev/null 2>&1 && echo ok || echo failed");
						if (p) {
							apply_output = p.read("all") || "";
							p.close();
						}
						applied = trim(norm(apply_output)) == "ok";
						if (!applied)
							warning = "routes saved; live firewall apply is pending until VPN rules are available";
					} else {
						warning = "apply-custom-routes.sh not found; routes saved but not applied to firewall";
					}

					let needs_rebuild =
						custom_routes_have_domains(old_data) ||
						routes_have_domains(vpn_ok) ||
						routes_have_domains(direct_ok);

					if (needs_rebuild) {
						let rp = popen(
							"/etc/shpun/rebuild-config-deferred.sh >/dev/null 2>&1 &"
						);
						if (rp) rp.close();
						warning = applied
							? "domain routes saved; xray config rebuild deferred to avoid dropping active VPN sessions"
							: "routes saved; live firewall apply and xray config activation are pending";
					}

					return {
						ok:           1,
						vpn_count:    length(vpn_ok),
						direct_count: length(direct_ok),
						applied:      applied,
						restarted:    false,
						pending_rebuild: needs_rebuild,
						apply_output: apply_output,
						warning:      warning
					};
				} catch(e) {
					return { ok: 0, error: String(e) };
				}
			}
		},

		servers_get: {
			call: function(req) {
				try {
					if (!exists(SUB))
						return { ok: 1, selected: 0, servers: [] };

					let raw = readfile(SUB);
					let data = json(raw);
					if (!data)
						return { ok: 0, error: "invalid subscription json" };

					let links = [];
					if (data.subscription && type(data.subscription.links) == "array")
						links = data.subscription.links;
					else if (type(data.links) == "array")
						links = data.links;

					let selected = int(trim(readfile(SELECTED_LINK) || "0"));
					if (selected < 0 || selected >= length(links))
						selected = 0;

					let servers = [];
					for (let i = 0; i < length(links); i++) {
						push(servers, public_server_info(parse_link_info(links[i], i, i == selected)));
					}

					return {
						ok: 1,
						selected: selected,
						count: length(servers),
						servers: servers
					};
				} catch(e) {
					return { ok: 0, error: String(e) };
				}
			}
		},

		server_set: {
			args: { index: 0 },
			call: function(req) {
				try {
					let idx = 0;
					if (req && req.args && req.args.index != null)
						idx = int(req.args.index);

					if (idx < 0)
						return { ok: 0, error: "invalid index", index: idx };

					if (!exists(SUB))
						return { ok: 0, error: "subscription.json not found" };

					let raw = readfile(SUB);
					let data = json(raw);
					if (!data)
						return { ok: 0, error: "invalid subscription json" };

					let links = [];
					if (data.subscription && type(data.subscription.links) == "array")
						links = data.subscription.links;
					else if (type(data.links) == "array")
						links = data.links;

					if (idx >= length(links))
						return { ok: 0, error: "index out of range", index: idx, count: length(links) };

					let current = int(trim(readfile(SELECTED_LINK) || "0"));
					if (current < 0 || current >= length(links))
						current = 0;

					if (idx == current)
						return { ok: 1, selected: idx, unchanged: true };

					if (!exists(SERVER_SETTER))
						return { ok: 0, error: "switch-server.sh not found" };

					let p = popen(SERVER_SETTER + " " + idx + " 2>/dev/null");
					let out = "";
					if (p) { out = p.read("all") || ""; p.close(); }

					if (trim(out) != "ok")
						return { ok: 0, error: "server profile validation failed", output: out };

					return { ok: 1, selected: idx };
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

					let cmd =
						"rm -f " + DIR + "/last_sub_check " + VERROR + " >/dev/null 2>&1; " +
						"/etc/init.d/shpun-agent restart >/dev/null 2>&1 &";

					let p = popen(cmd);
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
							SUB_URL + " " + SUB_MIRROR_URL + " " + CONFIG_URL + " " +
							SELECTED_LINK + " " +
							DIR + "/xray.json " + READY + " " + VERROR + " " + LASTCHK + " " +
						CONFIG_PENDING + " " + DIR + "/xray_config_active " +
						DIR + "/dns_proxy_ready " + UDP_READY +
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
