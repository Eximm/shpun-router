/* Map subscription transports to the server names shown to the user.
 * Only strip recognized transport suffixes; distinct numbered nodes stay distinct.
 */

function link_value(link) {
	if (type(link) == "string")
		return trim(link);
	if (type(link) != "object") return "";
	for (let key in ["url", "link", "uri", "vless", "hysteria2", "hy2"]) {
		let value = link[key];
		if (type(value) == "string" && match(trim(value), /^(vless|hysteria2|hy2):\/\//))
			return trim(value);
	}
	return "";
}

function subscription_links(data) {
	if (type(data?.subscription?.links) == "array") return data.subscription.links;
	return type(data?.links) == "array" ? data.links : [];
}

function server_identity(entry, idx) {
	let link = link_value(entry);
	if (!match(link, /^(vless|hysteria2|hy2):\/\//)) return null;

	let authority = split(substr(link, index(link, "://") + 3), /[\/?#]/)[0];
	let parts = split(authority, "@");
	authority = parts[length(parts) - 1];
	let end = index(authority, "]");
	let endpoint = substr(authority, 0, 1) == "[" && end > 0
		? substr(authority, 1, end - 1) : split(authority, ":")[0];
	let mark = index(link, "#");
	let label = mark >= 0 ? substr(link, mark + 1) : "";
	label = replace(label, /\+/g, " ");
	label = replace(label, /%([a-fA-F0-9]{2})/g, (m, h) => chr(int(h, 16)));
	label = trim(replace(label, /[[:cntrl:][:space:]]+/g, " "));
	if (match(label, /^(⚡[ ]*)?Автовыбор([ ]*\/|$)/) ||
		match(label, /^(⚡[ ]*)?(auto|automatic)([ ]*\/|$)/i))
		return { alias: true, name: "Автовыбор" };

	let name = trim(replace(label, /[ ]*(\/|[–—])[ ]*(xhttp|hysteria[ ]*2|hy2|reality|vless|через рф|напрямую|Через РФ|Напрямую)([ ]+(RF|RU|TLS))?$/i, ""));
	name = trim(replace(name, /[ ]+(xhttp|hysteria[ ]*2|hy2|reality|vless)([ ]+(RF|TLS))?$/i, ""));

	// The feed names Helsinki's second node FI2 in the Hysteria entry
	// and Helsinki-2 FI in the other transports.
	name = replace(name, /Helsinki FI2$/i, "Helsinki-2 FI");
	if (!name)
		return { key: "endpoint:" + lc(endpoint || ("" + idx)), name: endpoint || ("Сервер " + (idx + 1)) };

	// The flag is presentational. The city, country code and slot are the identity.
	let key = trim(replace(name, /^(🇦🇹|🇧🇪|🇨🇦|🇨🇭|🇨🇿|🇩🇪|🇫🇮|🇫🇷|🇬🇧|🇱🇻|🇳🇱|🇵🇱|🇷🇴|🇷🇺|🇸🇪|🇺🇸)[ ]*/, ""));
	return { key: "name:" + lc(key || name), name };
}

function server_groups(links) {
	let groups = [], by_key = {};
	for (let i = 0; i < length(links); i++) {
		let id = server_identity(links[i], i);
		if (!id || id.alias) continue;
		let group = by_key[id.key];
		if (!group) {
			group = { key: id.key, name: id.name, indexes: [] };
			by_key[id.key] = group;
			push(groups, group);
		}
		push(group.indexes, i);
	}
	return groups;
}

function server_candidates(links, only) {
	let groups = server_groups(links);
	if (only != null) {
		for (let group in groups)
			if (index(group.indexes, only) >= 0) return group.indexes;
		return [];
	}

	// Spread early attempts across both locations and transport types.
	// Many feeds list one transport first for every city; trying that
	// entire block before alternatives would delay recovery when blocked.
	let queues = {}, order = [], result = [];
	for (let group in groups) {
		for (let idx in group.indexes) {
			let link = link_value(links[idx]);
			let kind = match(link, /^(hy2|hysteria2):\/\//) ? "hy2" :
				(match(link, /[?&]type=xhttp([&#]|$)/i) ? "xhttp" : "vless");
			if (!queues[kind]) {
				queues[kind] = [];
				push(order, kind);
			}
			push(queues[kind], idx);
		}
	}
	let more = true, slot = 0;
	while (more) {
		more = false;
		for (let kind in order) {
			if (slot < length(queues[kind])) {
				push(result, queues[kind][slot]);
				more = true;
			}
		}
		slot++;
	}
	return result;
}


export { link_value, subscription_links, server_identity, server_groups, server_candidates };
