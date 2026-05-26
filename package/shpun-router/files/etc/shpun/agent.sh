#!/bin/sh
#
# shpun-agent (Xray + Shadowsocks/VLESS transparent edition)
#

STATE_DIR="/etc/shpun"
CODE_FILE="$STATE_DIR/router_code"
SUB_FILE="$STATE_DIR/subscription.json"
SUB_URL_FILE="$STATE_DIR/subscription_url"
CONFIG_URL_FILE="$STATE_DIR/router_config_url"
UPDATE_URL_FILE="$STATE_DIR/router_update_url"
UPDATE_MIN_VERSION_FILE="$STATE_DIR/router_min_version"
FW_LATEST_FILE="$STATE_DIR/fw_latest"
ROUTER_LATEST_VERSION_FILE="$STATE_DIR/router_latest_version"
VPN_READY_FILE="$STATE_DIR/vpn_ready"
LAST_CHECK_FILE="$STATE_DIR/last_sub_check"
CONF="$STATE_DIR/agent.conf"

VERROR_FILE="$STATE_DIR/vpn_error"
CONFIG_ACTIVE_FILE="$STATE_DIR/xray_config_active"
CONFIG_PENDING_FILE="$STATE_DIR/xray_config_pending"
DNS_PROXY_READY_FILE="$STATE_DIR/dns_proxy_ready"
UDP_READY_FILE="$STATE_DIR/udp_ready"

LOG_TAG="shpun-agent"

API_URL_DEFAULT="https://bill.shpyn.online/shm/v1/public/router_public"
SUB_CHECK_INTERVAL_DEFAULT=21600

MIN_UPTIME_DEFAULT=120
NET_FAIL_TIMEOUT_DEFAULT=180
MAIN_LOOP_SLEEP_DEFAULT=30
DISABLE_LAN_IPV6_DEFAULT=1
REDIR_PORT_DEFAULT=12345
TPROXY_PORT_DEFAULT=12346
TPROXY_MARK_DEFAULT=233
HTTP_PROXY_PORT_DEFAULT=10809
DNS_PROXY_PORT_DEFAULT=1053
TUNNEL_PROBE_INTERVAL_DEFAULT=60
TUNNEL_FAIL_TIMEOUT_DEFAULT=180
TUNNEL_PROBE_URL_DEFAULT="http://api.ipify.org"

ROUTES_DIR="$STATE_DIR/routes"
ROUTES_CIDRS_FILE="$ROUTES_DIR/ru.cidrs"
ROUTES_VER_FILE="$ROUTES_DIR/ru.version"
ROUTES_SHA_FILE="$ROUTES_DIR/ru.sha256"
ROUTES_LAST_CHECK_FILE="$ROUTES_DIR/last_check"
ROUTES_MODE_FILE="$ROUTES_DIR/mode"
PRESETS_DIR="$ROUTES_DIR/presets"
SMART_RU_DOMAINS_FILE="$PRESETS_DIR/smart_ru.domains"
SMART_RU_DOMAINS_VER_FILE="$PRESETS_DIR/smart_ru.domains.version"
SMART_RU_DOMAINS_SHA_FILE="$PRESETS_DIR/smart_ru.domains.sha256"
ALWAYS_VPN_DOMAINS_FILE="$PRESETS_DIR/always_vpn.domains"
ALWAYS_VPN_CIDRS_FILE="$PRESETS_DIR/always_vpn.cidrs"
ALWAYS_VPN_DOMAINS_VER_FILE="$PRESETS_DIR/always_vpn.domains.version"
ALWAYS_VPN_DOMAINS_SHA_FILE="$PRESETS_DIR/always_vpn.domains.sha256"
ALWAYS_VPN_CIDRS_VER_FILE="$PRESETS_DIR/always_vpn.cidrs.version"
ALWAYS_VPN_CIDRS_SHA_FILE="$PRESETS_DIR/always_vpn.cidrs.sha256"

ROUTES_URL_BASE_DEFAULT="https://spb.shpyn.online/files/routes"
ROUTES_CHECK_INTERVAL_DEFAULT=43200

HTTP_BIN=""

log() {
	logger -t "$LOG_TAG" "$*"
}

get_routing_mode() {
	mode="$(cat "$ROUTES_MODE_FILE" 2>/dev/null | tr -d '\r\n ' || true)"
	[ -z "$mode" ] && mode="full"
	echo "$mode"
}

ensure_state_dir() {
	[ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null || true
}

ensure_routes_dir() {
	[ -d "$ROUTES_DIR" ] || mkdir -p "$ROUTES_DIR" 2>/dev/null || true
	[ -d "$PRESETS_DIR" ] || mkdir -p "$PRESETS_DIR" 2>/dev/null || true

	# ВАЖНО: режим создаём только при первой установке.
	# При обновлении пакета пользовательский выбор не перетираем.
	[ -f "$ROUTES_MODE_FILE" ]       || echo "full" > "$ROUTES_MODE_FILE"
	[ -f "$ROUTES_VER_FILE" ]        || echo "0"    > "$ROUTES_VER_FILE"
	[ -f "$ROUTES_LAST_CHECK_FILE" ] || echo "0"    > "$ROUTES_LAST_CHECK_FILE"
	[ -f "$ROUTES_SHA_FILE" ]        || : > "$ROUTES_SHA_FILE"
	[ -f "$ROUTES_CIDRS_FILE" ]      || : > "$ROUTES_CIDRS_FILE"
	[ -f "$SMART_RU_DOMAINS_VER_FILE" ] || echo "0" > "$SMART_RU_DOMAINS_VER_FILE"
	[ -f "$SMART_RU_DOMAINS_SHA_FILE" ] || : > "$SMART_RU_DOMAINS_SHA_FILE"
	[ -f "$SMART_RU_DOMAINS_FILE" ]     || : > "$SMART_RU_DOMAINS_FILE"
	[ -f "$ALWAYS_VPN_CIDRS_FILE" ]     || : > "$ALWAYS_VPN_CIDRS_FILE"
	[ -f "$ALWAYS_VPN_DOMAINS_VER_FILE" ] || echo "0" > "$ALWAYS_VPN_DOMAINS_VER_FILE"
	[ -f "$ALWAYS_VPN_DOMAINS_SHA_FILE" ] || : > "$ALWAYS_VPN_DOMAINS_SHA_FILE"
	[ -f "$ALWAYS_VPN_CIDRS_VER_FILE" ]   || echo "0" > "$ALWAYS_VPN_CIDRS_VER_FILE"
	[ -f "$ALWAYS_VPN_CIDRS_SHA_FILE" ]   || : > "$ALWAYS_VPN_CIDRS_SHA_FILE"
	if [ ! -f "$ALWAYS_VPN_DOMAINS_FILE" ]; then
		cat > "$ALWAYS_VPN_DOMAINS_FILE" <<'EOF'
telegram.org
*.telegram.org
t.me
*.t.me
telegram.me
*.telegram.me
telegram-cdn.org
*.telegram-cdn.org
cdn-telegram.org
*.cdn-telegram.org
telesco.pe
*.telesco.pe
telegra.ph
*.telegra.ph
tdesktop.com
*.tdesktop.com
discord.com
*.discord.com
discord.gg
*.discord.gg
discordapp.com
*.discordapp.com
discordapp.net
*.discordapp.net
discord.media
*.discord.media
discordcdn.com
*.discordcdn.com
signal.org
*.signal.org
signal.me
*.signal.me
signal.art
*.signal.art
whatsapp.com
*.whatsapp.com
whatsapp.net
*.whatsapp.net
wa.me
*.wa.me
viber.com
*.viber.com
viber.co
*.viber.co
viber.me
*.viber.me
facetime.apple.com
*.facetime.apple.com
snapchat.com
*.snapchat.com
sc-cdn.net
*.sc-cdn.net
EOF
	fi
	for protected_domain in \
		discord.media '*.discord.media' discordcdn.com '*.discordcdn.com' \
		signal.art '*.signal.art' wa.me '*.wa.me' \
		viber.com '*.viber.com' viber.co '*.viber.co' viber.me '*.viber.me' \
		facetime.apple.com '*.facetime.apple.com' \
		snapchat.com '*.snapchat.com' sc-cdn.net '*.sc-cdn.net'; do
		grep -Fqx "$protected_domain" "$ALWAYS_VPN_DOMAINS_FILE" 2>/dev/null || \
			printf '%s\n' "$protected_domain" >> "$ALWAYS_VPN_DOMAINS_FILE"
	done
	if [ ! -s "$ALWAYS_VPN_CIDRS_FILE" ]; then
		cat > "$ALWAYS_VPN_CIDRS_FILE" <<'EOF'
91.108.4.0/22
91.108.8.0/22
91.108.12.0/22
91.108.16.0/22
91.108.20.0/22
91.108.56.0/22
149.154.160.0/20
EOF
	fi
}

apply_protected_dns_forwarding() {
	[ -s "$DNS_PROXY_READY_FILE" ] || return 0
	[ -x /etc/shpun/dns-xray.sh ] || return 0
	/etc/shpun/dns-xray.sh apply || log "failed to synchronize DNS forwarding through Xray"
}

ensure_router_code() {
	if [ -s "$CODE_FILE" ]; then
		return 0
	fi

	if [ -x /etc/shpun/gen_code.sh ]; then
		local new_code
		new_code="$(/etc/shpun/gen_code.sh 2>/dev/null | tr -d '\r\n ' || true)"
		if [ -n "$new_code" ]; then
			printf '%s\n' "$new_code" >"$CODE_FILE"
			log "generated new router code: $new_code"
			return 0
		fi
	fi

	log "failed to generate router code"
	return 1
}

detect_http_client() {
	if command -v curl >/dev/null 2>&1; then
		HTTP_BIN="curl"
	elif command -v wget >/dev/null 2>&1; then
		HTTP_BIN="wget"
	elif command -v uclient-fetch >/dev/null 2>&1; then
		HTTP_BIN="uclient-fetch"
	else
		HTTP_BIN=""
	fi
}

http_get_to_file() {
	local url="$1"
	local out="$2"

	case "$HTTP_BIN" in
		curl) curl -fsS "$url" -o "$out" ;;
		wget) wget -qO "$out" "$url" ;;
		uclient-fetch) uclient-fetch -qO "$out" "$url" ;;
		*) return 1 ;;
	esac
}

