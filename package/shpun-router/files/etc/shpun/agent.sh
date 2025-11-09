#!/bin/sh

STATE_DIR="/etc/shpun"
CODE_FILE="$STATE_DIR/router_code"
SUB_FILE="$STATE_DIR/subscription_url"
VPN_READY_FILE="$STATE_DIR/vpn_ready"
XRAY_CONF="/etc/xray/config.json"
XRAY_INIT="/etc/init.d/xray"
API_URL="https://bill.shpyn.online/shm/v1/public/router_public"

POLL_INTERVAL_OK=60    # когда всё ок, как часто опрашивать
POLL_INTERVAL_FAIL=15  # пауза при ошибках

set -eu

log() {
	logger -t shpun-agent "$*"
}

ensure_prereqs() {
	if ! command -v curl >/dev/null 2>&1; then
		log "curl not found, exiting"
		exit 1
	fi

	if [ ! -x /etc/shpun/gen_code.sh ]; then
		log "/etc/shpun/gen_code.sh missing or not executable"
		exit 1
	fi
}

ensure_state_dir() {
	if ! mkdir -p "$STATE_DIR"; then
		log "failed to create $STATE_DIR"
		exit 1
	fi
}

get_or_create_code() {
	if [ ! -s "$CODE_FILE" ]; then
		log "router code not found, generating..."
		if ! /etc/shpun/gen_code.sh >/dev/null 2>&1; then
			log "router code generation failed"
			return 1
		fi
	fi

	CODE=$(cat "$CODE_FILE" 2>/dev/null || echo "")
	if [ -z "$CODE" ]; then
		log "router code is empty"
		return 1
	fi

	printf '%s\n' "$CODE"
}

fetch_json() {
	URL=$1
	curl -fsS "$URL" 2>/dev/null || return 1
}

parse_ok() {
	printf '%s\n' "$1" | grep -o '"ok":[0-9]*' | head -n1 | cut -d: -f2
}

parse_sub_url() {
	printf '%s\n' "$1" | sed -n 's/.*"subscription_url":"\([^"]*\)".*/\1/p'
}

download_xray_conf() {
	SUB_URL=$1
	TMP="$XRAY_CONF.tmp"

	if ! curl -fsS "$SUB_URL" -o "$TMP" 2>/dev/null; then
		log "failed to download config from subscription url"
		rm -f "$TMP"
		return 1
	fi

	if [ ! -s "$TMP" ]; then
		log "downloaded config is empty"
		rm -f "$TMP"
		return 1
	fi

	mv "$TMP" "$XRAY_CONF"
	return 0
}

restart_xray() {
	if [ ! -x "$XRAY_INIT" ]; then
		log "xray init script not found at $XRAY_INIT"
		return 1
	fi

	"$XRAY_INIT" enable >/dev/null 2>&1 || true
	if ! "$XRAY_INIT" restart >/dev/null 2>&1; then
		log "failed to restart xray"
		return 1
	fi

	log "xray restarted"
	return 0
}

main_loop() {
	while :; do
		CODE=$(get_or_create_code || echo "")
		if [ -z "$CODE" ]; then
			log "no valid router code, retry in ${POLL_INTERVAL_FAIL}s"
			sleep "$POLL_INTERVAL_FAIL"
			continue
		fi

		log "polling API for code=$CODE"
		JSON=$(fetch_json "$API_URL?code=$CODE&format=json" || echo "")
		if [ -z "$JSON" ]; then
			log "API request failed, retry in ${POLL_INTERVAL_FAIL}s"
			sleep "$POLL_INTERVAL_FAIL"
			continue
		fi

		OK=$(parse_ok "$JSON")
		if [ "$OK" != "1" ]; then
			log "API response ok=$OK, wait ${POLL_INTERVAL_FAIL}s"
			sleep "$POLL_INTERVAL_FAIL"
			continue
		fi

		SUB=$(parse_sub_url "$JSON" || echo "")
		if [ -z "$SUB" ]; then
			log "ok=1 but subscription_url missing, retry in ${POLL_INTERVAL_FAIL}s"
			sleep "$POLL_INTERVAL_FAIL"
			continue
		fi

		printf '%s\n' "$SUB" >"$SUB_FILE"
		rm -f "$VPN_READY_FILE"
		log "received subscription url"

		if ! download_xray_conf "$SUB"; then
			rm -f "$SUB_FILE"
			log "config download failed, retry in ${POLL_INTERVAL_FAIL}s"
			sleep "$POLL_INTERVAL_FAIL"
			continue
		fi

		if restart_xray; then
			printf '1\n' >"$VPN_READY_FILE"
		else
			rm -f "$VPN_READY_FILE"
		fi

		sleep "$POLL_INTERVAL_OK"
	done
}

ensure_prereqs
ensure_state_dir

log "shpun-agent started"
main_loop
