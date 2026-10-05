#!/bin/sh

CONF="/etc/shpun/agent.conf"
DOMAINS_FILE="/etc/shpun/routes/presets/always_vpn.domains"
SMART_DOMAINS_FILE="/etc/shpun/routes/presets/smart_ru.domains"
CUSTOM_ROUTES_FILE="/etc/shpun/routes/custom.json"
MODE_FILE="/etc/shpun/routes/mode"
TRACK_FILE="/tmp/shpun-always-vpn.dnsmasq"
NFTSET_CONF_FILE="/tmp/dnsmasq.d/shpun-direct-domains.conf"
NFTSET_RELOAD_FILE="/tmp/shpun-domain-direct-needs-reload"
NFTSET_SUFFIX="4#inet#shpun#domain_direct"
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

dnsmasq_nftset_available() {
	command -v dnsmasq >/dev/null 2>&1 || return 1
	dnsmasq --version 2>/dev/null | grep -Eq '(^|[[:space:]])nftset([[:space:]]|$)'
}

reload_dnsmasq() {
	/etc/init.d/dnsmasq reload >/dev/null 2>&1 && return 0
	/etc/init.d/dnsmasq restart >/dev/null 2>&1 && return 0
	log "failed to reload dnsmasq"
	return 1
}

restart_dnsmasq() {
	/etc/init.d/dnsmasq restart >/dev/null 2>&1 && return 0
	log "failed to restart dnsmasq"
	return 1
}

sort_unique_file() {
	local file="$1"
	local sorted="${file}.sorted"

	sort -u "$file" > "$sorted" 2>/dev/null && mv "$sorted" "$file"
	rm -f "$sorted"
}

write_current_forwarding() {
	local out="$1"

	uci -q get dhcp.@dnsmasq[0].server 2>/dev/null | \
		tr ' ' '\n' | \
		grep -F "127.0.0.1#$DNS_PROXY_PORT" > "$out" 2>/dev/null || true
	[ -s "$out" ] && sort_unique_file "$out"
}

write_current_non_shpun_servers() {
	local out="$1"

	uci -q get dhcp.@dnsmasq[0].server 2>/dev/null | \
		tr ' ' '\n' | \
		grep -Fv "127.0.0.1#$DNS_PROXY_PORT" > "$out" 2>/dev/null || true
}

clear_direct_nftsets() {
	local changed=0

	dnsmasq_available || return 0
	[ -e "$NFTSET_CONF_FILE" ] && changed=1
	rm -f "$NFTSET_CONF_FILE" "$NFTSET_RELOAD_FILE"
	nft flush set inet shpun domain_direct >/dev/null 2>&1 || true

	if [ "$changed" -eq 1 ]; then
		restart_dnsmasq || return 1
		log "removed direct-domain nftset routing"
	fi
}

apply_direct_nftsets() {
	local raw_domain domain entry mode tmp

	dnsmasq_available || return 0
	if ! dnsmasq_nftset_available; then
		clear_direct_nftsets
		log "dnsmasq has no nftset support; keeping safe UDP/443 fallback"
		return 0
	fi

	mkdir -p "${NFTSET_CONF_FILE%/*}" 2>/dev/null || return 1
	tmp="${NFTSET_CONF_FILE}.tmp.$$"
	rm -f "$tmp"
	: > "$tmp"

	append_direct_domain() {
		local oldifs octet numeric_labels=1
		raw_domain="$1"
		domain="$(printf '%s' "$raw_domain" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz' | tr -d ' \t\r\n')"
		case "$domain" in
			''|\#*) return ;;
			\*.*) domain="${domain#*.}" ;;
		esac
		case "$domain" in *[!a-z0-9.-]*) return ;; esac
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

		entry="nftset=/$domain/$NFTSET_SUFFIX"
		grep -Fqx "$entry" "$tmp" 2>/dev/null || printf '%s\n' "$entry" >> "$tmp"
	}

	mode="full"
	[ -f "$MODE_FILE" ] && mode="$(tr -d '\r\n ' < "$MODE_FILE")"
	if [ "$mode" = "smart_ru" ] && [ -s "$SMART_DOMAINS_FILE" ]; then
		while IFS= read -r raw_domain; do
			append_direct_domain "$raw_domain"
		done < "$SMART_DOMAINS_FILE"
	fi

	if [ -s "$CUSTOM_ROUTES_FILE" ] && command -v jsonfilter >/dev/null 2>&1; then
		jsonfilter -i "$CUSTOM_ROUTES_FILE" -e '@.direct[*]' 2>/dev/null | tr -d '"' | \
		while IFS= read -r raw_domain; do
			append_direct_domain "$raw_domain"
		done
	fi

	[ -s "$tmp" ] && sort_unique_file "$tmp"
	if cmp -s "$tmp" "$NFTSET_CONF_FILE" 2>/dev/null; then
		if [ -e "$NFTSET_RELOAD_FILE" ]; then
			restart_dnsmasq || {
				rm -f "$tmp"
				return 1
			}
			rm -f "$NFTSET_RELOAD_FILE"
			log "reloaded DNS to repopulate empty direct-domain nftset"
		fi
		rm -f "$tmp"
		return 0
	fi

	nft flush set inet shpun domain_direct >/dev/null 2>&1 || true
	if [ -s "$tmp" ]; then
		mv "$tmp" "$NFTSET_CONF_FILE" || return 1
	else
		rm -f "$tmp" "$NFTSET_CONF_FILE"
	fi

	if ! restart_dnsmasq; then
		rm -f "$NFTSET_CONF_FILE"
		restart_dnsmasq >/dev/null 2>&1 || true
		return 1
	fi
	rm -f "$NFTSET_RELOAD_FILE"
	log "direct domains now populate nft set inet shpun domain_direct"
}

clear_forwarding() {
	local forwarding tmp changed=0

	dnsmasq_available || return 0

	tmp="${TRACK_FILE}.keep.$$"
	rm -f "$tmp"
	write_current_non_shpun_servers "$tmp"

	if ! uci -q show dhcp.@dnsmasq[0] 2>/dev/null | grep -Fq "127.0.0.1#$DNS_PROXY_PORT"; then
		rm -f "$tmp" "$TRACK_FILE"
		return 0
	fi

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
	apply)
		apply_forwarding
		apply_direct_nftsets
		;;
	clear)
		clear_forwarding
		clear_direct_nftsets
		;;
	*)
		echo "Usage: $0 [apply|clear]" >&2
		exit 1
		;;
esac

exit 0
