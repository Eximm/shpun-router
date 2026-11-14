import { readfile } from "fs";
import { link_value, subscription_links, server_identity, server_candidates, server_groups, is_ru_exit, transport_rank, compare_delay } from "./server-groups.uc";

let links = subscription_links(json(readfile(ARGV[1])));

// representatives SUB SCORES: one index per server for background measuring,
// the transport that was best before (relays only when clearly faster, see
// compare_delay), else the most direct one (transport_rank); RU exits last.
if (ARGV[0] == "representatives") {
	let scores = {};
	for (let line in split(readfile(ARGV[2]) || "", "\n")) {
		let p = split(trim(line), " ");
		if (length(p) == 3 && p[1] != "fail") scores[p[0]] = +p[1];
	}
	let picks = [], ru = [];
	for (let group in server_groups(links)) {
		let pick = group.indexes[0], best = null;
		for (let idx in group.indexes)
			if (transport_rank(links[idx]) < transport_rank(links[pick])) pick = idx;
		for (let idx in group.indexes) {
			let s = scores["" + idx];
			if (s == null) continue;
			s = compare_delay(links[idx], s);
			if (best == null || s < best) { best = s; pick = idx; }
		}
		push(is_ru_exit(group) ? ru : picks, pick);
	}
	picks = [ ...picks, ...ru ];
	print(join(" ", picks));
	exit(length(picks) ? 0 : 1);
}
// endpoints SUB: "index host relay kind" per link; relay=1 goes through the RU
// gateway, kind is xhttp or tcp.
if (ARGV[0] == "endpoints") {
	for (let i = 0; i < length(links); i++) {
		let link = link_value(links[i]);
		let authority = split(substr(link, index(link, "://") + 3), /[\/?#]/)[0];
		let parts = split(authority, "@");
		authority = parts[length(parts) - 1];
		let end = index(authority, "]");
		let host = substr(authority, 0, 1) == "[" && end > 0 ? substr(authority, 1, end - 1) : split(authority, ":")[0];
		let kind = match(link, /[?&]type=xhttp([&#]|$)/i) ? "xhttp" : "tcp";
		if (host) print(i, " ", host, " ", transport_rank(links[i]) == 3 ? 1 : 0, " ", kind, "\n");
	}
	exit(0);
}
// candidates SUB ONLY SKIP [FIRST] [EXCLUDE_RU]
// FIRST moves an allowed index to the front, so recovery re-checks the
// active connection before spending the deadline on alternatives.
if (ARGV[0] == "candidates") {
	let only = ARGV[2] == "-" ? null : int(ARGV[2]);
	let skip = ARGV[3] == "-" ? -1 : int(ARGV[3]);
	let first = (ARGV[4] == null || ARGV[4] == "-") ? -1 : int(ARGV[4]);
	let candidates = filter(server_candidates(links, only, ARGV[5] == "1"), i => i != skip);
	// Direct connections first; relays share one RU gateway and are the fallback.
	// Among relays XHTTP goes first: bursts of Reality connections to the gateway
	// get the subscriber's path to it dropped by some providers for minutes.
	let relay = i => transport_rank(links[i]) == 3;
	let xhttp = i => !!match(link_value(links[i]), /[?&]type=xhttp([&#]|$)/i);
	candidates = [ ...filter(candidates, i => !relay(i)),
		...filter(candidates, i => relay(i) && xhttp(i)), ...filter(candidates, i => relay(i) && !xhttp(i)) ];
	if (first >= 0 && index(candidates, first) >= 0)
		candidates = [ first, ...filter(candidates, i => i != first) ];
	print(join(" ", candidates));
	exit(length(candidates) ? 0 : 1);
}

if (ARGV[0] == "remap") {
	let before = int(ARGV[2]);
	let desired = server_identity(links[before], before);
	if (!desired || desired.alias) exit(1);
	let next = subscription_links(json(readfile(ARGV[3])));
	let preferred = int(ARGV[4]);
	let mapped = server_identity(next[preferred], preferred);
	if (mapped && mapped.key == desired.key) {
		print(preferred);
		exit(0);
	}
	for (let i = 0; i < length(next); i++) {
		let candidate = server_identity(next[i], i);
		if (candidate && candidate.key == desired.key) {
			print(i);
			exit(0);
		}
	}
}
exit(1);
