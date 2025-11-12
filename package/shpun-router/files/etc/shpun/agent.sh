#!/bin/sh
# Shpun agent v2 — POSIX clean: получает subscription_url из биллинга,
# дальше проверяет саму ссылку: 200=ОК (редкий опрос), 404/ошибка=НЕ настроен (частый опрос).

STATE_DIR="/etc/shpun"
CODE_FILE="$STATE_DIR/router_code"
SUB_FILE="$STATE_DIR/subscription_url"
VPN_READY_FILE="$STATE_DIR/vpn_ready"
XRAY_CONF="/etc/xray/config.json"
XRAY_INIT="/etc/init.d/xray"

# Биллинг (куда ходим, пока роутер не настроен)
API_URL="https://bill.shpyn.online/shm/v1/public/router_public"

# Интервалы
POLL_BASE=30                 # старт опроса биллинга
POLL_MAX=$((10*60))          # максимум бэкоффа
POLL_JIT=15                  # ±15% к backoff

OK_INTERVAL=$((6*60*60))     # 6 часов при 200 OK
OK_JIT_MIN=$((10*60))        # минимальный джиттер при OK (±10 мин)
OK_JIT_MAX=$((30*60))        # максимальный джиттер при OK (±30 мин)

FAIL_INTERVAL=60             # 1 мин при NOT OK

set -eu

log() { logger -t shpun-agent "$*"; }

# ---------- HTTP ----------
HTTP_TOOL=""

detect_http_client() {
	if command -v curl >/dev/null 2>&1; then
		HTTP_TOOL="curl"
	elif command -v uclient-fetch >/dev/null 2>&1; then
		HTTP_TOOL="uclient"
	elif command -v wget >/dev/null 2>&1; then
		HTTP_TOOL="wget"
	else
		HTTP_TOOL=""
	fi
}

http_get() {
	case "$HTTP_TOOL" in
		curl)    curl -fsS "$1" ;;
		uclient) uclient-fetch -qO- "$1" ;;
		wget)    wget -qO- "$1" ;;
		*)       return 1 ;;
	esac
}

http_download() {
	url="$1"; file="$2"
	case "$HTTP_TOOL" in
		curl)    curl -fsS "$url" -o "$file" ;;
		uclient) uclient-fetch -qO "$file" "$url" ;;
		wget)    wget -qO "$file" "$url" ;;
		*)       return 1 ;;
	esac
}

http_code() {
	url="$1"
	case "$HTTP_TOOL" in
		curl)
			curl -fsS -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo 000
			;;
		wget)
			wget -S --spider "$url" 2>&1 | awk '/HTTP\/[0-9.]+/ {c=$2} END{if(c=="") c=0; print c}' || echo 000
			;;
		uclient)
			head="$(uclient-fetch -qO- "$url" 2>/dev/null | head -c 256 || true)"
			[ -z "$head" ] && { echo 000; return; }
			echo "$head" | grep -qi 'not found' && echo 404 || echo 200
			;;
		*)
			echo 000
			;;
	esac
}

# ---------- utils ----------
ensure_prereqs() {
	detect_http_client
	[ -n "$HTTP_TOOL" ] || { log "no HTTP client"; exit 1; }
	[ -x /etc/shpun/gen_code.sh ] || { log "gen_code.sh missing"; exit 1; }
}

ensure_state_dir() { mkdir -p "$STATE_DIR" || exit 1; }

get_or_create_code() {
	if [ ! -s "$CODE_FILE" ]; then
		log "router code not found, generating..."
		/etc/shpun/gen_code.sh >/dev/null 2>&1 || { log "code generation failed"; return 1; }
	fi
	CODE="$(cat "$CODE_FILE" 2>/dev/null || true)"
	[ -n "$CODE" ] || { log "router code empty"; return 1; }
	echo "$CODE"
}

fetch_json() { http_get "$1" 2>/dev/null || return 1; }

