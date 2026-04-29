#!/bin/sh
#
# shpun-agent (Xray + Shadowsocks/VLESS transparent edition)
#

STATE_DIR="/etc/shpun"
CODE_FILE="$STATE_DIR/router_code"
SUB_FILE="$STATE_DIR/subscription.json"
VPN_READY_FILE="$STATE_DIR/vpn_ready"
LAST_CHECK_FILE="$STATE_DIR/last_sub_check"
CONF="$STATE_DIR/agent.conf"

VERROR_FILE="$STATE_DIR/vpn_error"

LOG_TAG="shpun-agent"

API_URL_DEFAULT="https://bill.shpyn.online/shm/v1/public/router_public"
SUB_CHECK_INTERVAL_DEFAULT=21600  # 6 часов

# Failsafe дефолты
MIN_UPTIME_DEFAULT=120
NET_FAIL_TIMEOUT_DEFAULT=60
MAIN_LOOP_SLEEP_DEFAULT=30

# Routes defaults
ROUTES_DIR="$STATE_DIR/routes"
ROUTES_CIDRS_FILE="$ROUTES_DIR/ru.cidrs"
ROUTES_VER_FILE="$ROUTES_DIR/ru.version"
ROUTES_SHA_FILE="$ROUTES_DIR/ru.sha256"
ROUTES_LAST_CHECK_FILE="$ROUTES_DIR/last_check"
ROUTES_MODE_FILE="$ROUTES_DIR/mode"

ROUTES_URL_BASE_DEFAULT="https://spb.shpyn.online/files/routes"
ROUTES_CHECK_INTERVAL_DEFAULT=43200   # 12 часов

HTTP_BIN=""

log() {
	logger -t "$LOG_TAG" "$*"
}

#######################################
# Helpers
#######################################

get_routing_mode() {
	cat "$ROUTES_MODE_FILE" 2>/dev/null | tr -d '\r\n ' || echo "full"
}

ensure_state_dir() {
	[ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null || true
}

ensure_routes_dir() {
	[ -d "$ROUTES_DIR" ] || mkdir -p "$ROUTES_DIR" 2>/dev/null || true

	[ -f "$ROUTES_MODE_FILE" ]       || echo "full" > "$ROUTES_MODE_FILE"
	[ -f "$ROUTES_VER_FILE" ]        || echo "0"    > "$ROUTES_VER_FILE"
	[ -f "$ROUTES_LAST_CHECK_FILE" ] || echo "0"    > "$ROUTES_LAST_CHECK_FILE"
	[ -f "$ROUTES_SHA_FILE" ]        || : > "$ROUTES_SHA_FILE"
	[ -f "$ROUTES_CIDRS_FILE" ]      || : > "$ROUTES_CIDRS_FILE"
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

	log "failed to generate router code (gen_code.sh missing or returned empty)"
	return 1
}

#######################################
# HTTP client
#######################################

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
		curl)         curl -fsS "$url" -o "$out" ;;
		wget)         wget -qO "$out" "$url" ;;
		uclient-fetch) uclient-fetch -qO "$out" "$url" ;;
		*) return 1 ;;
	esac
}

http_get_stdout() {
	local url="$1"

	case "$HTTP_BIN" in
		curl)         curl -fsS "$url" ;;
		wget)         wget -qO- "$url" ;;
		uclient-fetch) uclient-fetch -qO- "$url" ;;
		*) return 1 ;;
	esac
}

#######################################
# TPROXY modules
#######################################

has_tproxy() {
	command -v nft >/dev/null 2>&1 || return 1

	nft 'add table inet shpun_tproxy_test' >/dev/null 2>&1 || return 1

	nft 'add chain inet shpun_tproxy_test c { type filter hook prerouting priority mangle; policy accept; }' >/dev/null 2>&1 || {
		nft delete table inet shpun_tproxy_test >/dev/null 2>&1
		return 1
	}

	nft 'add rule inet shpun_tproxy_test c meta l4proto udp tproxy to :12346 meta mark set 0xe9' >/dev/null 2>&1
	rc=$?

	nft delete table inet shpun_tproxy_test >/dev/null 2>&1
	return "$rc"
}

