import { server_groups, server_candidates } from "../package/shpun-router/files/etc/shpun/server-groups.uc";

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