http_get_stdout() {
	local url="$1"

	case "$HTTP_BIN" in
		curl) curl -fsS "$url" ;;
		wget) wget -qO- "$url" ;;
		uclient-fetch) uclient-fetch -qO- "$url" ;;
		*) return 1 ;;
	esac
}

has_tproxy() {
	command -v nft >/dev/null 2>&1 || return 1

	nft delete table inet shpun_tproxy_test >/dev/null 2>&1 || true
	nft 'add table inet shpun_tproxy_test' >/dev/null 2>&1 || return 1

	nft 'add chain inet shpun_tproxy_test c { type filter hook prerouting priority mangle; policy accept; }' >/dev/null 2>&1 || {
		nft delete table inet shpun_tproxy_test >/dev/null 2>&1
		return 1
	}

	nft 'add rule inet shpun_tproxy_test c meta l4proto udp tproxy ip to :12346 meta mark set 0xe9' >/dev/null 2>&1
	rc=$?

	nft delete table inet shpun_tproxy_test >/dev/null 2>&1
	return "$rc"
}

ensure_tproxy_modules() {
	has_tproxy && {
		log "tproxy: available"
		return 0
	}

	modprobe nft_tproxy 2>/dev/null || true
	modprobe nf_tproxy_ipv4 2>/dev/null || true
	modprobe nf_tproxy_ipv6 2>/dev/null || true

	has_tproxy && {
		log "tproxy: available after modprobe"
		return 0
	}

	command -v opkg >/dev/null 2>&1 || {
		log "tproxy: opkg not found, UDP will stay disabled"
		return 1
	}

	log "tproxy: missing, trying to install kmod-nft-tproxy"

	if ! opkg update >/dev/null 2>&1; then
		log "tproxy: opkg update failed, UDP will stay disabled"
		return 1
	fi

	if ! opkg install kmod-nft-tproxy >/dev/null 2>&1; then
		log "tproxy: failed to install kmod-nft-tproxy, UDP will stay disabled"
		return 1
	fi

	has_tproxy && {
		log "tproxy: installed successfully"
		return 0
	}

	log "tproxy: package installed, but nft tproxy rule is still unavailable"
	return 1
}

detect_engine_arch() {
	local arch

	if [ -f /etc/openwrt_release ]; then
		. /etc/openwrt_release
		arch="$DISTRIB_ARCH"
	fi

	if [ -z "$arch" ] && command -v opkg >/dev/null 2>&1; then
		arch="$(opkg print-architecture 2>/dev/null | awk '$1=="arch"{print $2}' | tail -n1)"
	fi

	case "$arch" in
		mips_24kc) echo "mips_24kc" ;;
		mipsel_24kc|ramips*|mipsel*) echo "mipsel_24kc" ;;
		arm_cortex-a7|arm_cortex-a9|arm_mpcore|armv7*) echo "armv7" ;;
		aarch64*|arm64*) echo "aarch64" ;;
		x86_64) echo "amd64" ;;
		*)
			log "detect_engine_arch: unknown arch '$arch', fallback to mips_24kc"
			echo "mips_24kc"
			;;
	esac
}

build_engine_url() {
	if [ -n "$ENGINE_URL" ]; then
		echo "$ENGINE_URL"
		return 0
	fi

	if [ -z "$ENGINE_BASE_URL" ]; then
		log "build_engine_url: ENGINE_BASE_URL not set and ENGINE_URL empty"
		echo ""
		return 1
	fi

	ENGINE_ARCH="$(detect_engine_arch)"

	if [ -n "$ENGINE_VERSION" ]; then
		echo "${ENGINE_BASE_URL}/xray-${ENGINE_ARCH}-${ENGINE_VERSION}"
	else
		echo "${ENGINE_BASE_URL}/xray-${ENGINE_ARCH}"
	fi
}

load_conf() {
	[ -f "$CONF" ] && . "$CONF"

	[ -z "$API_URL" ]               && API_URL="$API_URL_DEFAULT"
	[ -z "$ENGINE_BIN" ]            && ENGINE_BIN="/tmp/xray"
	[ -z "$ENGINE_CONFIG" ]         && ENGINE_CONFIG="/etc/shpun/xray.json"
	[ -z "$SUB_CHECK_INTERVAL" ]    && SUB_CHECK_INTERVAL="$SUB_CHECK_INTERVAL_DEFAULT"

	[ -z "$MIN_UPTIME" ]            && MIN_UPTIME="$MIN_UPTIME_DEFAULT"
	[ -z "$NET_FAIL_TIMEOUT" ]      && NET_FAIL_TIMEOUT="$NET_FAIL_TIMEOUT_DEFAULT"
	[ -z "$MAIN_LOOP_SLEEP" ]       && MAIN_LOOP_SLEEP="$MAIN_LOOP_SLEEP_DEFAULT"
	[ -z "$DISABLE_LAN_IPV6" ]      && DISABLE_LAN_IPV6="$DISABLE_LAN_IPV6_DEFAULT"
	[ -z "$REDIR_PORT" ]            && REDIR_PORT="$REDIR_PORT_DEFAULT"
	[ -z "$TPROXY_PORT" ]           && TPROXY_PORT="$TPROXY_PORT_DEFAULT"
	[ -z "$TPROXY_MARK" ]           && TPROXY_MARK="$TPROXY_MARK_DEFAULT"
	[ -z "$HTTP_PROXY_PORT" ]       && HTTP_PROXY_PORT="$HTTP_PROXY_PORT_DEFAULT"
	[ -z "$DNS_PROXY_PORT" ]        && DNS_PROXY_PORT="$DNS_PROXY_PORT_DEFAULT"
	[ -z "$TUNNEL_PROBE_INTERVAL" ] && TUNNEL_PROBE_INTERVAL="$TUNNEL_PROBE_INTERVAL_DEFAULT"
	[ -z "$TUNNEL_FAIL_TIMEOUT" ]   && TUNNEL_FAIL_TIMEOUT="$TUNNEL_FAIL_TIMEOUT_DEFAULT"
	[ -z "$TUNNEL_PROBE_URL" ]      && TUNNEL_PROBE_URL="${KEEPALIVE_URL:-$TUNNEL_PROBE_URL_DEFAULT}"

	case "$REDIR_PORT" in
		''|*[!0-9]*) REDIR_PORT="$REDIR_PORT_DEFAULT" ;;
	esac
	[ "$REDIR_PORT" -gt 0 ] 2>/dev/null && [ "$REDIR_PORT" -le 65535 ] 2>/dev/null || \
		REDIR_PORT="$REDIR_PORT_DEFAULT"
	case "$TPROXY_PORT" in
		''|*[!0-9]*) TPROXY_PORT="$TPROXY_PORT_DEFAULT" ;;
	esac
	[ "$TPROXY_PORT" -gt 0 ] 2>/dev/null && [ "$TPROXY_PORT" -le 65535 ] 2>/dev/null || \
		TPROXY_PORT="$TPROXY_PORT_DEFAULT"
	case "$TPROXY_MARK" in
		''|*[!0-9]*) TPROXY_MARK="$TPROXY_MARK_DEFAULT" ;;
	esac
	case "$HTTP_PROXY_PORT" in
		''|*[!0-9]*) HTTP_PROXY_PORT="$HTTP_PROXY_PORT_DEFAULT" ;;
	esac
	[ "$HTTP_PROXY_PORT" -gt 0 ] 2>/dev/null && [ "$HTTP_PROXY_PORT" -le 65535 ] 2>/dev/null || \
		HTTP_PROXY_PORT="$HTTP_PROXY_PORT_DEFAULT"
	case "$DNS_PROXY_PORT" in
		''|*[!0-9]*) DNS_PROXY_PORT="$DNS_PROXY_PORT_DEFAULT" ;;
	esac
	[ "$DNS_PROXY_PORT" -gt 0 ] 2>/dev/null && [ "$DNS_PROXY_PORT" -le 65535 ] 2>/dev/null || \
		DNS_PROXY_PORT="$DNS_PROXY_PORT_DEFAULT"
	case "$TUNNEL_PROBE_INTERVAL" in
		''|*[!0-9]*) TUNNEL_PROBE_INTERVAL="$TUNNEL_PROBE_INTERVAL_DEFAULT" ;;
	esac
	[ "$TUNNEL_PROBE_INTERVAL" -gt 0 ] 2>/dev/null || TUNNEL_PROBE_INTERVAL="$TUNNEL_PROBE_INTERVAL_DEFAULT"
	case "$TUNNEL_FAIL_TIMEOUT" in
		''|*[!0-9]*) TUNNEL_FAIL_TIMEOUT="$TUNNEL_FAIL_TIMEOUT_DEFAULT" ;;
	esac
	[ "$TUNNEL_FAIL_TIMEOUT" -ge "$TUNNEL_PROBE_INTERVAL" ] 2>/dev/null || \
		TUNNEL_FAIL_TIMEOUT="$TUNNEL_PROBE_INTERVAL"

	[ -z "$ROUTES_URL_BASE" ]       && ROUTES_URL_BASE="$ROUTES_URL_BASE_DEFAULT"
	[ -z "$ROUTES_CHECK_INTERVAL" ] && ROUTES_CHECK_INTERVAL="$ROUTES_CHECK_INTERVAL_DEFAULT"

	if [ -z "$PING_HOST" ]; then
		if [ -n "$DNS_ADDR1" ]; then
			PING_HOST="$DNS_ADDR1"
		else
			PING_HOST="8.8.8.8"
		fi
	fi

	if [ -z "$ENGINE_URL" ]; then
		ENGINE_URL="$(build_engine_url)"
	fi
}

