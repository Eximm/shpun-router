#!/bin/sh

CONF="/etc/shpun/agent.conf"
DOMAINS_FILE="/etc/shpun/routes/presets/always_vpn.domains"
CUSTOM_ROUTES_FILE="/etc/shpun/routes/custom.json"
TRACK_FILE="/tmp/shpun-always-vpn.dnsmasq"
LOGTAG="shpun-dns"

DNS_PROXY_PORT_DEFAULT=1053

log() {
	logger -t "$LOGTAG" "$*"
}

load_conf() {
	[ -f "$CONF" ] && . "$CONF"
	[ -z "$DNS_PROXY_PORT" ] && DNS_PROXY_PORT="$DNS_PROXY_PORT_DEFAULT"

	case "$DNS_PROXY_PORT" in
		''|*[!0-9]*) DNS_PROXY_PORT="$DNS_PROXY_PORT_DEFAULT" ;;
	esac
	[ "$DNS_PROXY_PORT" -gt 0 ] 2>/dev/null && [ "$DNS_PROXY_PORT" -le 65535 ] 2>/dev/null || \
		DNS_PROXY_PORT="$DNS_PROXY_PORT_DEFAULT"
}

dnsmasq_available() {
	command -v uci >/dev/null 2>&1 || return 1
	uci -q get dhcp.@dnsmasq[0] >/dev/null 2>&1
}

reload_dnsmasq() {
	/etc/init.d/dnsmasq reload >/dev/null 2>&1 || /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
}

sort_unique_file() {
	local file="$1"
	local sorted="${file}.sorted"

	sort -u "$file" > "$sorted" 2>/dev/null && mv "$sorted" "$file"
	rm -f "$sorted"
}

write_current_forwarding() {
	local out="$1"

	uci -q show dhcp.@dnsmasq[0] 2>/dev/null | \
		sed -n "s/^dhcp\\.@dnsmasq\\[0\\]\\.server='\\(.*\\)'$/\\1/p" | \
		grep -F "127.0.0.1#$DNS_PROXY_PORT" > "$out" 2>/dev/null || true
	[ -s "$out" ] && sort_unique_file "$out"
}

write_current_non_shpun_servers() {
	local out="$1"

	uci -q show dhcp.@dnsmasq[0] 2>/dev/null | \
		sed -n "s/^dhcp\\.@dnsmasq\\[0\\]\\.server='\\(.*\\)'$/\\1/p" | \
		grep -Fv "127.0.0.1#$DNS_PROXY_PORT" > "$out" 2>/dev/null || true
}

clear_forwarding() {
	local forwarding tmp changed=0

	dnsmasq_available || return 0
	[ -s "$TRACK_FILE" ] || return 0

	tmp="${TRACK_FILE}.keep.$$"
	rm -f "$tmp"
	write_current_non_shpun_servers "$tmp"

	uci -q delete dhcp.@dnsmasq[0].server && changed=1

	while IFS= read -r forwarding; do
		[ -n "$forwarding" ] || continue
		uci -q add_list "dhcp.@dnsmasq[0].server=$forwarding" && changed=1
	done < "$tmp"

	rm -f "$tmp"
	rm -f "$TRACK_FILE"

	if [ "$changed" -eq 1 ]; then
		reload_dnsmasq
		log "removed Xray DNS forwarding"
	fi
}

apply_forwarding() {
	local raw_domain domain forwarding tmp current keep changed=0

	dnsmasq_available || return 0
	[ -s "$DOMAINS_FILE" ] || return 0

	tmp="${TRACK_FILE}.tmp.$$"
	current="${TRACK_FILE}.current.$$"
	keep="${TRACK_FILE}.keep.$$"
	rm -f "$tmp"
	rm -f "$current"
	rm -f "$keep"

	append_domain_forwarding() {
		local oldifs octet numeric_labels=1
		raw_domain="$1"
		domain="$(printf '%s' "$raw_domain" | tr -d ' \t\r\n')"
		case "$domain" in
			''|\#*) return ;;
			\*.*) domain="${domain#*.}" ;;
		esac
		case "$domain" in *[!A-Za-z0-9.-]*) return ;; esac
		case "$domain" in *.*) ;; *) return ;; esac

		oldifs="$IFS"
		IFS='.'
		set -- $domain
		IFS="$oldifs"
		if [ "$#" -eq 4 ]; then
			for octet in "$@"; do
				case "$octet" in
					''|*[!0-9]*) numeric_labels=0 ;;
				esac
				[ "$octet" -le 255 ] 2>/dev/null || numeric_labels=0
			done
			[ "$numeric_labels" -eq 1 ] && return
		fi

		forwarding="/$domain/127.0.0.1#$DNS_PROXY_PORT"
		grep -Fqx "$forwarding" "$tmp" 2>/dev/null || printf '%s\n' "$forwarding" >> "$tmp"
	}

	while IFS= read -r raw_domain; do
		append_domain_forwarding "$raw_domain"
	done < "$DOMAINS_FILE"

	if [ -s "$CUSTOM_ROUTES_FILE" ] && command -v jsonfilter >/dev/null 2>&1; then
		jsonfilter -i "$CUSTOM_ROUTES_FILE" -e '@.vpn[*]' 2>/dev/null | tr -d '"' | \
		while IFS= read -r raw_domain; do
			append_domain_forwarding "$raw_domain"
		done
	fi

	[ -s "$tmp" ] && sort_unique_file "$tmp"

	[ -s "$tmp" ] || {
		rm -f "$tmp" "$current"
		return 0
	}

	write_current_forwarding "$current"

	if [ -s "$current" ] && cmp -s "$tmp" "$current" 2>/dev/null; then
		if [ ! -s "$TRACK_FILE" ] || ! cmp -s "$tmp" "$TRACK_FILE" 2>/dev/null; then
			cp "$tmp" "$TRACK_FILE" 2>/dev/null || true
		fi
		rm -f "$tmp" "$current" "$keep"
		return 0
	fi

	write_current_non_shpun_servers "$keep"

	uci -q delete dhcp.@dnsmasq[0].server && changed=1

	while IFS= read -r forwarding; do
		[ -n "$forwarding" ] || continue
		uci -q add_list "dhcp.@dnsmasq[0].server=$forwarding" && changed=1
	done < "$keep"

	while IFS= read -r forwarding; do
		[ -n "$forwarding" ] || continue
		uci -q add_list "dhcp.@dnsmasq[0].server=$forwarding" && changed=1
	done < "$tmp"

	if [ -s "$TRACK_FILE" ] && cmp -s "$tmp" "$TRACK_FILE" 2>/dev/null; then
		rm -f "$tmp"
	else
		mv "$tmp" "$TRACK_FILE"
	fi
	rm -f "$current" "$keep"

	if [ "$changed" -eq 1 ]; then
		reload_dnsmasq
		log "VPN domain DNS now uses Xray on 127.0.0.1:$DNS_PROXY_PORT"
	fi
}

load_conf

case "${1:-apply}" in
	apply) apply_forwarding ;;
	clear) clear_forwarding ;;
	*)
		echo "Usage: $0 [apply|clear]" >&2
		exit 1
		;;
esac

exit 0
