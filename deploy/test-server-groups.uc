import { server_groups, server_candidates, is_ru_exit, transport_rank, compare_delay } from "../package/shpun-router/files/etc/shpun/server-groups.uc";

let links = [
	"vless://fixture@gateway.example:443?type=xhttp#⚡%20Автовыбор%20/%20XHTTP%20RF",
	"vless://fixture@gateway.example:443?type=xhttp#🇫🇮%20Helsinki%20FI%20/%20XHTTP%20RF",
	"vless://fixture@gateway.example:443?type=xhttp#🇫🇮%20Helsinki-2%20FI%20/%20XHTTP%20RF",
	{ url: "hysteria2://fixture@fi.example:443#🇫🇮%20Helsinki%20FI%20/%20Hysteria%202" },
	"hy2://fixture@fi2.example:443#🇫🇮%20Helsinki%20FI2%20/%20Hysteria%202",
	"vless://fixture@gateway.example:443?security=reality#Helsinki%20FI%20/%20Через%20РФ"
];
let groups = server_groups(links);
function check(ok, message) { if (!ok) die(message); }
check(length(groups) == 2, "expected two physical servers");
check(join(",", groups[0].indexes) == "1,3,5", "Helsinki must include three transports");
check(join(",", groups[1].indexes) == "2,4", "FI2 alias must keep Helsinki-2 separate");
check(join(",", server_candidates(links, 3)) == "1,3,5", "pin must stay inside the selected server");
check(join(",", server_candidates(links, null)) == "1,3,5,2,4", "global search must interleave transports");
print("PASS grouped feed and transport diversity\n");

// Automatic search never selects a Russian exit; relays "Через РФ" stay allowed.
let ru_links = [
	"hy2://fixture@msk.example:443#🇷🇺%20Moscow%20RU%20/%20Hysteria%202",
	"vless://fixture@relay.example:443?security=reality#🇵🇱%20Warsaw%20PL%20/%20Через%20РФ",
	"hy2://fixture@spb.example:443#🇷🇺%20St.Petersburg%20RU%20/%20Hysteria%202",
	"hy2://fixture@pl.example:443#🇵🇱%20Warsaw%20PL%20/%20Hysteria%202"
];
check(join(",", server_candidates(ru_links, null, true)) == "1,3", "auto must skip RU exits but keep RU relays");
check(join(",", server_candidates(ru_links, null, false)) == "0,1,3,2", "exclusion is opt-in");
check(join(",", server_candidates(ru_links, 0, true)) == "0", "a pinned RU server stays selectable");
check(is_ru_exit({ key: "name:moscow ru", name: "🇷🇺 Moscow RU" }) && !is_ru_exit({ key: "name:warsaw pl", name: "🇵🇱 Warsaw PL" }), "RU exit detection");
print("PASS RU exits excluded from automatic search\n");
check(transport_rank(links[3]) == 0 && transport_rank(links[1]) == 3 && transport_rank(links[5]) == 3, "relays rank after direct Hysteria 2");
check(transport_rank("vless://f@rush.example:443?security=reality#Prague%20CZ%20/%20Reality") == 1, "direct Reality before XHTTP");
check(transport_rank("vless://f@cz.example:443?type=xhttp#Prague%20CZ%20/%20XHTTP") == 2, "direct XHTTP before relays");
print("PASS transports ranked direct first\n");
// A relay wins only when at least 30% and 25 ms faster than a direct connection.
check(compare_delay(links[3], 0.050) == 0.050, "direct delay compared as measured");
check(compare_delay(links[1], 0.095) > 0.098, "relay 3 ms faster loses to direct");
check(compare_delay(links[1], 0.010) > 5.0, "relay is a reserve: even a much faster relay loses to a slow direct");
check(compare_delay(links[1], 0.010) < compare_delay(links[1], 0.020), "relays still compare among themselves");
print("PASS direct connections preferred over relays\n");

// The panel renamed relays to "RAW TLS RF": they must join their city, not form new servers.
let raw_links = [
	"hysteria2://fixture@fi.example:443#%F0%9F%87%AB%F0%9F%87%AE%20Helsinki%20FI%20%2F%20Hysteria%202",
	"vless://fixture@ruin.example:443?type=xhttp#%F0%9F%87%AB%F0%9F%87%AE%20Helsinki%20FI%20%2F%20XHTTP%20RF",
	"vless://fixture@rt1.example:443?type=tcp&security=tls#%F0%9F%87%AB%F0%9F%87%AE%20Helsinki%20FI%20%2F%20RAW%20TLS%20RF",
	"vless://fixture@rt14.example:443?type=tcp&security=tls#%F0%9F%87%AB%F0%9F%87%AE%20Helsinki-2%20FI%20%2F%20RAW%20TLS%20RF",
	"hy2://fixture@fi2.example:443#%F0%9F%87%AB%F0%9F%87%AE%20Helsinki%20FI2%20%2F%20Hysteria%202",
	"hy2://fixture@msk.example:443#%F0%9F%87%B7%F0%9F%87%BA%20Moscow%20RU%20%2F%20Hysteria%202"
];
let raw_groups = server_groups(raw_links);
check(length(raw_groups) == 3, "RAW TLS RF must not create extra servers");
check(join(",", raw_groups[0].indexes) == "0,1,2" && join(",", raw_groups[1].indexes) == "3,4", "RAW TLS RF joins its city");
check(raw_groups[2].name == "🇷🇺 Moscow RU", "country code RU stays in the name");
check(transport_rank(raw_links[2]) == 3, "RAW TLS RF is a relay");
print("PASS RAW TLS relays grouped with their city\n");
