#!/bin/sh
#
# shpun-agent (упрощённый)
#   - получает / генерирует код роутера;
#   - опрашивает router_public по этому коду;
#   - при ok=1 + subscription_url пишет файлы
#     /etc/shpun/subscription_url и /etc/shpun/vpn_ready.
# shellcheck disable=SC2034,SC1090,SC1091

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
	[ -f "$CONF" ] && . "$CONF"
	[ -z "$API_URL" ] && API_URL="$API_URL_DEFAULT"
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

fetch_subscription_once() {
	[ -z "$CLEAN_CODE" ] && return 1
	[ -z "$API_URL" ] && return 1

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

	# позже сюда можно добавить скачивание конфига/движка
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
		get_code || {
			log "failed to get code, retry in 15s"
			sleep 15
			continue
		}

		log "router code: $CODE (clean: $CLEAN_CODE)"

		fetch_subscription_once && {
			# успех
			return 0
		}

		log "no subscription yet, retry in 20s"
		sleep 20
	done
}

main_loop() {
	load_conf
	ensure_state_dir

	log "shpun-agent started (simple mode, API_URL=$API_URL)"

	poll_subscription_loop

	# можно добавить периодическую проверку подписки, пока просто ждём и выходим
	sleep 600
}

main_loop "$@"
