#!/bin/sh

CONF="/etc/shpun/agent.conf"
DOMAINS_FILE="/etc/shpun/routes/presets/always_vpn.domains"
TRACK_FILE="/etc/shpun/routes/presets/always_vpn.dnsmasq"
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
	uci commit dhcp
	/etc/init.d/dnsmasq reload >/dev/null 2>&1 || /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
}

clear_forwarding() {
	local forwarding changed=0

	dnsmasq_available || return 0
	[ -s "$TRACK_FILE" ] || return 0

	while IFS= read -r forwarding; do
		[ -n "$forwarding" ] || continue
		uci -q del_list "dhcp.@dnsmasq[0].server=$forwarding" && changed=1
	done < "$TRACK_FILE"

	rm -f "$TRACK_FILE"

	if [ "$changed" -eq 1 ]; then
		reload_dnsmasq
		log "removed Xray DNS forwarding"
	fi
}

apply_forwarding() {
	local raw_domain domain forwarding tmp changed=0

	dnsmasq_available || return 0
	[ -s "$DOMAINS_FILE" ] || return 0

	tmp="${TRACK_FILE}.tmp.$$"
	rm -f "$tmp"

	while IFS= read -r raw_domain; do
		domain="$(printf '%s' "$raw_domain" | tr -d ' \t\r\n')"
		case "$domain" in
			''|\#*) continue ;;
			\*.*) domain="${domain#*.}" ;;
		esac
		case "$domain" in *.*) ;; *) continue ;; esac

		forwarding="/$domain/127.0.0.1#$DNS_PROXY_PORT"
		grep -Fqx "$forwarding" "$tmp" 2>/dev/null || printf '%s\n' "$forwarding" >> "$tmp"
	done < "$DOMAINS_FILE"

	[ -s "$tmp" ] || {
		rm -f "$tmp"
		return 0
	}

	if [ -s "$TRACK_FILE" ]; then
		while IFS= read -r forwarding; do
			[ -n "$forwarding" ] || continue
			grep -Fqx "$forwarding" "$tmp" 2>/dev/null && continue
			uci -q del_list "dhcp.@dnsmasq[0].server=$forwarding" && changed=1
		done < "$TRACK_FILE"
	fi

	while IFS= read -r forwarding; do
		[ -n "$forwarding" ] || continue
		uci -q show dhcp.@dnsmasq[0] | grep -Fq "server='$forwarding'" && continue
		uci -q add_list "dhcp.@dnsmasq[0].server=$forwarding" && changed=1
	done < "$tmp"

	if [ -s "$TRACK_FILE" ] && cmp -s "$tmp" "$TRACK_FILE" 2>/dev/null; then
		rm -f "$tmp"
	else
		mv "$tmp" "$TRACK_FILE"
	fi

	if [ "$changed" -eq 1 ]; then
		reload_dnsmasq
		log "protected DNS now uses Xray on 127.0.0.1:$DNS_PROXY_PORT"
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