ensure_tproxy_modules() {
	has_tproxy && {
		log "tproxy: available"
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

	if has_tproxy; then
		log "tproxy: installed successfully"
		return 0
	fi

	log "tproxy: package installed, but nft tproxy rule is still unavailable"
	return 1
}

#######################################
# Arch detection
#######################################

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
		mips_24kc)                              echo "mips_24kc" ;;
		mipsel_24kc|ramips*|mipsel*)            echo "mipsel_24kc" ;;
		arm_cortex-a7|arm_cortex-a9|arm_mpcore|armv7*) echo "armv7" ;;
		aarch64*|arm64*)                        echo "aarch64" ;;
		x86_64)                                 echo "amd64" ;;
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

#######################################
# Router code
#######################################

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

#######################################
# Routes update / sync
#######################################

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

# Применяет маршруты через firewall-xray.sh init.
# Вызывается только когда CIDR реально изменились.
apply_routes_rules() {
	if [ -x /etc/shpun/firewall-xray.sh ]; then
		log "routes: rebuilding nft route set via firewall-xray.sh init"
		/etc/shpun/firewall-xray.sh init 2>/dev/null || {
			log "routes: firewall-xray.sh init failed"
			return 1
		}
	fi
	return 0
}

# Скачивает CIDR только если версия изменилась.
# Применяет маршруты только если режим split_ru — в режиме full
# firewall-xray.sh init будет вызван из restart_vpn без CIDR.
fetch_routes_once() {
	local remote_ver local_ver remote_sha local_sha
	local tmp_cidrs tmp_sha mode

	ensure_routes_dir
	detect_http_client

	if [ -z "$HTTP_BIN" ]; then
		log "routes: no HTTP client (curl/wget/uclient-fetch)"
		return 1
	fi

	remote_ver="$(http_get_stdout "$ROUTES_URL_BASE/ru.version" 2>/dev/null | tr -d '\r\n ' || true)"
	local_ver="$(cat "$ROUTES_VER_FILE" 2>/dev/null | tr -d '\r\n ' || echo "0")"

	if [ -z "$remote_ver" ]; then
		log "routes: empty remote version"
		return 1
	fi

	# Версия не изменилась — ничего не делаем
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

	# Применяем только если режим split_ru.
	# В режиме full — firewall уже работает без CIDR,
	# пересчитывать его из-за обновления маршрутов не нужно.
	mode="$(get_routing_mode)"
	if [ "$mode" = "split_ru" ]; then
		apply_routes_rules
	else
		log "routes: mode=$mode, skipping nft rebuild (will apply on next split_ru switch)"
	fi

	return 0
}

# Проверяет интервал и при необходимости обновляет CIDR.
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

	fetch_routes_once
	echo "$now_ts" > "$ROUTES_LAST_CHECK_FILE"
}

# Гарантирует наличие CIDR файла.
# В режиме full — пропускаем, CIDR не нужны для работы туннеля.
# В режиме split_ru — скачиваем если отсутствуют.
ensure_routes_ready() {
	ensure_routes_dir

	local mode
	mode="$(get_routing_mode)"

	if [ "$mode" = "full" ]; then
		# В режиме full CIDR не используются — не тратим время на скачивание
		return 0
	fi

	if [ ! -s "$ROUTES_CIDRS_FILE" ]; then
		log "routes: local route file missing, fetching initial copy"
		fetch_routes_once
	fi
}

#######################################
# Engine download / VPN control
#######################################

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
		log "engine_download: no HTTP client (curl/wget/uclient-fetch), cannot download engine"
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

	# НЕ вызываем firewall-xray.sh здесь — shpun-vpn restart уже вызывает
	# firewall-xray.sh init внутри start_service. Двойной вызов только замедляет
	# старт и дважды применяет 8000+ CIDR на медленном MIPS.

	return 0
}

wait_vpn_started() {
	local i=0
	while [ "$i" -lt 20 ]; do
		if pgrep -f "xray.*run.*-config.*xray.json" >/dev/null 2>&1; then
			return 0
		fi
		sleep 1
		i=$((i + 1))
	done
	return 1
}

get_uptime_secs() {
	awk -F. '{print $1}' /proc/uptime 2>/dev/null || echo 0
}

check_internet() {
	ping -c1 -W1 "$PING_HOST" >/dev/null 2>&1
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
				log "default IPv4 route detected (interface not parsed)"
			fi
			return 0
		fi
		i=$((i + 1))
		sleep 2
	done
	log "no default IPv4 route detected after timeout, continuing anyway"
	return 1
}

