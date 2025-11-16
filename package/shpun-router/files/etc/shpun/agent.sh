#!/bin/sh
#
# shpun-agent
#   - получает / генерирует код роутера;
#   - если subscription_url ещё нет:
#       * опрашивает router_public по CLEAN_CODE (A-Z0-9);
#       * при ok=1 + subscription_url:
#           - сохраняет ссылку
#           - качает VPN-движок
#           - качает конфиг
#           - рестартует shpun-vpn
#           - ставит vpn_ready
#   - если subscription_url уже есть:
#       * следит, чтобы движок/конфиг/VPN были подняты
#       * раз в N секунд (по умолчанию 6 часов) проверяет, что subscription_url ещё доступна

STATE_DIR="/etc/shpun"
CODE_FILE="$STATE_DIR/router_code"
SUB_FILE="$STATE_DIR/subscription_url"
VPN_READY_FILE="$STATE_DIR/vpn_ready"
LAST_CHECK_FILE="$STATE_DIR/last_sub_check"
CONF="$STATE_DIR/agent.conf"

LOG_TAG="shpun-agent"

API_URL_DEFAULT="https://bill.shpyn.online/shm/v1/public/router_public"

# интервал проверки подписки (секунды), по умолчанию 6 часов
SUB_CHECK_INTERVAL_DEFAULT=21600

log() {
	logger -t "$LOG_TAG" "$*"
}

load_conf() {
	# shellcheck disable=SC1090,SC1091
	[ -f "$CONF" ] && . "$CONF"

	[ -z "$API_URL" ]              && API_URL="$API_URL_DEFAULT"
	[ -z "$ENGINE_NAME" ]          && ENGINE_NAME="sing-box"
	# по умолчанию кладём движок в /tmp/shpun/sing-box
	[ -z "$ENGINE_BIN" ]           && ENGINE_BIN="/tmp/shpun/sing-box"
	[ -z "$ENGINE_CONFIG" ]        && ENGINE_CONFIG="/etc/shpun/sing-box.json"
	[ -z "$SUB_CHECK_INTERVAL" ]   && SUB_CHECK_INTERVAL="$SUB_CHECK_INTERVAL_DEFAULT"
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

	# CLEAN_CODE: только A-Z0-9 (AAAA-AAAA -> AAAAAAAA)
	CLEAN_CODE="$(printf '%s' "$CODE" | tr '[:lower:]' '[:upper:]' | tr -dc 'A-Z0-9')"

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

	mkdir -p "$(dirname "$ENGINE_BIN")" 2>/dev/null || true

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
		if [ "$sum" != "$ENGINE_SHA256" ]; then
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

# --- режим ожидания временного ключа / первой подписки --- #
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

	# сброс таймера проверки подписки
	date +%s >"$LAST_CHECK_FILE"

	# дальше обработаем через ensure_vpn_from_subscription
	return 0
}

poll_subscription_loop() {
	# если subscription_url уже есть — не трогаем router_public вообще
	if [ -s "$SUB_FILE" ]; then
		SUB="$(cat "$SUB_FILE" 2>/dev/null || echo "")"
		if [ -n "$SUB" ]; then
			log "subscription_url already present, skipping router_public"
			ensure_vpn_from_subscription "$SUB"
			return 0
		fi
	fi

	while :; do
		if ! get_code; then
			log "failed to get code, retry in 15s"
			sleep 15
			continue
		fi

		log "router code: $CODE (clean: $CLEAN_CODE)"

		if fetch_subscription_once; then
			# получили subscription_url, дальше создаём VPN на её основе
			SUB="$(cat "$SUB_FILE" 2>/dev/null || echo "")"
			ensure_vpn_from_subscription "$SUB"
			return 0
		fi

		log "no subscription yet, retry in 20s"
		sleep 20
	done
}

# --- работа по уже известной subscription_url --- #
ensure_vpn_from_subscription() {
	sub="$1"

	if [ -z "$sub" ]; then
		log "ensure_vpn_from_subscription: empty subscription_url"
		return 1
	fi

	log "ensuring VPN from subscription_url"

	if ! engine_download; then
		log "engine_download failed in ensure_vpn_from_subscription"
		return 1
	fi

	if ! config_download "$sub"; then
		log "config_download failed in ensure_vpn_from_subscription"
		return 1
	fi

	restart_vpn

	touch "$VPN_READY_FILE"
	log "vpn_ready marked in $VPN_READY_FILE"

	return 0
}

check_subscription_alive() {
	[ ! -s "$SUB_FILE" ] && return 0

	sub="$(cat "$SUB_FILE" 2>/dev/null || echo "")"
	[ -z "$sub" ] && return 0

	now_ts="$(date +%s)"
	last_ts=0
	[ -f "$LAST_CHECK_FILE" ] && last_ts="$(cat "$LAST_CHECK_FILE" 2>/dev/null || echo 0)"

	# если ещё не пришло время — выходим
	if [ "$((now_ts - last_ts))" -lt "$SUB_CHECK_INTERVAL" ]; then
		return 0
	fi

	log "checking subscription_url still valid..."
	if uclient-fetch -qO- "$sub" >/dev/null 2>&1; then
		log "subscription_url OK"
		echo "$now_ts" >"$LAST_CHECK_FILE"
		return 0
	fi

	log "subscription_url seems invalid, resetting VPN state"
	rm -f "$VPN_READY_FILE"
	rm -f "$SUB_FILE"
	echo "$now_ts" >"$LAST_CHECK_FILE"
	echo "subscription_invalid" >"$STATE_DIR/vpn_error"

	return 1
}

main_loop() {
	load_conf
	ensure_state_dir

	log "shpun-agent started (API_URL=$API_URL, ENGINE_BIN=$ENGINE_BIN)"

	while :; do
		load_conf

		# 1) если ещё нет subscription_url — ждём её через router_public
		if [ ! -s "$SUB_FILE" ]; then
			poll_subscription_loop
		else
			# 2) если есть subscription_url, но нет vpn_ready — поднимаем VPN
			if [ ! -s "$VPN_READY_FILE" ]; then
				sub="$(cat "$SUB_FILE" 2>/dev/null || echo "")"
				[ -n "$sub" ] && ensure_vpn_from_subscription "$sub"
			fi

			# 3) периодически проверяем, что подписка ещё жива
			check_subscription_alive
		fi

		# основной цикл не должен жрать CPU
		sleep 30
	done
}

main_loop "$@"
