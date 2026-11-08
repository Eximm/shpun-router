import { readfile } from "fs";
import { subscription_links, server_identity, server_candidates } from "./server-groups.uc";

let links = subscription_links(json(readfile(ARGV[1])));
if (ARGV[0] == "candidates") {
	let only = ARGV[2] == "-" ? null : int(ARGV[2]);
	let skip = ARGV[3] == "-" ? -1 : int(ARGV[3]);
	let candidates = filter(server_candidates(links, only), i => i != skip);
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