#######################################
# Subscription fetch / check
#######################################

fetch_subscription_once() {
	if [ -z "$CLEAN_CODE" ] || [ -z "$API_URL" ]; then
		return 1
	fi

	detect_http_client
	if [ -z "$HTTP_BIN" ]; then
		log "fetch_subscription_once: no HTTP client (curl/wget/uclient-fetch)"
		return 1
	fi

	URL="${API_URL}?code=${CLEAN_CODE}&format=json"

	log "query router_public: $URL"
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

	if [ -z "$CONFIG_PATH" ]; then
		log "router_public ok=1 but config_url is empty"
		return 1
	fi

	BASE_URL="${API_URL%/shm/v1/public/router_public}"
	CONFIG_URL="${BASE_URL}${CONFIG_PATH}"

	log "fetching subscription from $CONFIG_URL"

	TMP_SUB="${SUB_FILE}.tmp"

	if ! http_get_to_file "${CONFIG_URL}&format=json" "$TMP_SUB" 2>/dev/null; then
		log "failed to download subscription json"
		rm -f "$TMP_SUB"
		return 1
	fi

	if [ ! -s "$TMP_SUB" ]; then
		log "downloaded subscription json is empty"
		rm -f "$TMP_SUB"
		return 1
	fi

	mv "$TMP_SUB" "$SUB_FILE"
	log "subscription json saved to $SUB_FILE"

	date +%s >"$LAST_CHECK_FILE"

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

	# Скачиваем CIDR только если нужны (режим split_ru)
	ensure_routes_ready

	if ! engine_download; then
		log "engine_download failed in ensure_vpn_from_subscription"
		echo "engine_download_failed" >"$VERROR_FILE"
		rm -f "$VPN_READY_FILE"
		return 1
	fi

	if [ ! -x /etc/shpun/build-config.sh ]; then
		log "/etc/shpun/build-config.sh not found or not executable"
		echo "build_script_missing" >"$VERROR_FILE"
		rm -f "$VPN_READY_FILE"
		return 1
	fi

	ensure_tproxy_modules || true

	log "building xray config from subscription.json"
	if ! /etc/shpun/build-config.sh; then
		log "build-config.sh failed"
		echo "build_config_failed" >"$VERROR_FILE"
		rm -f "$VPN_READY_FILE"
		return 1
	fi

	# restart_vpn вызывает shpun-vpn restart который сам применяет firewall
	if ! restart_vpn; then
		log "restart_vpn failed, not marking vpn_ready"
		echo "restart_vpn_failed" >"$VERROR_FILE"
		rm -f "$VPN_READY_FILE"
		return 1
	fi

	if ! wait_vpn_started; then
		log "xray did not start successfully, not marking vpn_ready"
		echo "xray_failed_to_start" >"$VERROR_FILE"
		rm -f "$VPN_READY_FILE"
		return 1
	fi

	echo "ok" >"$VPN_READY_FILE"
	rm -f "$VERROR_FILE"
	log "vpn_ready marked in $VPN_READY_FILE"

	return 0
}

