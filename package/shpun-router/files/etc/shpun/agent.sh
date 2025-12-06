#!/bin/sh
#
# shpun-agent (Xray + Shadowsocks transparent edition)
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

HTTP_BIN=""

log() {
	logger -t "$LOG_TAG" "$*"
}

#######################################
# State dir helper
#######################################

ensure_state_dir() {
	[ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null || true
}

#######################################
# Router code helper
#######################################

ensure_router_code() {
	# если код уже есть и не пустой — ничего не делаем
	if [ -s "$CODE_FILE" ]; then
		return 0
	fi

	# пробуем сгенерировать новый код
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
# HTTP client detection
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
	# $1: url, $2: out_file
	local url="$1"
	local out="$2"

	case "$HTTP_BIN" in
		curl)
			curl -fsS "$url" -o "$out"
			;;
		wget)
			wget -qO "$out" "$url"
			;;
		uclient-fetch)
			uclient-fetch -qO "$out" "$url"
			;;
		*)
			return 1
			;;
	esac
}

http_get_stdout() {
	# $1: url
	local url="$1"

	case "$HTTP_BIN" in
		curl)
			curl -fsS "$url"
			;;
		wget)
			wget -qO- "$url"
			;;
		uclient-fetch)
			uclient-fetch -qO- "$url"
			;;
		*)
			return 1
			;;
	esac
}

#######################################
# Arch detection / config
#######################################

detect_engine_arch() {
	local arch

	if [ -f /etc/openwrt_release ]; then
		# shellcheck disable=SC1091
		. /etc/openwrt_release
		arch="$DISTRIB_ARCH"
	fi

	if [ -z "$arch" ] && command -v opkg >/dev/null 2>&1; then
		arch="$(opkg print-architecture 2>/dev/null | awk '$1=="arch"{print $2}' | tail -n1)"
	fi

	case "$arch" in
		mips_24kc)
			echo "mips_24kc"
			;;
		mipsel_24kc|ramips*|mipsel*)
			echo "mipsel_24kc"
			;;
		arm_cortex-a7|arm_cortex-a9|arm_mpcore|armv7*)
			echo "armv7"
			;;
		aarch64*|arm64*)
			echo "aarch64"
			;;
		x86_64)
			echo "amd64"
			;;
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
	# shellcheck disable=SC1090,SC1091
	[ -f "$CONF" ] && . "$CONF"

	[ -z "$API_URL" ]            && API_URL="$API_URL_DEFAULT"
	[ -z "$ENGINE_BIN" ]         && ENGINE_BIN="/tmp/xray"
	[ -z "$ENGINE_CONFIG" ]      && ENGINE_CONFIG="/etc/shpun/xray.json"
	[ -z "$SUB_CHECK_INTERVAL" ] && SUB_CHECK_INTERVAL="$SUB_CHECK_INTERVAL_DEFAULT"

	[ -z "$MIN_UPTIME" ]       && MIN_UPTIME="$MIN_UPTIME_DEFAULT"
	[ -z "$NET_FAIL_TIMEOUT" ] && NET_FAIL_TIMEOUT="$NET_FAIL_TIMEOUT_DEFAULT"
	[ -z "$MAIN_LOOP_SLEEP" ]  && MAIN_LOOP_SLEEP="$MAIN_LOOP_SLEEP_DEFAULT"

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

	# проверка, что файл не пустой
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

	return 0
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

	# минимальная проверка: файл не пустой
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

	if ! engine_download; then
		log "engine_download failed in ensure_vpn_from_subscription"
		return 1
	fi

	if [ ! -x /etc/shpun/build-config.sh ]; then
		log "/etc/shpun/build-config.sh not found or not executable"
		return 1
	fi

	log "building xray config from subscription.json"
	if ! /etc/shpun/build-config.sh; then
		log "build-config.sh failed"
		return 1
	fi

	if ! restart_vpn; then
		log "restart_vpn failed, not marking vpn_ready"
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
# Main loop
#######################################

main_loop() {
	load_conf
	ensure_state_dir
	ensure_router_code

	log "shpun-agent started (API_URL=$API_URL, ENGINE_BIN=$ENGINE_BIN, ENGINE_URL=$ENGINE_URL, MIN_UPTIME=$MIN_UPTIME, NET_FAIL_TIMEOUT=$NET_FAIL_TIMEOUT, PING_HOST=$PING_HOST)"

	NET_FAIL_SECONDS=0

	while :; do
		load_conf

		UPTIME_SECS="$(get_uptime_secs)"
		if [ "$UPTIME_SECS" -lt "$MIN_UPTIME" ]; then
			log "uptime ${UPTIME_SECS}s < ${MIN_UPTIME}s, waiting before managing VPN"
			sleep "$MAIN_LOOP_SLEEP"
			continue
		fi

		# --- INTERNET FAILSAFE ---
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

		# --- SUBSCRIPTION HANDLING ---
		if [ ! -s "$SUB_FILE" ]; then
			poll_subscription_loop
		else
			if [ ! -s "$VPN_READY_FILE" ]; then
				ensure_vpn_from_subscription
			fi

			check_subscription_alive
		fi
		sleep "$MAIN_LOOP_SLEEP"
	done
}

main_loop "$@"