parse_ok() { echo "$1" | grep -o '"ok":[0-9]*' | head -n1 | cut -d: -f2; }

parse_sub_url() { echo "$1" | sed -n 's/.*"subscription_url":"\([^"]*\)".*/\1/p'; }

download_xray_conf() {
	SUB_URL="$1"; TMP="$XRAY_CONF.tmp"
	http_download "$SUB_URL" "$TMP" 2>/dev/null || { rm -f "$TMP"; return 1; }
	[ -s "$TMP" ] || { rm -f "$TMP"; return 1; }
	mv "$TMP" "$XRAY_CONF"
	return 0
}

restart_xray() {
	[ -x "$XRAY_INIT" ] || return 0
	"$XRAY_INIT" enable >/dev/null 2>&1 || true
	"$XRAY_INIT" restart >/dev/null 2>&1 || true
	log "xray restarted"
}

stop_xray() { [ -x "$XRAY_INIT" ] && "$XRAY_INIT" stop >/dev/null 2>&1 || true; }

# rand(min,max) — POSIX-псевдослучайное число через awk
rand() { awk -v min="$1" -v max="$2" 'BEGIN{srand(); print int(min+rand()*(max-min+1))}'; }

# ---------- main ----------
main_loop() {
	backoff=$POLL_BASE
	while :; do
		# 1) пока нет ссылки — тянем из биллинга с бэкоффом
		if [ ! -s "$SUB_FILE" ]; then
			CODE="$(get_or_create_code || true)"
			[ -z "$CODE" ] && { sleep "$POLL_BASE"; continue; }

			JSON="$(fetch_json "$API_URL?code=$CODE&format=json" || true)"
			OK="$(parse_ok "$JSON" || echo 0)"
			if [ "$OK" = "1" ]; then
				SUB="$(parse_sub_url "$JSON" || true)"
				if [ -n "$SUB" ]; then
					echo "$SUB" >"$SUB_FILE"
					log "got subscription_url"
					download_xray_conf "$SUB" && restart_xray || true
					echo 1 >"$VPN_READY_FILE"
					backoff=$POLL_BASE
				fi
			fi

			if [ ! -s "$SUB_FILE" ]; then
				# backoff ±15%
				jup=$(( backoff + backoff * POLL_JIT / 100 ))
				sleep "$(rand "$backoff" "$jup")"
				backoff=$(( backoff + backoff/2 ))
				[ "$backoff" -gt "$POLL_MAX" ] && backoff="$POLL_MAX"
				continue
			fi
		fi

		# 2) есть ссылка — проверяем 200/404
		SUB_URL="$(cat "$SUB_FILE" 2>/dev/null || true)"
		[ -z "$SUB_URL" ] && { rm -f "$SUB_FILE"; sleep "$POLL_BASE"; continue; }

		HTTP_CODE="$(http_code "$SUB_URL")"
		if [ "$HTTP_CODE" = "200" ]; then
			[ -s "$VPN_READY_FILE" ] || echo 1 >"$VPN_READY_FILE"
			[ -s "$XRAY_CONF" ] || { download_xray_conf "$SUB_URL" && restart_xray || true; }
			# джиттер: ±(OK_JIT_MIN..OK_JIT_MAX)
			OFF="$(rand "$OK_JIT_MIN" "$OK_JIT_MAX")"
			SIGN="$(rand 0 1)"
			if [ "$SIGN" -eq 0 ]; then OFF=$(( -OFF )); fi
			SLEEP_TIME=$(( OK_INTERVAL + OFF ))
			[ "$SLEEP_TIME" -lt 60 ] && SLEEP_TIME=60
			sleep "$SLEEP_TIME"
		else
			log "subscription invalid (code=$HTTP_CODE) → reset"
			rm -f "$VPN_READY_FILE" "$SUB_FILE"
			stop_xray
			sleep "$FAIL_INTERVAL"
		fi
	done
}

ensure_prereqs
ensure_state_dir
log "shpun-agent started ($HTTP_TOOL)"
main_loop
