#!/bin/sh
#
# shpun-agent
#   - получает / генерирует код роутера;
#   - опрашивает router_public по этому коду;
#   - при ok=1 + subscription_url:
#       * сохраняет ссылку
#       * качает VPN-движок
#       * качает конфиг
#       * рестартует shpun-vpn
#       * ставит vpn_ready

STATE_DIR="/etc/shpun"
CODE_FILE="$STATE_DIR/router_code"
SUB_FILE="$STATE_DIR/subscription_url"
VPN_READY_FILE="$STATE_DIR/vpn_ready"
CONF="$STATE_DIR/agent.conf"

LOG_TAG="shpun-agent"

API_URL_DEFAULT="https://bill.shpyn.online/shm/v1/public/router_public"

log() {
	logger -t "$LOG_TAG" "$*"
}

load_conf() {
	# shellcheck disable=SC1090,SC1091
	[ -f "$CONF" ] && . "$CONF"

	[ -z "$API_URL" ]        && API_URL="$API_URL_DEFAULT"
	[ -z "$ENGINE_NAME" ]    && ENGINE_NAME="sing-box"
	[ -z "$ENGINE_BIN" ]     && ENGINE_BIN="/tmp/sing-box"
	[ -z "$ENGINE_CONFIG" ]  && ENGINE_CONFIG="/etc/shpun/sing-box.json"
}

ensure_state_dir() {
	mkdir -p "$STATE_DIR" 2>/dev/null || {
		log "failed to create $STATE_DIR"
		exit 1
	}
}

get_code() {
	# если файл уже есть — читаем
	if [ -s "$CODE_FILE" ]; then
		CODE="$(cat "$CODE_FILE" 2>/dev/null || true)"
	else
		# иначе пробуем сгенерировать
		if [ -x /etc/shpun/gen_code.sh ]; then
			CODE="$(/etc/shpun/gen_code.sh 2>/dev/null | head -n1 || true)"
		fi
		[ -n "$CODE" ] && echo "$CODE" >"$CODE_FILE"
	fi

	# убираем переводы строк
	CODE="$(printf '%s' "$CODE" | tr -d '\r\n')"

	if [ -z "$CODE" ]; then
		log "router code is empty"
		return 1
	fi

	# clean_code: только A-Z0-9, без дефиса
	CLEAN_CODE="$(printf '%s' "$CODE" | tr -dc 'A-Z0-9')"

	if [ -z "$CLEAN_CODE" ]; then
		log "clean code is empty after filtering: $CODE"
		return 1
	fi

	return 0
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

	log "downloading engine from $ENGINE_URL to $ENGINE_BIN"
	if ! uclient-fetch -qO "$ENGINE_BIN" "$ENGINE_URL" 2>/dev/null; then
		log "failed to download engine"
		rm -f "$ENGINE_BIN"
		return 1
	fi

	if ! chmod +x "$ENGINE_BIN" 2>/dev/null; then
		log "failed to chmod +x engine"
		rm -f "$ENGINE_BIN"
		return 1
	fi

	if [ -n "$ENGINE_SHA256" ]; then
		sum="$(sha256sum "$ENGINE_BIN" 2>/dev/null | awk '{print $1}')"
		sum_lc="$(printf '%s' "$sum" | tr 'A-Z' 'a-z')"
		ref_lc="$(printf '%s' "$ENGINE_SHA256" | tr 'A-Z' 'a-z')"

		if [ "$sum_lc" != "$ref_lc" ]; then
			log "engine sha256 mismatch: got=$sum expected=$ENGINE_SHA256, removing"
			rm -f "$ENGINE_BIN"
			return 1
		fi
	fi


	log "engine downloaded and ready: $ENGINE_BIN"
	return 0
}

config_download() {
	sub="$1"

	if [ -z "$sub" ]; then
		log "config_download: empty subscription_url"
		return 1
	fi

	log "downloading config to $ENGINE_CONFIG from $sub"
	if ! uclient-fetch -qO "$ENGINE_CONFIG" "$sub" 2>/dev/null; then
		log "failed to download config"
		rm -f "$ENGINE_CONFIG"
		return 1
	fi

	log "config saved to $ENGINE_CONFIG"
	return 0
}

restart_vpn() {
	if [ -x /etc/init.d/shpun-vpn ]; then
		log "restarting shpun-vpn"
		/etc/init.d/shpun-vpn restart 2>/dev/null || log "failed to restart shpun-vpn"
	else
		log "shpun-vpn init script not found"
	fi
}

fetch_subscription_once() {
	if [ -z "$CLEAN_CODE" ] || [ -z "$API_URL" ]; then
		return 1
	fi

	URL="${API_URL}?code=${CLEAN_CODE}&format=json"

	log "query router_public: $URL"
	BODY="$(uclient-fetch -qO- "$URL" 2>/dev/null || true)"

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

	SUB="$(printf '%s' "$BODY" | jsonfilter -e '@.subscription_url' 2>/dev/null || echo "")"

	if [ -z "$SUB" ]; then
		log "router_public ok=1 but subscription_url is empty"
		return 1
	fi

	printf '%s\n' "$SUB" >"$SUB_FILE"
	log "subscription_url saved to $SUB_FILE"

	# === качаем движок ===
	if ! engine_download; then
		log "engine_download failed, will retry later"
		return 1
	fi

	# === качаем конфиг ===
	if ! config_download "$SUB"; then
		log "config_download failed, will retry later"
		return 1
	fi

	# === перезапускаем shpun-vpn ===
	restart_vpn

	# === помечаем vpn_ready ===
	touch "$VPN_READY_FILE"
	log "vpn_ready marked in $VPN_READY_FILE"

	return 0
}

poll_subscription_loop() {
	# если уже всё есть — выходим
	if [ -s "$SUB_FILE" ] && [ -s "$VPN_READY_FILE" ]; then
		log "subscription already present and vpn_ready set, exiting"
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
			# успех
			return 0
		fi

		log "no subscription or engine/config yet, retry in 20s"
		sleep 20
	done
}

main_loop() {
	load_conf
	ensure_state_dir

	log "shpun-agent started (with engine management, API_URL=$API_URL)"

	poll_subscription_loop

	# можно добавить периодические проверки, пока просто ждём
	sleep 600
}

main_loop "$@"