ensure_lan_ipv6_disabled() {
	[ "$DISABLE_LAN_IPV6" = "1" ] || return 0
	command -v uci >/dev/null 2>&1 || return 0

	changed=0

	ra="$(uci -q get dhcp.lan.ra 2>/dev/null || true)"
	dhcpv6="$(uci -q get dhcp.lan.dhcpv6 2>/dev/null || true)"
	ndp="$(uci -q get dhcp.lan.ndp 2>/dev/null || true)"
	ip6assign="$(uci -q get network.lan.ip6assign 2>/dev/null || true)"

	if [ "$ra" != "disabled" ]; then
		uci -q set dhcp.lan.ra='disabled' && changed=1
	fi
	if [ "$dhcpv6" != "disabled" ]; then
		uci -q set dhcp.lan.dhcpv6='disabled' && changed=1
	fi
	if [ "$ndp" != "disabled" ]; then
		uci -q set dhcp.lan.ndp='disabled' && changed=1
	fi
	if [ -n "$ip6assign" ] && [ "$ip6assign" != "0" ]; then
		uci -q set network.lan.ip6assign='0' && changed=1
	fi

	[ "$changed" -eq 1 ] || return 0

	uci -q commit dhcp 2>/dev/null || true
	uci -q commit network 2>/dev/null || true
	/etc/init.d/odhcpd restart 2>/dev/null || true
	/etc/init.d/network reload 2>/dev/null || true

	log "LAN IPv6 disabled to prevent VPN bypass"
}

get_code() {
	if [ -s "$CODE_FILE" ]; then
		CODE="$(cat "$CODE_FILE" 2>/dev/null || true)"
	else
		if [ -x /etc/shpun/gen_code.sh ]; then
			CODE="$(/etc/shpun/gen_code.sh 2>/dev/null | head -n1 || true)"
		fi
		[ -n "$CODE" ] && echo "$CODE" >"$CODE_FILE"
	fi

	CODE="$(printf '%s' "$CODE" | tr -d '\r\n')"

	if [ -z "$CODE" ]; then
		log "router code is empty"
		return 1
	fi

	CLEAN_CODE="$(printf '%s' "$CODE" | tr '[:lower:]' '[:upper:]' | tr -dc 'A-Z0-9')"

	if [ -z "$CLEAN_CODE" ]; then
		log "clean code is empty after filtering: $CODE"
		return 1
	fi

	return 0
}

calc_sha256_file() {
	local file="$1"

	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$file" 2>/dev/null | awk '{print $1}'
		return 0
	fi

	if command -v openssl >/dev/null 2>&1; then
		openssl dgst -sha256 "$file" 2>/dev/null | awk '{print $NF}'
		return 0
	fi

	return 1
}

json_escape_string() {
	printf '%s' "$1" | awk '
		{
			gsub(/\\/,"\\\\")
			gsub(/"/,"\\\"")
			printf "%s", $0
		}
	'
}

extract_subscription_url_from_json_file() {
	local file="$1"
	local url

	url="$(jsonfilter -i "$file" -e '@.subscription_url' 2>/dev/null || echo "")"
	[ -z "$url" ] && url="$(jsonfilter -i "$file" -e '@.sub_url' 2>/dev/null || echo "")"
	[ -z "$url" ] && url="$(jsonfilter -i "$file" -e '@.sub' 2>/dev/null || echo "")"
	[ -z "$url" ] && url="$(jsonfilter -i "$file" -e '@.subscription.url' 2>/dev/null || echo "")"

	case "$url" in
		http://*|https://*) printf '%s' "$url"; return 0 ;;
	esac

	return 1
}

extract_subscription_url_from_json_text() {
	local url

	url="$(printf '%s' "$1" | jsonfilter -e '@.subscription_url' 2>/dev/null || echo "")"
	[ -z "$url" ] && url="$(printf '%s' "$1" | jsonfilter -e '@.sub_url' 2>/dev/null || echo "")"
	[ -z "$url" ] && url="$(printf '%s' "$1" | jsonfilter -e '@.sub' 2>/dev/null || echo "")"
	[ -z "$url" ] && url="$(printf '%s' "$1" | jsonfilter -e '@.subscription.url' 2>/dev/null || echo "")"

	case "$url" in
		http://*|https://*) printf '%s' "$url"; return 0 ;;
	esac

	return 1
}

save_subscription_url() {
	local url="$1"

	case "$url" in
		http://*|https://*)
			printf '%s\n' "$url" > "$SUB_URL_FILE"
			log "subscription url saved"
			return 0
			;;
	esac

	return 1
}

save_config_url() {
	local url="$1"

	case "$url" in
		http://*|https://*)
			printf '%s\n' "$url" > "$CONFIG_URL_FILE"
			log "router config url saved"
			return 0
			;;
	esac

	return 1
}

save_router_software_metadata_file() {
	local file="$1"
	local version update_url min_version

	[ -s "$file" ] || return 1

	version="$(jsonfilter -i "$file" -e '@.router_software.version' 2>/dev/null || echo "")"
	[ -z "$version" ] && version="$(jsonfilter -i "$file" -e '@.router_software_current.version' 2>/dev/null || echo "")"

	update_url="$(jsonfilter -i "$file" -e '@.router_software.update_url' 2>/dev/null || echo "")"
	[ -z "$update_url" ] && update_url="$(jsonfilter -i "$file" -e '@.router_software_current.update_url' 2>/dev/null || echo "")"

	min_version="$(jsonfilter -i "$file" -e '@.router_software.min_version' 2>/dev/null || echo "")"
	[ -z "$min_version" ] && min_version="$(jsonfilter -i "$file" -e '@.router_software_current.min_version' 2>/dev/null || echo "")"

	[ -n "$version" ] && {
		printf '%s\n' "$version" > "$FW_LATEST_FILE"
		printf '%s\n' "$version" > "$ROUTER_LATEST_VERSION_FILE"
	}

	case "$update_url" in
		http://*|https://*) printf '%s\n' "$update_url" > "$UPDATE_URL_FILE" ;;
	esac

	[ -n "$min_version" ] && printf '%s\n' "$min_version" > "$UPDATE_MIN_VERSION_FILE"
}

save_router_software_metadata_text() {
	local tmp="$STATE_DIR/router_software_meta.tmp.$$"

	printf '%s' "$1" > "$tmp" || return 1
	save_router_software_metadata_file "$tmp"
	rm -f "$tmp"
}

append_format_json() {
	local url="$1"

	case "$url" in
		*format=*) printf '%s' "$url" ;;
		*\?*)     printf '%s&format=json' "$url" ;;
		*)        printf '%s?format=json' "$url" ;;
	esac
}

base64_decode_subscription() {
	local in="$1"
	local out="$2"
	local b64="${out}.b64"
	local len mod

	tr -d '\r\n \t' < "$in" 2>/dev/null | tr '_-' '/+' > "$b64" 2>/dev/null || {
		rm -f "$b64"
		return 1
	}

	len="$(wc -c < "$b64" 2>/dev/null | tr -d ' ')"
	case "$len" in
		''|*[!0-9]*) rm -f "$b64"; return 1 ;;
	esac

	mod=$((len % 4))
	case "$mod" in
		0) ;;
		2) printf '==' >> "$b64" ;;
		3) printf '=' >> "$b64" ;;
		*) rm -f "$b64"; return 1 ;;
	esac

	if command -v ucode >/dev/null 2>&1 &&
		ucode -e "let fs = require('fs'); let s = fs.readfile('$b64'); print(b64dec(s));" > "$out" 2>/dev/null; then
		rm -f "$b64"
		return 0
	fi

	rm -f "$b64" "$out"
	return 1
}

extract_uri_links_file() {
	local file="$1"
	local out="$2"

	grep -oE '(ss|vless)://[^"'"'"'[:space:],<>{}]+' "$file" 2>/dev/null > "$out"
	[ -s "$out" ]
}

write_links_json_from_lines() {
	local in="$1"
	local out="$2"
	local line escaped first count

	first=1
	count=0
	printf '{"subscription":{"links":[' > "$out" || return 1

	while IFS= read -r line; do
		line="$(printf '%s' "$line" | tr -d '\r')"
		case "$line" in
			ss://*|vless://*) ;;
			*) continue ;;
		esac

		escaped="$(json_escape_string "$line")"
		if [ "$first" -eq 1 ]; then
			first=0
		else
			printf ',' >> "$out"
		fi
		printf '"%s"' "$escaped" >> "$out"
		count=$((count + 1))
	done < "$in"

	printf ']}}\n' >> "$out"

	[ "$count" -gt 0 ]
}

json_value_from_sources() {
	local expr="$1"
	shift
	local src val

	for src in "$@"; do
		[ -s "$src" ] || continue
		val="$(jsonfilter -i "$src" -e "$expr" 2>/dev/null || echo "")"
		[ -n "$val" ] && {
			printf '%s' "$val"
			return 0
		}
	done

	return 1
}

append_json_string_field() {
	local out="$1"
	local key="$2"
	local val="$3"
	local escaped

	[ -n "$val" ] || return 0
	escaped="$(json_escape_string "$val")"
	printf ',"%s":"%s"' "$key" "$escaped" >> "$out"
}