poll_subscription_loop() {
	if [ -s "$SUB_FILE" ]; then
		log "subscription.json already present, skipping router_public"
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
	[ ! -s "$SUB_FILE" ] && return 0

	now_ts="$(date +%s)"
	last_ts=0
	[ -f "$LAST_CHECK_FILE" ] && last_ts="$(cat "$LAST_CHECK_FILE" 2>/dev/null || echo 0)"

	if [ "$((now_ts - last_ts))" -lt "$SUB_CHECK_INTERVAL" ]; then
		return 0
	fi

	detect_http_client
	if [ -z "$HTTP_BIN" ]; then
		log "check_subscription_alive: no HTTP client (curl/wget/uclient-fetch)"
		echo "$now_ts" >"$LAST_CHECK_FILE"
		return 0
	fi

	UID_SUB="$(jsonfilter -i "$SUB_FILE" -e '@.uid' 2>/dev/null || echo "")"
	USI_SUB="$(jsonfilter -i "$SUB_FILE" -e '@.usi' 2>/dev/null || echo "")"

	if [ -z "$UID_SUB" ] || [ -z "$USI_SUB" ]; then
		log "check_subscription_alive: uid/usi missing in subscription.json"
		echo "$now_ts" >"$LAST_CHECK_FILE"
		return 0
	fi

	if ! get_code; then
		log "check_subscription_alive: failed to get code"
		echo "$now_ts" >"$LAST_CHECK_FILE"
		return 0
	fi

	BASE_URL="${API_URL%/shm/v1/public/router_public}"
	CHECK_URL="${BASE_URL}/shm/v1/public/router_config?uid=${UID_SUB}&usi=${USI_SUB}&code=${CLEAN_CODE}&format=json"

	log "checking subscription via $CHECK_URL"

	BODY="$(http_get_stdout "$CHECK_URL" 2>/dev/null || true)"

	if [ -z "$BODY" ]; then
		log "check_subscription_alive: empty response from router_config"
		echo "$now_ts" >"$LAST_CHECK_FILE"
		return 0
	fi

	OK="$(printf '%s' "$BODY" | jsonfilter -e '@.ok' 2>/dev/null || echo "")"

	if [ "$OK" = "1" ]; then
		printf '%s' "$BODY" >"$SUB_FILE"
		log "subscription_alive: ok=1, subscription.json refreshed"
		echo "$now_ts" >"$LAST_CHECK_FILE"
		rm -f "$VERROR_FILE"
		return 0
	fi

	ERR="$(printf '%s' "$BODY" | jsonfilter -e '@.error' 2>/dev/null || echo "unknown_error")"
	log "subscription_invalid: ok=$OK, error=$ERR — resetting VPN state"

	rm -f "$VPN_READY_FILE"
	rm -f "$SUB_FILE"

	echo "$now_ts" >"$LAST_CHECK_FILE"
	echo "$ERR" >"$VERROR_FILE"

	if [ -x /etc/init.d/shpun-vpn ]; then
		/etc/init.d/shpun-vpn stop 2>/dev/null || true
	fi
	return 1
}

#######################################
# Sanity-check vpn_ready vs реальность
#######################################

vpn_sanity_check() {
	local fail_count=0
	local fail_file="/etc/shpun/vpn_sanity_fail_count"
	local fail_limit=3

	if [ ! -s "/etc/shpun/vpn_ready" ]; then
		rm -f "$fail_file"
		return
	fi

	if [ ! -x "/tmp/xray" ] || [ ! -s "/etc/shpun/xray.json" ]; then
		logger -t shpun-agent "vpn_sanity_check: engine or config missing → reset vpn_ready"
		rm -f "/etc/shpun/vpn_ready"
		rm -f "$fail_file"
		return
	fi

	if pgrep -f "/tmp/xray" >/dev/null 2>&1; then
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

	logger -t shpun-agent "vpn_sanity_check: xray not found ($fail_count/$fail_limit)"

	if [ "$fail_count" -lt "$fail_limit" ]; then
		return
	fi

	logger -t shpun-agent "vpn_sanity_check: FAIL LIMIT reached → reset vpn_ready"
	rm -f "/etc/shpun/vpn_ready"
	rm -f "$fail_file"
}

#######################################
# Main loop
#######################################

main_loop() {
	load_conf
	ensure_state_dir
	ensure_routes_dir

	if ! ensure_router_code; then
		log "initial ensure_router_code failed (router_code empty), will retry in loop"
	fi

	log "shpun-agent started (API_URL=$API_URL, ENGINE_BIN=$ENGINE_BIN, ENGINE_URL=$ENGINE_URL, ROUTES_URL_BASE=$ROUTES_URL_BASE, MIN_UPTIME=$MIN_UPTIME, NET_FAIL_TIMEOUT=$NET_FAIL_TIMEOUT, PING_HOST=$PING_HOST)"

	NET_FAIL_SECONDS=0

	while :; do
		load_conf

		if [ ! -s "$CODE_FILE" ]; then
			if ! ensure_router_code; then
				log "ensure_router_code failed in loop (router_code still empty), retry in 10s"
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
					log "no internet for ${NET_FAIL_SECONDS}s (>= ${NET_FAIL_TIMEOUT}s), stopping shpun-vpn and clearing vpn_ready"
					if [ -x /etc/init.d/shpun-vpn ]; then
						/etc/init.d/shpun-vpn stop 2>/dev/null || true
					fi
					rm -f "$VPN_READY_FILE"
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