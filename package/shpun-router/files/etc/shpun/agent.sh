#!/bin/sh
#
# shpun-agent (Xray + Shadowsocks/VLESS transparent edition)
#

STATE_DIR="/etc/shpun"
CODE_FILE="$STATE_DIR/router_code"
SUB_FILE="$STATE_DIR/subscription.json"
SUB_URL_FILE="$STATE_DIR/subscription_url"
CONFIG_URL_FILE="$STATE_DIR/router_config_url"
VPN_READY_FILE="$STATE_DIR/vpn_ready"
LAST_CHECK_FILE="$STATE_DIR/last_sub_check"
CONF="$STATE_DIR/agent.conf"

VERROR_FILE="$STATE_DIR/vpn_error"

LOG_TAG="shpun-agent"

API_URL_DEFAULT="https://bill.shpyn.online/shm/v1/public/router_public"
SUB_CHECK_INTERVAL_DEFAULT=21600

MIN_UPTIME_DEFAULT=120
NET_FAIL_TIMEOUT_DEFAULT=180
MAIN_LOOP_SLEEP_DEFAULT=30

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

	command -v base64 >/dev/null 2>&1 || return 1

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

	if base64 -d "$b64" > "$out" 2>/dev/null; then
		rm -f "$b64"
		return 0
	fi

	rm -f "$b64" "$out"
	return 1
}

normalize_subscription_file() {
	local file="$1"
	local tmp line escaped first decoded

	if jsonfilter -i "$file" -e '@.subscription.links[0]' >/dev/null 2>&1; then
		return 0
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
		if command -v base64 >/dev/null 2>&1; then
			decoded="${file}.decoded"
			if base64_decode_subscription "$file" "$decoded" && grep -qE '^(ss|vless)://' "$decoded" 2>/dev/null; then
				mv "$decoded" "$file"
			else
				rm -f "$decoded"
			fi
		fi
	fi

	if ! grep -qE '^(ss|vless)://' "$file" 2>/dev/null; then
		return 1
	fi

	tmp="${file}.norm"
	first=1
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
	done < "$file"

	printf ']}}\n' >> "$tmp"
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
	log "routes: CIDR changed while mode=split_ru, restarting shpun-vpn safely"

	# Нельзя дергать firewall-xray.sh напрямую при работающем Xray.
	# shpun-vpn restart сначала останавливает Xray, затем применяет firewall,
	# затем запускает Xray обратно. Это защищает слабые роутеры от OOM.
	restart_vpn || {
		log "routes: failed to restart shpun-vpn after route update"
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

	if ! http_get_to_file "$DOWNLOAD_URL" "$TMP_SUB" 2>/dev/null; then
		log "failed to download subscription"
		rm -f "$TMP_SUB"
		return 1
	fi

	if [ ! -s "$TMP_SUB" ]; then
		log "downloaded subscription json is empty"
		rm -f "$TMP_SUB"
		return 1
	fi

	if [ -z "$SUBSCRIPTION_URL" ]; then
		SUBSCRIPTION_URL="$(extract_subscription_url_from_json_file "$TMP_SUB" || echo "")"
		[ -n "$SUBSCRIPTION_URL" ] && save_subscription_url "$SUBSCRIPTION_URL" >/dev/null 2>&1 || true
	fi

	if ! normalize_subscription_file "$TMP_SUB"; then
		log "downloaded subscription format is unsupported"
		rm -f "$TMP_SUB"
		return 1
	fi

	mv "$TMP_SUB" "$SUB_FILE"
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

	log "building xray config from subscription.json"

	if ! /etc/shpun/build-config.sh; then
		log "build-config.sh failed"
		echo "build_config_failed" > "$VERROR_FILE"
		rm -f "$VPN_READY_FILE"
		return 1
	fi

	if ! restart_vpn; then
		log "restart_vpn failed, not marking vpn_ready"
		echo "restart_vpn_failed" > "$VERROR_FILE"
		rm -f "$VPN_READY_FILE"
		return 1
	fi

	if ! wait_vpn_started; then
		log "xray did not start successfully, not marking vpn_ready"
		echo "xray_failed_to_start" > "$VERROR_FILE"
		rm -f "$VPN_READY_FILE"
		return 1
	fi

	echo "ok" > "$VPN_READY_FILE"
	rm -f "$VERROR_FILE"
	log "vpn_ready marked in $VPN_READY_FILE"

	return 0
}

poll_subscription_loop() {
	if [ -s "$SUB_FILE" ]; then
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
		new_sha="$(calc_sha256_file "$tmp_sub")"

		if [ -s "$tmp_sub" ] && [ "$new_sha" != "$old_sha" ]; then
			mv "$tmp_sub" "$SUB_FILE"
			ensure_selected_link_valid
			log "subscription_alive: ok=1, subscription.json changed, rebuilding VPN"
			rm -f "$VPN_READY_FILE"
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

	if ! ensure_router_code; then
		log "initial ensure_router_code failed, will retry in loop"
	fi

	log "shpun-agent started (API_URL=$API_URL, ENGINE_BIN=$ENGINE_BIN, ENGINE_URL=$ENGINE_URL, ROUTES_URL_BASE=$ROUTES_URL_BASE, MIN_UPTIME=$MIN_UPTIME, NET_FAIL_TIMEOUT=$NET_FAIL_TIMEOUT, PING_HOST=$PING_HOST)"

	NET_FAIL_SECONDS=0

	while :; do
		load_conf

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
			if check_internet; then
				[ "$NET_FAIL_SECONDS" -gt 0 ] && log "internet is back, resetting fail counter (was ${NET_FAIL_SECONDS}s)"
				NET_FAIL_SECONDS=0
			else
				NET_FAIL_SECONDS=$((NET_FAIL_SECONDS + MAIN_LOOP_SLEEP))
				log "no internet detected for ${NET_FAIL_SECONDS}s while VPN is active"

				if [ "$NET_FAIL_SECONDS" -ge "$NET_FAIL_TIMEOUT" ]; then
					log "internet probe failed for ${NET_FAIL_SECONDS}s, keeping tunnel running"
					NET_FAIL_SECONDS=0
				fi
			fi
		else
			NET_FAIL_SECONDS=0
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