rewrite_subscription_with_metadata() {
	local file="$1"
	shift
	local out="${file}.meta"
	local first line escaped count
	local code uid usi v sub_url profile_proto
	local sw_version sw_update_url sw_min_version

	first=1
	count=0

	printf '{"subscription":{"links":[' > "$out" || return 1
	jsonfilter -i "$file" -e '@.subscription.links[*]' 2>/dev/null | while IFS= read -r line; do
		line="$(printf '%s' "$line" | tr -d '\r')"
		case "$line" in
			ss://*|vless://*) ;;
			*) continue ;;
		esac

		escaped="$(json_escape_string "$line")"
		if [ "$first" -eq 1 ]; then
			first=0
		else
			printf ',' >> "$out"
		fi
		printf '"%s"' "$escaped" >> "$out"
		count=$((count + 1))
		echo "$count" > "${out}.count"
	done

	count="$(cat "${out}.count" 2>/dev/null || echo 0)"
	rm -f "${out}.count"
	case "$count" in ''|*[!0-9]*) count=0 ;; esac
	[ "$count" -gt 0 ] || {
		rm -f "$out"
		return 1
	}

	printf ']}' >> "$out"

	code="$(json_value_from_sources '@.code' "$@" || echo "")"
	uid="$(json_value_from_sources '@.uid' "$@" || echo "")"
	usi="$(json_value_from_sources '@.usi' "$@" || echo "")"
	v="$(json_value_from_sources '@.v' "$@" || echo "")"
	sub_url="$(json_value_from_sources '@.subscription_url' "$@" || echo "")"
	profile_proto="$(json_value_from_sources '@.router_profile.proto' "$@" || echo "")"
	sw_version="$(json_value_from_sources '@.router_software.version' "$@" || echo "")"
	[ -z "$sw_version" ] && sw_version="$(json_value_from_sources '@.router_software_current.version' "$@" || echo "")"
	sw_update_url="$(json_value_from_sources '@.router_software.update_url' "$@" || echo "")"
	[ -z "$sw_update_url" ] && sw_update_url="$(json_value_from_sources '@.router_software_current.update_url' "$@" || echo "")"
	sw_min_version="$(json_value_from_sources '@.router_software.min_version' "$@" || echo "")"
	[ -z "$sw_min_version" ] && sw_min_version="$(json_value_from_sources '@.router_software_current.min_version' "$@" || echo "")"

	append_json_string_field "$out" "code" "$code"
	append_json_string_field "$out" "uid" "$uid"
	append_json_string_field "$out" "usi" "$usi"
	append_json_string_field "$out" "v" "$v"
	append_json_string_field "$out" "subscription_url" "$sub_url"

	if [ -n "$profile_proto" ]; then
		printf ',"router_profile":{"proto":"%s"}' "$(json_escape_string "$profile_proto")" >> "$out"
	fi

	if [ -n "$sw_version" ] || [ -n "$sw_update_url" ] || [ -n "$sw_min_version" ]; then
		printf ',"router_software":{' >> "$out"
		first=1
		for field in version update_url min_version; do
			case "$field" in
				version) val="$sw_version" ;;
				update_url) val="$sw_update_url" ;;
				min_version) val="$sw_min_version" ;;
			esac
			[ -n "$val" ] || continue
			[ "$first" -eq 1 ] || printf ',' >> "$out"
			first=0
			printf '"%s":"%s"' "$field" "$(json_escape_string "$val")" >> "$out"
		done
		printf '}' >> "$out"
	fi

	printf '}\n' >> "$out"
	mv "$out" "$file"
}

normalize_subscription_file() {
	local file="$1"
	local tmp line escaped first decoded links_tmp

	if jsonfilter -i "$file" -e '@.subscription.links[0]' >/dev/null 2>&1; then
		return 0
	fi

	if jsonfilter -i "$file" -e '@[0]' >/dev/null 2>&1; then
		tmp="${file}.norm"
		{
			printf '{"subscription":{"links":'
			jsonfilter -i "$file" -e '@' 2>/dev/null
			printf '}}\n'
		} > "$tmp" && mv "$tmp" "$file"
		return $?
	fi

	if jsonfilter -i "$file" -e '@.links[0]' >/dev/null 2>&1; then
		tmp="${file}.norm"
		{
			printf '{"subscription":{"links":'
			jsonfilter -i "$file" -e '@.links' 2>/dev/null
			printf '}}\n'
		} > "$tmp" && mv "$tmp" "$file"
		return $?
	fi

	if ! grep -qE '^(ss|vless)://' "$file" 2>/dev/null; then
		decoded="${file}.decoded"
		if base64_decode_subscription "$file" "$decoded" && grep -qE '(ss|vless)://' "$decoded" 2>/dev/null; then
			mv "$decoded" "$file"
		else
			rm -f "$decoded"
		fi
	fi

	if ! grep -qE '(ss|vless)://' "$file" 2>/dev/null; then
		return 1
	fi

	tmp="${file}.norm"
	if write_links_json_from_lines "$file" "$tmp"; then
		mv "$tmp" "$file"
		return 0
	fi
	rm -f "$tmp"

	links_tmp="${file}.links"
	first=1

	if ! extract_uri_links_file "$file" "$links_tmp"; then
		rm -f "$links_tmp"
		return 1
	fi

	printf '{"subscription":{"links":[' > "$tmp" || return 1

	while IFS= read -r line; do
		line="$(printf '%s' "$line" | tr -d '\r')"
		case "$line" in
			ss://*|vless://*) ;;
			*) continue ;;
		esac
		escaped="$(json_escape_string "$line")"
		if [ "$first" -eq 1 ]; then
			first=0
		else
			printf ',' >> "$tmp"
		fi
		printf '"%s"' "$escaped" >> "$tmp"
	done < "$links_tmp"

	printf ']}}\n' >> "$tmp"
	rm -f "$links_tmp"
	mv "$tmp" "$file"
}

ensure_selected_link_valid() {
	local selected count

	[ -s "$SUB_FILE" ] || return 0

	selected="$(cat "$STATE_DIR/selected_link_index" 2>/dev/null | tr -d '\r\n ' || echo 0)"
	case "$selected" in
		''|*[!0-9]*) selected=0 ;;
	esac

	count="$(jsonfilter -i "$SUB_FILE" -e '@.subscription.links[*]' 2>/dev/null | wc -l | tr -d ' ')"
	case "$count" in
		''|*[!0-9]*) count=0 ;;
	esac

	if [ "$count" -gt 0 ] && [ "$selected" -ge "$count" ]; then
		log "selected server index $selected is out of range after subscription update (count=$count), fallback to 0"
		echo "0" > "$STATE_DIR/selected_link_index"
	fi
}

restart_vpn() {
	if [ ! -x /etc/init.d/shpun-vpn ]; then
		log "shpun-vpn init script not found"
		return 1
	fi

	log "restarting shpun-vpn"

	if ! /etc/init.d/shpun-vpn restart 2>/dev/null; then
		log "failed to restart shpun-vpn"
		return 1
	fi

	return 0
}

apply_routes_rules() {
	log "routes: CIDR changed while mode=split_ru, applying live rules without VPN restart"

	if [ ! -x /etc/shpun/firewall-xray.sh ]; then
		log "routes: firewall-xray.sh not found, updated CIDRs will apply on next VPN start"
		return 1
	fi

	/etc/shpun/firewall-xray.sh reload-ru || {
		log "routes: live CIDR apply failed, updated CIDRs will apply on next VPN start"
		return 1
	}

	return 0
}

fetch_routes_once() {
	local remote_ver local_ver remote_sha local_sha
	local tmp_cidrs tmp_sha mode

	ensure_routes_dir
	detect_http_client

	if [ -z "$HTTP_BIN" ]; then
		log "routes: no HTTP client"
		return 1
	fi

	remote_ver="$(http_get_stdout "$ROUTES_URL_BASE/ru.version" 2>/dev/null | tr -d '\r\n ' || true)"
	local_ver="$(cat "$ROUTES_VER_FILE" 2>/dev/null | tr -d '\r\n ' || echo "0")"

	if [ -z "$remote_ver" ]; then
		log "routes: empty remote version"
		return 1
	fi

	if [ "$remote_ver" = "$local_ver" ] && [ -s "$ROUTES_CIDRS_FILE" ]; then
		log "routes: already up-to-date (v=$local_ver)"
		return 0
	fi

	log "routes: updating local=$local_ver remote=$remote_ver"

	tmp_cidrs="${ROUTES_CIDRS_FILE}.tmp"
	tmp_sha="${ROUTES_SHA_FILE}.tmp"

	rm -f "$tmp_cidrs" "$tmp_sha"

	if ! http_get_to_file "$ROUTES_URL_BASE/ru.cidrs" "$tmp_cidrs" 2>/dev/null; then
		log "routes: failed to download ru.cidrs"
		rm -f "$tmp_cidrs" "$tmp_sha"
		return 1
	fi

	if [ ! -s "$tmp_cidrs" ]; then
		log "routes: downloaded ru.cidrs is empty"
		rm -f "$tmp_cidrs" "$tmp_sha"
		return 1
	fi

	if ! http_get_to_file "$ROUTES_URL_BASE/ru.sha256" "$tmp_sha" 2>/dev/null; then
		log "routes: failed to download ru.sha256"
		rm -f "$tmp_cidrs" "$tmp_sha"
		return 1
	fi

	remote_sha="$(tr -d '\r\n ' < "$tmp_sha" 2>/dev/null)"

	if [ -z "$remote_sha" ]; then
		log "routes: empty remote sha256"
		rm -f "$tmp_cidrs" "$tmp_sha"
		return 1
	fi

	local_sha="$(calc_sha256_file "$tmp_cidrs" 2>/dev/null || true)"

	if [ -z "$local_sha" ]; then
		log "routes: failed to calculate local sha256"
		rm -f "$tmp_cidrs" "$tmp_sha"
		return 1
	fi

	if [ "$local_sha" != "$remote_sha" ]; then
		log "routes: sha256 mismatch local=$local_sha remote=$remote_sha"
		rm -f "$tmp_cidrs" "$tmp_sha"
		return 1
	fi

	mv "$tmp_cidrs" "$ROUTES_CIDRS_FILE"
	echo "$remote_sha" > "$ROUTES_SHA_FILE"
	echo "$remote_ver" > "$ROUTES_VER_FILE"
	rm -f "$tmp_sha"

	log "routes: updated to version $remote_ver"

	mode="$(get_routing_mode)"

	if [ "$mode" = "split_ru" ]; then
		apply_routes_rules
	else
		log "routes: mode=$mode, skipping nft rebuild (will apply on next split_ru switch)"
	fi

	return 0
}

