#!/bin/sh
#
# shpun-agent (новая схема с проверкой подписки + failsafe)
#
# Логика:
#   1) Получаем / читаем router_code.
#   2) Если subscription.json ещё нет:
#       - чистим код до A-Z0-9 (AAAA-AAAA -> AAAAAAAA)
#       - дергаем router_public?code=<CLEAN_CODE>&format=json
#       - из ответа берём config_url (router_config) и скачиваем subscription.json
#   3) Если subscription.json уже есть:
#       - докачиваем движок (ENGINE_URL из agent.conf)
#       - вызываем /etc/shpun/build-config.sh -> генерим sing-box.json (Reality)
#       - стартуем shpun-vpn, ставим vpn_ready
#   4) Периодически (SUB_CHECK_INTERVAL) валидируем подписку:
#       - читаем uid/usi из subscription.json
#       - вызываем router_config?uid=<uid>&usi=<usi>&code=<CLEAN_CODE>
#       - если ok=1 — подписка жива, обновляем subscription.json
#       - если ok!=1 (pair_not_found, no_links_in_service и т.п.) — сбрасываем VPN:
#           * удаляем subscription.json и vpn_ready
#           * ждём новую привязку (шаг 2)
#   5) Failsafe:
#       - если uptime < MIN_UPTIME (120с по умолчанию) — VPN не трогаем
#       - если при активном VPN нет интернета NET_FAIL_TIMEOUT (60с по умолчанию) —
#         останавливаем shpun-vpn и снимаем vpn_ready

STATE_DIR="/etc/shpun"
CODE_FILE="$STATE_DIR/router_code"
SUB_FILE="$STATE_DIR/subscription.json"
VPN_READY_FILE="$STATE_DIR/vpn_ready"
LAST_CHECK_FILE="$STATE_DIR/last_sub_check"
CONF="$STATE_DIR/agent.conf"

LOG_TAG="shpun-agent"

API_URL_DEFAULT="https://bill.shpyn.online/shm/v1/public/router_public"
SUB_CHECK_INTERVAL_DEFAULT=21600  # 6 часов

# Failsafe дефолты (можно переопределить в agent.conf)
MIN_UPTIME_DEFAULT=120        # не трогать VPN, пока роутер не проработал 2 минуты
NET_FAIL_TIMEOUT_DEFAULT=60   # если нет интернета 60 секунд при активном VPN — стоп
MAIN_LOOP_SLEEP_DEFAULT=30    # задержка основного цикла

log() {
	logger -t "$LOG_TAG" "$*"
}