fetch_smart_ru_once() {
	local remote_ver local_ver remote_sha local_sha
	local tmp_domains tmp_sha

	ensure_routes_dir
	detect_http_client

	if [ -z "$HTTP_BIN" ]; then
		log "smart_ru: no HTTP client"
		return 1
	fi

	remote_ver="$(http_get_stdout "$ROUTES_URL_BASE/presets/smart_ru.domains.version" 2>/dev/null | tr -d '\r\n ' || true)"
	local_ver="$(cat "$SMART_RU_DOMAINS_VER_FILE" 2>/dev/null | tr -d '\r\n ' || echo "0")"

	if [ -z "$remote_ver" ]; then
		log "smart_ru: empty remote version"
		return 1
	fi

	if [ "$remote_ver" = "$local_ver" ] && [ -s "$SMART_RU_DOMAINS_FILE" ]; then
		log "smart_ru: already up-to-date (v=$local_ver)"
		return 0
	fi

	log "smart_ru: updating local=$local_ver remote=$remote_ver"

	tmp_domains="${SMART_RU_DOMAINS_FILE}.tmp"
	tmp_sha="${SMART_RU_DOMAINS_SHA_FILE}.tmp"

	rm -f "$tmp_domains" "$tmp_sha"

	if ! http_get_to_file "$ROUTES_URL_BASE/presets/smart_ru.domains" "$tmp_domains" 2>/dev/null; then
		log "smart_ru: failed to download domains"
		rm -f "$tmp_domains" "$tmp_sha"
		return 1
	fi

	if [ ! -s "$tmp_domains" ]; then
		log "smart_ru: downloaded domains file is empty"
		rm -f "$tmp_domains" "$tmp_sha"
		return 1
	fi

	if ! http_get_to_file "$ROUTES_URL_BASE/presets/smart_ru.domains.sha256" "$tmp_sha" 2>/dev/null; then
		log "smart_ru: failed to download sha256"
		rm -f "$tmp_domains" "$tmp_sha"
		return 1
	fi

	remote_sha="$(tr -d '\r\n ' < "$tmp_sha" 2>/dev/null)"

	if [ -z "$remote_sha" ]; then
		log "smart_ru: empty remote sha256"
		rm -f "$tmp_domains" "$tmp_sha"
		return 1
	fi

	local_sha="$(calc_sha256_file "$tmp_domains" 2>/dev/null || true)"

	if [ -z "$local_sha" ]; then
		log "smart_ru: failed to calculate local sha256"
		rm -f "$tmp_domains" "$tmp_sha"
		return 1
	fi

	if [ "$local_sha" != "$remote_sha" ]; then
		log "smart_ru: sha256 mismatch local=$local_sha remote=$remote_sha"
		rm -f "$tmp_domains" "$tmp_sha"
		return 1
	fi

	mv "$tmp_domains" "$SMART_RU_DOMAINS_FILE"
	echo "$remote_sha" > "$SMART_RU_DOMAINS_SHA_FILE"
	echo "$remote_ver" > "$SMART_RU_DOMAINS_VER_FILE"
	rm -f "$tmp_sha"

	log "smart_ru: domains updated to version $remote_ver"

	if [ "$(get_routing_mode)" = "smart_ru" ]; then
		log "smart_ru: domains changed while mode=smart_ru, rebuilding VPN config"
		ensure_vpn_from_subscription || true
	fi

	return 0
}

fetch_always_vpn_file_once() {
	local suffix target_file version_file sha_file label
	local remote_ver local_ver remote_sha local_sha
	local tmp_file tmp_sha

	suffix="$1"
	target_file="$2"
	version_file="$3"
	sha_file="$4"
	label="always_vpn.$suffix"

	ensure_routes_dir
	detect_http_client

	if [ -z "$HTTP_BIN" ]; then
		log "$label: no HTTP client"
		return 1
	fi

	remote_ver="$(http_get_stdout "$ROUTES_URL_BASE/presets/always_vpn.$suffix.version" 2>/dev/null | tr -d '\r\n ' || true)"
	local_ver="$(cat "$version_file" 2>/dev/null | tr -d '\r\n ' || echo "0")"

	if [ -z "$remote_ver" ]; then
		log "$label: empty remote version"
		return 1
	fi

	if [ "$remote_ver" = "$local_ver" ] && [ -s "$target_file" ]; then
		log "$label: already up-to-date (v=$local_ver)"
		return 0
	fi

	log "$label: updating local=$local_ver remote=$remote_ver"

	tmp_file="${target_file}.tmp"
	tmp_sha="${sha_file}.tmp"

	rm -f "$tmp_file" "$tmp_sha"

	if ! http_get_to_file "$ROUTES_URL_BASE/presets/always_vpn.$suffix" "$tmp_file" 2>/dev/null; then
		log "$label: failed to download file"
		rm -f "$tmp_file" "$tmp_sha"
		return 1
	fi

	if [ ! -s "$tmp_file" ]; then
		log "$label: downloaded file is empty"
		rm -f "$tmp_file" "$tmp_sha"
		return 1
	fi

	if ! http_get_to_file "$ROUTES_URL_BASE/presets/always_vpn.$suffix.sha256" "$tmp_sha" 2>/dev/null; then
		log "$label: failed to download sha256"
		rm -f "$tmp_file" "$tmp_sha"
		return 1
	fi

	remote_sha="$(tr -d '\r\n ' < "$tmp_sha" 2>/dev/null)"
	local_sha="$(calc_sha256_file "$tmp_file" 2>/dev/null || true)"

	if [ -z "$remote_sha" ] || [ -z "$local_sha" ] || [ "$local_sha" != "$remote_sha" ]; then
		log "$label: sha256 mismatch local=$local_sha remote=$remote_sha"
		rm -f "$tmp_file" "$tmp_sha"
		return 1
	fi

	mv "$tmp_file" "$target_file"
	echo "$remote_sha" > "$sha_file"
	echo "$remote_ver" > "$version_file"
	rm -f "$tmp_sha"

	log "$label: updated to version $remote_ver"
	return 2
}

fetch_always_vpn_once() {
	local domains_changed=0 cidrs_changed=0 rc

	fetch_always_vpn_file_once domains "$ALWAYS_VPN_DOMAINS_FILE" "$ALWAYS_VPN_DOMAINS_VER_FILE" "$ALWAYS_VPN_DOMAINS_SHA_FILE"
	rc=$?
	[ "$rc" -eq 2 ] && domains_changed=1

	fetch_always_vpn_file_once cidrs "$ALWAYS_VPN_CIDRS_FILE" "$ALWAYS_VPN_CIDRS_VER_FILE" "$ALWAYS_VPN_CIDRS_SHA_FILE"
	rc=$?
	[ "$rc" -eq 2 ] && cidrs_changed=1

	if [ "$cidrs_changed" -eq 1 ]; then
		log "always_vpn: protected CIDRs changed, applying live rules without VPN restart"
		if [ -x /etc/shpun/firewall-xray.sh ]; then
			/etc/shpun/firewall-xray.sh reload-always-vpn || \
				log "always_vpn: live CIDR apply failed, updated CIDRs will apply on next VPN start"
		else
			log "always_vpn: firewall-xray.sh not found, updated CIDRs will apply on next VPN start"
		fi
	fi

	if [ "$domains_changed" -eq 1 ]; then
		log "always_vpn: protected domains changed, rebuilding deferred xray config"
		ensure_vpn_from_subscription || true
		apply_protected_dns_forwarding
	fi

	return 0
}

apply_always_vpn_live_rules() {
	[ -s "$ALWAYS_VPN_CIDRS_FILE" ] || return 0
	[ -x /etc/shpun/firewall-xray.sh ] || return 0

	log "always_vpn: synchronizing protected CIDRs into live rules"
	/etc/shpun/firewall-xray.sh reload-always-vpn || \
		log "always_vpn: live CIDR sync deferred until next VPN start"
}

check_routes_update() {
	local now_ts last_ts

	ensure_routes_dir

	now_ts="$(date +%s)"
	last_ts="$(cat "$ROUTES_LAST_CHECK_FILE" 2>/dev/null | tr -d '\r\n ' || echo 0)"

	case "$last_ts" in
		''|*[!0-9]*) last_ts=0 ;;
	esac

	if [ "$((now_ts - last_ts))" -lt "$ROUTES_CHECK_INTERVAL" ]; then
		return 0
	fi

	fetch_always_vpn_once
	fetch_smart_ru_once
	if [ "$(get_routing_mode)" = "split_ru" ]; then
		fetch_routes_once
	fi
	echo "$now_ts" > "$ROUTES_LAST_CHECK_FILE"
}

ensure_routes_ready() {
	ensure_routes_dir

	local mode
	mode="$(get_routing_mode)"

	if [ "$mode" = "full" ]; then
		return 0
	fi

	if [ "$mode" = "smart_ru" ]; then
		if [ ! -s "$SMART_RU_DOMAINS_FILE" ]; then
			log "routes: smart_ru domains missing, fetching initial copy"
			fetch_smart_ru_once
		fi
		return 0
	fi

	if [ ! -s "$ROUTES_CIDRS_FILE" ]; then
		log "routes: local route file missing, fetching initial copy"
		fetch_routes_once
	fi
}

engine_download() {
	if [ -z "$ENGINE_URL" ]; then
		log "ENGINE_URL not set, skip engine download"
		return 1
	fi

	if [ -x "$ENGINE_BIN" ]; then
		log "engine already present: $ENGINE_BIN"
		return 0
	fi

	detect_http_client

	if [ -z "$HTTP_BIN" ]; then
		log "engine_download: no HTTP client"
		return 1
	fi

	mkdir -p "$(dirname "$ENGINE_BIN")" 2>/dev/null || true

	log "downloading engine from $ENGINE_URL to $ENGINE_BIN"

	if ! http_get_to_file "$ENGINE_URL" "$ENGINE_BIN" 2>/dev/null; then
		log "failed to download engine"
		rm -f "$ENGINE_BIN"
		return 1
	fi

	if [ ! -s "$ENGINE_BIN" ]; then
		log "downloaded engine file is empty"
		rm -f "$ENGINE_BIN"
		return 1
	fi

	if ! chmod +x "$ENGINE_BIN" 2>/dev/null; then
		log "failed to chmod +x engine"
		rm -f "$ENGINE_BIN"
		return 1
	fi

	log "engine downloaded and ready: $ENGINE_BIN"
	return 0
}

wait_vpn_started() {
	local i=0

	while [ "$i" -lt 20 ]; do
		if is_vpn_process_running; then
			return 0
		fi
		sleep 1
		i=$((i + 1))
	done

	return 1
}

is_vpn_process_running() {
	local engine_base
	local config_base

	engine_base="$(basename "$ENGINE_BIN" 2>/dev/null || echo xray)"
	config_base="$(basename "$ENGINE_CONFIG" 2>/dev/null || echo xray.json)"

	pgrep -f "$ENGINE_BIN.*run.*-config.*$ENGINE_CONFIG" >/dev/null 2>&1 && return 0
	pgrep -f "$engine_base.*run.*-config.*$config_base" >/dev/null 2>&1 && return 0

	return 1
}

get_uptime_secs() {
	awk -F. '{print $1}' /proc/uptime 2>/dev/null || echo 0
}

check_internet() {
	ping -c1 -W1 "$PING_HOST" >/dev/null 2>&1 && return 0

	[ "$PING_HOST" != "1.1.1.1" ] && ping -c1 -W1 1.1.1.1 >/dev/null 2>&1 && return 0
	[ "$PING_HOST" != "8.8.8.8" ] && ping -c1 -W1 8.8.8.8 >/dev/null 2>&1 && return 0

	return 1
}

probe_url_through_tunnel() {
	local url="$1"
	local proxy="http://127.0.0.1:${HTTP_PROXY_PORT}"

	case "$HTTP_BIN" in
		curl)
			curl -fsS -m 8 -x "$proxy" "$url" >/dev/null 2>&1
			;;
		wget)
			env http_proxy="$proxy" HTTP_PROXY="$proxy" \
				wget -q -T 8 -O /dev/null "$url" >/dev/null 2>&1
			;;
		uclient-fetch)
			env http_proxy="$proxy" HTTP_PROXY="$proxy" \
				uclient-fetch -q -T 8 -Y on -O /dev/null "$url" >/dev/null 2>&1
			;;
		*)
			return 1
			;;
	esac
}

check_tunnel_connectivity() {
	detect_http_client
	[ -n "$HTTP_BIN" ] || return 1

	probe_url_through_tunnel "$TUNNEL_PROBE_URL" && return 0

	if [ "$TUNNEL_PROBE_URL" != "$TUNNEL_PROBE_URL_DEFAULT" ]; then
		probe_url_through_tunnel "$TUNNEL_PROBE_URL_DEFAULT" && return 0
	fi

	return 1
}

ensure_transparent_rules() {
	local repair=0

	[ -x /etc/shpun/firewall-xray.sh ] || return 0
	command -v nft >/dev/null 2>&1 || return 0

	nft list chain inet shpun prerouting 2>/dev/null | grep -q "redirect to :${REDIR_PORT}" || repair=1

	if [ -s "$UDP_READY_FILE" ]; then
		nft list chain inet shpun prerouting_mangle 2>/dev/null | grep -q "tproxy.*:${TPROXY_PORT}" || repair=1
		ip rule show 2>/dev/null | grep -q "fwmark 0x${TPROXY_MARK}" || repair=1
	fi

	[ "$repair" -eq 0 ] && return 0

	log "transparent VPN rules are missing, restoring firewall path without restarting xray"
	if /etc/shpun/firewall-xray.sh init; then
		apply_protected_dns_forwarding
		return 0
	fi

	log "failed to restore transparent VPN rules"
	return 1
}

recover_failed_tunnel() {
	log "tunnel probe failure confirmed, restarting shpun-vpn to apply current effective config"
	rm -f "$VPN_READY_FILE"

	if ensure_vpn_from_subscription; then
		log "tunnel recovery completed"
		return 0
	fi

	log "tunnel recovery failed; agent will retry"
	return 1
}

wait_for_default_route() {
	log "waiting for default IPv4 route..."

	i=0
	while [ "$i" -lt 30 ]; do
		if ip -4 route show default 2>/dev/null | grep -q '^default'; then
			IFACE="$(ip -4 route show default 2>/dev/null | awk '/^default/ {print $5; exit}')"
			if [ -n "$IFACE" ]; then
				log "default IPv4 route via $IFACE detected"
			else
				log "default IPv4 route detected"
			fi
			return 0
		fi
		i=$((i + 1))
		sleep 2
	done

	log "no default IPv4 route detected after timeout, continuing anyway"
	return 1
}

fetch_subscription_once() {
	if [ -z "$CLEAN_CODE" ] || [ -z "$API_URL" ]; then
		return 1
	fi

	detect_http_client

	if [ -z "$HTTP_BIN" ]; then
		log "fetch_subscription_once: no HTTP client"
		return 1
	fi

	URL="${API_URL}?code=${CLEAN_CODE}&format=json"

	log "query router_public"
	BODY="$(http_get_stdout "$URL" 2>/dev/null || true)"

	if [ -z "$BODY" ]; then
		log "empty response from router_public"
		return 1
	fi

	OK="$(printf '%s' "$BODY" | jsonfilter -e '@.ok' 2>/dev/null || echo "")"

	if [ "$OK" != "1" ]; then
		ERR="$(printf '%s' "$BODY" | jsonfilter -e '@.error' 2>/dev/null || echo "")"
		[ -z "$ERR" ] && ERR="unknown_error"
		log "router_public error: ok=$OK, error=$ERR"
		return 1
	fi
	save_router_software_metadata_text "$BODY" >/dev/null 2>&1 || true

	CONFIG_PATH="$(printf '%s' "$BODY" | jsonfilter -e '@.config_url' 2>/dev/null || echo "")"
	SUBSCRIPTION_URL="$(extract_subscription_url_from_json_text "$BODY" || echo "")"

	if [ -z "$CONFIG_PATH" ] && [ -z "$SUBSCRIPTION_URL" ]; then
		log "router_public ok=1 but config_url/subscription_url is empty"
		return 1
	fi

	BASE_URL="${API_URL%/shm/v1/public/router_public}"
	CONFIG_URL=""
	if [ -n "$CONFIG_PATH" ]; then
		case "$CONFIG_PATH" in
			http://*|https://*) CONFIG_URL="$CONFIG_PATH" ;;
			*) CONFIG_URL="${BASE_URL}${CONFIG_PATH}" ;;
		esac
		save_config_url "$CONFIG_URL" >/dev/null 2>&1 || true
	fi

	if [ -n "$SUBSCRIPTION_URL" ]; then
		save_subscription_url "$SUBSCRIPTION_URL" >/dev/null 2>&1 || true
		DOWNLOAD_URL="$SUBSCRIPTION_URL"
	else
		if [ -z "$CONFIG_URL" ]; then
			log "router_public ok=1 but usable config_url is empty"
			return 1
		fi
		DOWNLOAD_URL="${CONFIG_URL}&format=json"
	fi

	log "fetching subscription"

	TMP_SUB="${SUB_FILE}.tmp"
	PUBLIC_META="${TMP_SUB}.public"
	CONFIG_META="${TMP_SUB}.config"
	rm -f "$PUBLIC_META" "$CONFIG_META"
	printf '%s' "$BODY" > "$PUBLIC_META"

	if [ -n "$CONFIG_URL" ]; then
		if http_get_to_file "$(append_format_json "$CONFIG_URL")" "$CONFIG_META" >/dev/null 2>&1; then
			save_router_software_metadata_file "$CONFIG_META" >/dev/null 2>&1 || true
		else
			rm -f "$CONFIG_META"
		fi
	fi

	if ! http_get_to_file "$DOWNLOAD_URL" "$TMP_SUB" 2>/dev/null; then
		log "failed to download subscription"
		rm -f "$TMP_SUB" "$PUBLIC_META" "$CONFIG_META"
		return 1
	fi

	if [ ! -s "$TMP_SUB" ]; then
		log "downloaded subscription json is empty"
		rm -f "$TMP_SUB" "$PUBLIC_META" "$CONFIG_META"
		return 1
	fi

	if [ -z "$SUBSCRIPTION_URL" ]; then
		SUBSCRIPTION_URL="$(extract_subscription_url_from_json_file "$TMP_SUB" || echo "")"
		[ -n "$SUBSCRIPTION_URL" ] && save_subscription_url "$SUBSCRIPTION_URL" >/dev/null 2>&1 || true
	fi

	if ! normalize_subscription_file "$TMP_SUB"; then
		log "downloaded subscription format is unsupported"
		rm -f "$TMP_SUB" "$PUBLIC_META" "$CONFIG_META"
		return 1
	fi
	rewrite_subscription_with_metadata "$TMP_SUB" "$CONFIG_META" "$PUBLIC_META" "$SUB_FILE" "$TMP_SUB" >/dev/null 2>&1 || true

	mv "$TMP_SUB" "$SUB_FILE"
	rm -f "$PUBLIC_META" "$CONFIG_META"
	ensure_selected_link_valid
	log "subscription json saved to $SUB_FILE"

	date +%s > "$LAST_CHECK_FILE"

	return 0
}