load_conf() {
	# shellcheck disable=SC1090,SC1091
	[ -f "$CONF" ] && . "$CONF"

	[ -z "$API_URL" ]            && API_URL="$API_URL_DEFAULT"
	[ -z "$ENGINE_NAME" ]        && ENGINE_NAME="sing-box"
	[ -z "$ENGINE_BIN" ]         && ENGINE_BIN="/tmp/sing-box"
	[ -z "$ENGINE_CONFIG" ]      && ENGINE_CONFIG="/etc/shpun/sing-box.json"
	[ -z "$SUB_CHECK_INTERVAL" ] && SUB_CHECK_INTERVAL="$SUB_CHECK_INTERVAL_DEFAULT"

	# Failsafe параметры (можно задавать в agent.conf)
	[ -z "$MIN_UPTIME" ]       && MIN_UPTIME="$MIN_UPTIME_DEFAULT"
	[ -z "$NET_FAIL_TIMEOUT" ] && NET_FAIL_TIMEOUT="$NET_FAIL_TIMEOUT_DEFAULT"
	[ -z "$MAIN_LOOP_SLEEP" ]  && MAIN_LOOP_SLEEP="$MAIN_LOOP_SLEEP_DEFAULT"

	# Хост для ping-проверки интернета: по умолчанию DNS_ADDR1 (если задан),
	# иначе 8.8.8.8. Можно переопределить PING_HOST в agent.conf.
	if [ -z "$PING_HOST" ]; then
		if [ -n "$DNS_ADDR1" ]; then
			PING_HOST="$DNS_ADDR1"
		else
			PING_HOST="8.8.8.8"
		fi
	fi
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

has_tun() {
	[ -c /dev/net/tun ]
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

	# Проверку SHA256 убрали сознательно (дорого по CPU на слабом железе)

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

# --- uptime и проверка интернета для failsafe --- #

get_uptime_secs() {
	# /proc/uptime: "<seconds> <idle>"
	awk -F. '{print $1}' /proc/uptime 2>/dev/null || echo 0
}

check_internet() {
	# Пингуем один раз с таймаутом 1 сек.
	# При активном VPN этого достаточно, чтобы понять, не схлопнулось ли всё в /dev/null.
	ping -c1 -W1 "$PING_HOST" >/dev/null 2>&1
}

# --- запрос router_public и скачивание subscription.json через router_config --- #
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

	CONFIG_PATH="$(printf '%s' "$BODY" | jsonfilter -e '@.config_url' 2>/dev/null || echo "")"

	if [ -z "$CONFIG_PATH" ]; then
		log "router_public ok=1 but config_url is empty"
		return 1
	fi

	# Собираем полный URL до router_config на том же хосте, что и API_URL
	BASE_URL="${API_URL%/shm/v1/public/router_public}"
	CONFIG_URL="${BASE_URL}${CONFIG_PATH}"

	log "fetching subscription from $CONFIG_URL"

	TMP_SUB="${SUB_FILE}.tmp"

	if ! uclient-fetch -qO "$TMP_SUB" "${CONFIG_URL}&format=json" 2>/dev/null; then
		log "failed to download subscription json"
		rm -f "$TMP_SUB"
		return 1
	fi

	mv "$TMP_SUB" "$SUB_FILE"
	log "subscription json saved to $SUB_FILE"

	date +%s >"$LAST_CHECK_FILE"

	return 0
}

# --- создание VPN по уже имеющемуся subscription.json --- #
ensure_vpn_from_subscription() {
	if [ ! -s "$SUB_FILE" ]; then
		log "ensure_vpn_from_subscription: $SUB_FILE not found"
		return 1
	fi

	if ! has_tun; then
		log "ensure_vpn_from_subscription: /dev/net/tun is missing, please install kmod-tun"
		return 1
	fi

	if ! engine_download; then
		log "engine_download failed in ensure_vpn_from_subscription"
		return 1
	fi

	if [ ! -x /etc/shpun/build-config.sh ]; then
		log "/etc/shpun/build-config.sh not found or not executable"
		return 1
	fi

	log "building sing-box config from subscription.json"
	if ! /etc/shpun/build-config.sh; then
		log "build-config.sh failed"
		return 1
	fi

	if ! restart_vpn; then
		log "restart_vpn failed, not marking vpn_ready"
		return 1
	fi

	touch "$VPN_READY_FILE"
	log "vpn_ready marked in $VPN_READY_FILE"

	return 0
}

# --- режим ожидания первой подписки --- #
poll_subscription_loop() {
	# если subscription.json уже есть — не трогаем router_public вообще
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
			# получили subscription.json, дальше создаём VPN на её основе
			ensure_vpn_from_subscription
			return 0
		fi

		log "no subscription yet, retry in 20s"
		sleep 20
	done
}

# --- периодическая проверка: подписка всё ещё валидна в хранилище? --- #
check_subscription_alive() {
	[ ! -s "$SUB_FILE" ] && return 0

	now_ts="$(date +%s)"
	last_ts=0
	[ -f "$LAST_CHECK_FILE" ] && last_ts="$(cat "$LAST_CHECK_FILE" 2>/dev/null || echo 0)"

	# если ещё не пришло время — выходим
	if [ "$((now_ts - last_ts))" -lt "$SUB_CHECK_INTERVAL" ]; then
		return 0
	fi

	# читаем uid/usi из subscription.json
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

	BODY="$(uclient-fetch -qO- "$CHECK_URL" 2>/dev/null || true)"

	if [ -z "$BODY" ]; then
		log "check_subscription_alive: empty response from router_config"
		echo "$now_ts" >"$LAST_CHECK_FILE"
		return 0
	fi

	OK="$(printf '%s' "$BODY" | jsonfilter -e '@.ok' 2>/dev/null || echo "")"

	if [ "$OK" = "1" ]; then
		# подписка жива — обновляем файл (вдруг links/лимиты поменялись)
		printf '%s' "$BODY" >"$SUB_FILE"
		log "subscription_alive: ok=1, subscription.json refreshed"
		echo "$now_ts" >"$LAST_CHECK_FILE"
		return 0
	fi

	ERR="$(printf '%s' "$BODY" | jsonfilter -e '@.error' 2>/dev/null || echo "unknown_error")"
	log "subscription_invalid: ok=$OK, error=$ERR — resetting VPN state"

	rm -f "$VPN_READY_FILE"
	rm -f "$SUB_FILE"

	echo "$now_ts" >"$LAST_CHECK_FILE"
	echo "$ERR" >"$STATE_DIR/vpn_error"

	if [ -x /etc/init.d/shpun-vpn ]; then
		/etc/init.d/shpun-vpn stop 2>/dev/null || true
	fi

	return 1
}

main_loop() {
	load_conf
	ensure_state_dir

	log "shpun-agent started (API_URL=$API_URL, ENGINE_BIN=$ENGINE_BIN, MIN_UPTIME=$MIN_UPTIME, NET_FAIL_TIMEOUT=$NET_FAIL_TIMEOUT, PING_HOST=$PING_HOST)"

	NET_FAIL_SECONDS=0

	while :; do
		load_conf

		# --- 0) Failsafe: ждём, пока роутер хотя бы MIN_UPTIME секунд живёт ---
		UPTIME_SECS="$(get_uptime_secs)"
		if [ "$UPTIME_SECS" -lt "$MIN_UPTIME" ]; then
			log "uptime ${UPTIME_SECS}s < ${MIN_UPTIME}s, waiting before managing VPN"
			sleep "$MAIN_LOOP_SLEEP"
			continue
		fi

		# --- 0.5) Failsafe: если VPN активен, проверяем интернет ---
		if [ -s "$VPN_READY_FILE" ]; then
			if check_internet; then
				# интернет есть — сбрасываем счётчик
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
					# после этого в следующей итерации ensure_vpn_from_subscription попробует поднять VPN заново
				fi
			fi
		else
			NET_FAIL_SECONDS=0
		fi

		# 1) если ещё нет subscription.json — ждём её через router_public/router_config
		if [ ! -s "$SUB_FILE" ]; then
			poll_subscription_loop
		else
			# 2) если есть subscription.json, но нет vpn_ready — поднимаем VPN
			if [ ! -s "$VPN_READY_FILE" ]; then
				ensure_vpn_from_subscription
			fi

			# 3) периодически проверяем валидность подписки через router_config
			check_subscription_alive
		fi

		# основной цикл не должен жрать CPU
		sleep "$MAIN_LOOP_SLEEP"
	done
}

main_loop "$@"