refresh_subscription_from_url() {
	local sub_url tmp_sub old_sha new_sha

	[ -s "$SUB_URL_FILE" ] || return 1

	sub_url="$(cat "$SUB_URL_FILE" 2>/dev/null | tr -d '\r\n ' || true)"
	[ -n "$sub_url" ] || return 1

	detect_http_client

	if [ -z "$HTTP_BIN" ]; then
		log "refresh_subscription_from_url: no HTTP client"
		return 1
	fi

	tmp_sub="${SUB_FILE}.refresh.tmp"
	rm -f "$tmp_sub"

	log "refreshing subscription from saved url"

	if ! http_get_to_file "$sub_url" "$tmp_sub" 2>/dev/null; then
		log "refresh_subscription_from_url: download failed"
		rm -f "$tmp_sub"
		return 1
	fi

	if [ ! -s "$tmp_sub" ]; then
		log "refresh_subscription_from_url: downloaded file is empty"
		rm -f "$tmp_sub"
		return 1
	fi

	if ! normalize_subscription_file "$tmp_sub"; then
		log "refresh_subscription_from_url: unsupported subscription format"
		rm -f "$tmp_sub"
		return 1
	fi
	rewrite_subscription_with_metadata "$tmp_sub" "$SUB_FILE" "$tmp_sub" >/dev/null 2>&1 || true

	old_sha="$(calc_sha256_file "$SUB_FILE" 2>/dev/null || true)"
	new_sha="$(calc_sha256_file "$tmp_sub" 2>/dev/null || true)"

	if [ -n "$old_sha" ] && [ "$old_sha" = "$new_sha" ]; then
		rm -f "$tmp_sub"
		log "subscription refresh: unchanged"
		date +%s > "$LAST_CHECK_FILE"
		return 0
	fi

	mv "$tmp_sub" "$SUB_FILE"
	ensure_selected_link_valid
	log "subscription refresh: updated"
	date +%s > "$LAST_CHECK_FILE"
	rm -f "$VERROR_FILE"

	ensure_vpn_from_subscription || true
	return 0
}

ensure_vpn_from_subscription() {
	local old_config_sha active_config_sha new_config_sha vpn_was_running

	if [ ! -s "$SUB_FILE" ]; then
		log "ensure_vpn_from_subscription: $SUB_FILE not found"
		return 1
	fi

	if ! wait_for_default_route; then
		log "ensure_vpn_from_subscription: proceed without confirmed default route"
	fi

	ensure_routes_ready

	if ! engine_download; then
		log "engine_download failed in ensure_vpn_from_subscription"
		echo "engine_download_failed" > "$VERROR_FILE"
		rm -f "$VPN_READY_FILE"
		return 1
	fi

	if [ ! -x /etc/shpun/build-config.sh ]; then
		log "/etc/shpun/build-config.sh not found or not executable"
		echo "build_script_missing" > "$VERROR_FILE"
		rm -f "$VPN_READY_FILE"
		return 1
	fi

	ensure_tproxy_modules || true

	old_config_sha=""
	[ -s "$ENGINE_CONFIG" ] && old_config_sha="$(calc_sha256_file "$ENGINE_CONFIG" 2>/dev/null || true)"
	active_config_sha="$(cat "$CONFIG_ACTIVE_FILE" 2>/dev/null | tr -d '\r\n ' || true)"
	case "$active_config_sha" in
		''|*[!0-9a-fA-F]*) active_config_sha="$old_config_sha" ;;
	esac

	vpn_was_running=0
	if [ -s "$VPN_READY_FILE" ] && is_vpn_process_running; then
		vpn_was_running=1
	fi

	log "building xray config from subscription.json"

	if ! /etc/shpun/build-config.sh; then
		log "build-config.sh failed"
		echo "build_config_failed" > "$VERROR_FILE"
		rm -f "$VPN_READY_FILE"
		return 1
	fi

	new_config_sha=""
	[ -s "$ENGINE_CONFIG" ] && new_config_sha="$(calc_sha256_file "$ENGINE_CONFIG" 2>/dev/null || true)"

	if [ "$vpn_was_running" = "1" ] &&
		[ -n "$active_config_sha" ] &&
		[ -n "$new_config_sha" ] &&
		[ "$active_config_sha" = "$new_config_sha" ]; then
		echo "ok" > "$VPN_READY_FILE"
		echo "$new_config_sha" > "$CONFIG_ACTIVE_FILE"
		rm -f "$VERROR_FILE"
		rm -f "$CONFIG_PENDING_FILE"
		log "xray config unchanged after subscription refresh, keeping running shpun-vpn"
		return 0
	fi

	if [ "$vpn_was_running" = "1" ] && [ -n "$active_config_sha" ] && [ -n "$new_config_sha" ]; then
		echo "$new_config_sha" > "$CONFIG_PENDING_FILE"
		echo "ok" > "$VPN_READY_FILE"
		rm -f "$VERROR_FILE"
		log "xray config changed after subscription refresh, deferring shpun-vpn restart to avoid dropping active sessions"
		return 0
	fi

	if ! restart_vpn; then
		log "restart_vpn failed, not marking vpn_ready"
		echo "restart_vpn_failed" > "$VERROR_FILE"
		rm -f "$VPN_READY_FILE"
		return 1
	fi

	if ! wait_vpn_started; then
		log "xray did not start successfully, not marking vpn_ready"
		rm -f "$DNS_PROXY_READY_FILE"
		[ -x /etc/shpun/dns-xray.sh ] && /etc/shpun/dns-xray.sh clear || true
		echo "xray_failed_to_start" > "$VERROR_FILE"
		rm -f "$VPN_READY_FILE"
		return 1
	fi

	echo "ok" > "$VPN_READY_FILE"
	[ -n "$new_config_sha" ] && echo "$new_config_sha" > "$CONFIG_ACTIVE_FILE"
	rm -f "$VERROR_FILE"
	rm -f "$CONFIG_PENDING_FILE"
	echo "ok" > "$DNS_PROXY_READY_FILE"
	apply_protected_dns_forwarding
	log "vpn_ready marked in $VPN_READY_FILE"

	return 0
}

poll_subscription_loop() {
	if [ -s "$SUB_FILE" ]; then
		save_router_software_metadata_file "$SUB_FILE" >/dev/null 2>&1 || true
		log "subscription.json already present, skipping router_public"
		if [ -s "$VPN_READY_FILE" ] && [ -s "$ENGINE_CONFIG" ] && is_vpn_process_running; then
			log "vpn already running, keeping current tunnel"
			return 0
		fi
		ensure_vpn_from_subscription
		return 0
	fi

	while :; do
		if ! get_code; then
			log "failed to get code, retry in 15s"
			sleep 15
			continue
		fi

		log "router code: $CODE (clean: $CLEAN_CODE)"

		if fetch_subscription_once; then
			ensure_routes_ready
			ensure_vpn_from_subscription
			return 0
		fi

		log "no subscription yet, retry in 20s"
		sleep 20
	done
}

check_subscription_alive() {
	local direct_failed=0
	[ ! -s "$SUB_FILE" ] && return 0

	now_ts="$(date +%s)"
	last_ts=0
	[ -f "$LAST_CHECK_FILE" ] && last_ts="$(cat "$LAST_CHECK_FILE" 2>/dev/null || echo 0)"

	case "$last_ts" in
		''|*[!0-9]*) last_ts=0 ;;
	esac

	if [ "$((now_ts - last_ts))" -lt "$SUB_CHECK_INTERVAL" ]; then
		return 0
	fi

	if [ -s "$SUB_URL_FILE" ]; then
		if refresh_subscription_from_url; then
			return 0
		fi
		direct_failed=1
		log "direct subscription refresh failed, falling back to router_config"
	fi

	detect_http_client

	if [ -z "$HTTP_BIN" ]; then
		log "check_subscription_alive: no HTTP client"
		echo "$now_ts" > "$LAST_CHECK_FILE"
		return 0
	fi

	if [ -s "$CONFIG_URL_FILE" ]; then
		CHECK_URL="$(cat "$CONFIG_URL_FILE" 2>/dev/null | tr -d '\r\n ' || true)"
		if [ -z "$CHECK_URL" ]; then
			log "check_subscription_alive: router_config_url is empty"
			echo "$now_ts" > "$LAST_CHECK_FILE"
			return 0
		fi
		CHECK_URL="$(append_format_json "$CHECK_URL")"
	else
		UID_SUB="$(jsonfilter -i "$SUB_FILE" -e '@.uid' 2>/dev/null || echo "")"
		USI_SUB="$(jsonfilter -i "$SUB_FILE" -e '@.usi' 2>/dev/null || echo "")"

		if [ -z "$UID_SUB" ] || [ -z "$USI_SUB" ]; then
			log "check_subscription_alive: uid/usi missing in subscription.json"
			echo "$now_ts" > "$LAST_CHECK_FILE"
			return 0
		fi

		if ! get_code; then
			log "check_subscription_alive: failed to get code"
			echo "$now_ts" > "$LAST_CHECK_FILE"
			return 0
		fi

		BASE_URL="${API_URL%/shm/v1/public/router_public}"
		CHECK_URL="${BASE_URL}/shm/v1/public/router_config?uid=${UID_SUB}&usi=${USI_SUB}&code=${CLEAN_CODE}&format=json"
		save_config_url "$CHECK_URL" >/dev/null 2>&1 || true
	fi

	log "checking subscription via router_config"

	BODY="$(http_get_stdout "$CHECK_URL" 2>/dev/null || true)"

	if [ -z "$BODY" ]; then
		log "check_subscription_alive: empty response from router_config"
		echo "$now_ts" > "$LAST_CHECK_FILE"
		return 0
	fi
	save_router_software_metadata_text "$BODY" >/dev/null 2>&1 || true

	OK="$(printf '%s' "$BODY" | jsonfilter -e '@.ok' 2>/dev/null || echo "")"

	if [ "$OK" = "1" ]; then
		tmp_sub="${SUB_FILE}.tmp.$$"
		old_sha="$(calc_sha256_file "$SUB_FILE")"

		printf '%s' "$BODY" > "$tmp_sub"
		SUBSCRIPTION_URL="$(extract_subscription_url_from_json_file "$tmp_sub" || echo "")"
		[ -n "$SUBSCRIPTION_URL" ] && save_subscription_url "$SUBSCRIPTION_URL" >/dev/null 2>&1 || true

		if ! normalize_subscription_file "$tmp_sub" >/dev/null 2>&1; then
			log "subscription_alive: unsupported router_config subscription format"
			rm -f "$tmp_sub"
			echo "$now_ts" > "$LAST_CHECK_FILE"
			return 0
		fi
		rewrite_subscription_with_metadata "$tmp_sub" "$tmp_sub" "$SUB_FILE" >/dev/null 2>&1 || true
		new_sha="$(calc_sha256_file "$tmp_sub")"

		if [ -s "$tmp_sub" ] && [ "$new_sha" != "$old_sha" ]; then
			mv "$tmp_sub" "$SUB_FILE"
			ensure_selected_link_valid
			log "subscription_alive: ok=1, subscription.json changed, refreshing effective xray config"
			ensure_vpn_from_subscription || true
		else
			rm -f "$tmp_sub"
			ensure_selected_link_valid
			log "subscription_alive: ok=1, subscription.json unchanged"
		fi
		echo "$now_ts" > "$LAST_CHECK_FILE"
		rm -f "$VERROR_FILE"
		return 0
	fi

	ERR="$(printf '%s' "$BODY" | jsonfilter -e '@.error' 2>/dev/null || echo "unknown_error")"
	log "subscription_invalid: ok=$OK, error=$ERR"

	if [ -s "$SUB_URL_FILE" ] || [ "$direct_failed" = "1" ]; then
		log "subscription fallback failed, keeping current subscription because direct subscription url is known"
		echo "$now_ts" > "$LAST_CHECK_FILE"
		echo "$ERR" > "$VERROR_FILE"
		return 0
	fi

	log "subscription missing in router_config and no direct subscription url is known, resetting VPN state"

	rm -f "$VPN_READY_FILE"
	rm -f "$SUB_FILE"

	echo "$now_ts" > "$LAST_CHECK_FILE"
	echo "$ERR" > "$VERROR_FILE"

	if [ -x /etc/init.d/shpun-vpn ]; then
		/etc/init.d/shpun-vpn stop 2>/dev/null || true
	fi

	return 1
}

vpn_sanity_check() {
	local fail_count=0
	local fail_file="/etc/shpun/vpn_sanity_fail_count"
	local fail_limit=3
	local current_config_sha

	if [ -d "/tmp/shpun-firewall.lock" ]; then
		log "vpn_sanity_check: firewall apply in progress, skipping"
		return
	fi

	if [ ! -s "$VPN_READY_FILE" ]; then
		rm -f "$fail_file"
		return
	fi

	if [ ! -x "$ENGINE_BIN" ] || [ ! -s "$ENGINE_CONFIG" ]; then
		log "vpn_sanity_check: engine or config missing → reset vpn_ready"
		rm -f "$VPN_READY_FILE"
		rm -f "$fail_file"
		return
	fi

	if is_vpn_process_running; then
		rm -f "$fail_file"
		if [ ! -s "$CONFIG_PENDING_FILE" ] && [ -s "$ENGINE_CONFIG" ]; then
			current_config_sha="$(calc_sha256_file "$ENGINE_CONFIG" 2>/dev/null || true)"
			[ -n "$current_config_sha" ] && echo "$current_config_sha" > "$CONFIG_ACTIVE_FILE"
		fi
		return
	fi

	if [ -f "$fail_file" ]; then
		fail_count="$(cat "$fail_file" 2>/dev/null || echo 0)"
	fi

	case "$fail_count" in
		''|*[!0-9]*) fail_count=0 ;;
	esac

	fail_count=$((fail_count + 1))
	echo "$fail_count" > "$fail_file"

	log "vpn_sanity_check: xray not found ($fail_count/$fail_limit)"

	if [ "$fail_count" -lt "$fail_limit" ]; then
		return
	fi

	log "vpn_sanity_check: FAIL LIMIT reached → reset vpn_ready"
	rm -f "$VPN_READY_FILE"
	rm -f "$fail_file"
}

main_loop() {
	load_conf
	ensure_state_dir
	ensure_routes_dir
	ensure_lan_ipv6_disabled
	apply_always_vpn_live_rules

	if ! ensure_router_code; then
		log "initial ensure_router_code failed, will retry in loop"
	fi

	log "shpun-agent started (API_URL=$API_URL, ENGINE_BIN=$ENGINE_BIN, ENGINE_URL=$ENGINE_URL, ROUTES_URL_BASE=$ROUTES_URL_BASE, MIN_UPTIME=$MIN_UPTIME, NET_FAIL_TIMEOUT=$NET_FAIL_TIMEOUT, PING_HOST=$PING_HOST)"

	NET_FAIL_SECONDS=0
	TUNNEL_FAIL_SECONDS=0
	LAST_TUNNEL_PROBE=0

	while :; do
		load_conf
		ensure_lan_ipv6_disabled

		if [ ! -s "$CODE_FILE" ]; then
			if ! ensure_router_code; then
				log "ensure_router_code failed in loop, retry in 10s"
				sleep 10
				continue
			fi
		fi

		UPTIME_SECS="$(get_uptime_secs)"
		if [ "$UPTIME_SECS" -lt "$MIN_UPTIME" ]; then
			log "uptime ${UPTIME_SECS}s < ${MIN_UPTIME}s, waiting before managing VPN"
			sleep "$MAIN_LOOP_SLEEP"
			continue
		fi

		vpn_sanity_check

		if [ -s "$VPN_READY_FILE" ]; then
			if is_vpn_process_running; then
				apply_protected_dns_forwarding
				ensure_transparent_rules || true
			fi
			if check_internet; then
				[ "$NET_FAIL_SECONDS" -gt 0 ] && log "internet is back, resetting fail counter (was ${NET_FAIL_SECONDS}s)"
				NET_FAIL_SECONDS=0

				NOW_TS="$(date +%s 2>/dev/null || echo 0)"
				case "$NOW_TS" in
					''|*[!0-9]*) NOW_TS=0 ;;
				esac
				case "$LAST_TUNNEL_PROBE" in
					''|*[!0-9]*) LAST_TUNNEL_PROBE=0 ;;
				esac

				if is_vpn_process_running &&
					[ "$((NOW_TS - LAST_TUNNEL_PROBE))" -ge "$TUNNEL_PROBE_INTERVAL" ]; then
					LAST_TUNNEL_PROBE="$NOW_TS"

					if check_tunnel_connectivity; then
						[ "$TUNNEL_FAIL_SECONDS" -gt 0 ] && log "tunnel probe recovered after ${TUNNEL_FAIL_SECONDS}s"
						TUNNEL_FAIL_SECONDS=0
					else
						TUNNEL_FAIL_SECONDS=$((TUNNEL_FAIL_SECONDS + TUNNEL_PROBE_INTERVAL))
						log "tunnel proxy probe failed for ${TUNNEL_FAIL_SECONDS}s while WAN is reachable"

						if [ "$TUNNEL_FAIL_SECONDS" -ge "$TUNNEL_FAIL_TIMEOUT" ]; then
							recover_failed_tunnel || true
							TUNNEL_FAIL_SECONDS=0
						fi
					fi
				fi
			else
				NET_FAIL_SECONDS=$((NET_FAIL_SECONDS + MAIN_LOOP_SLEEP))
				log "no internet detected for ${NET_FAIL_SECONDS}s while VPN is active"
				TUNNEL_FAIL_SECONDS=0

				if [ "$NET_FAIL_SECONDS" -ge "$NET_FAIL_TIMEOUT" ]; then
					log "internet probe failed for ${NET_FAIL_SECONDS}s, keeping tunnel running"
					NET_FAIL_SECONDS=0
				fi
			fi
		else
			NET_FAIL_SECONDS=0
			TUNNEL_FAIL_SECONDS=0
		fi

		if [ ! -s "$SUB_FILE" ]; then
			poll_subscription_loop
		else
			if [ ! -s "$VPN_READY_FILE" ]; then
				ensure_vpn_from_subscription
			fi

			check_subscription_alive
			check_routes_update
		fi

		sleep "$MAIN_LOOP_SLEEP"
	done
}

main_loop "$@"
