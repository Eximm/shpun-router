#!/bin/sh
# Shpun agent v2.1 (OpenWrt-friendly)
# - JSON parsing via jsonfilter
# - proper HTTP handling for uclient-fetch/curl/wget
# - restart xray only when config actually changed
# - jitter via /dev/urandom
# - single-instance lock & clean stop

set -eu

STATE_DIR="/etc/shpun"
CODE_FILE="$STATE_DIR/router_code"
SUB_FILE="$STATE_DIR/subscription_url"
VPN_READY_FILE="$STATE_DIR/vpn_ready"

# XRAY
XRAY_CONF="/etc/xray/config.json"
XRAY_INIT="/etc/init.d/xray"

# Billing (public API)
API_URL="https://bill.shpyn.online/shm/v1/public/router_public"

# Intervals
POLL_BASE=30                 # start backoff
POLL_MAX=$((10*60))          # max backoff
POLL_JIT=15                  # ±15%

OK_INTERVAL=$((6*60*60))     # 6h when 200
OK_JIT_MIN=$((10*60))
OK_JIT_MAX=$((30*60))

FAIL_INTERVAL=60

LOCK="/var/run/shpun-agent.lock"
HTTP_TOOL=""

log() { logger -t shpun-agent "$*"; }

cleanup() {
  rm -f "$LOCK"
  log "stopped"
  exit 0
}
trap cleanup INT TERM

lock() {
  if [ -e "$LOCK" ]; then
    old="$(cat "$LOCK" 2>/dev/null || echo 0)"
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
      log "already running (pid=$old)"; exit 0
    fi
  fi
  echo $$ > "$LOCK"
}

# ---------- RNG ----------
rand_u16() { hexdump -n2 -e '1/2 "%u"' /dev/urandom 2>/dev/null || echo 12345; }
rand_range() { # min max
  min="$1"; max="$2"
  [ "$max" -lt "$min" ] && { t="$min"; min="$max"; max="$t"; }
  span=$((max - min + 1))
  n=$(rand_u16)
  echo $(( min + (n % span) ))
}

# ---------- HTTP ----------
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
  url="$1"
  case "$HTTP_TOOL" in
    curl)    curl -fsS --max-time 20 "$url" ;;
    uclient) uclient-fetch -qO- -T 20 "$url" ;;
    wget)    wget -qO- --timeout=20 "$url" ;;
    *)       return 1 ;;
  esac
}

http_download() {
  url="$1"; file="$2"
  case "$HTTP_TOOL" in
    curl)    curl -fsS --max-time 30 -o "$file" "$url" ;;
    uclient) uclient-fetch -qO "$file" -T 30 "$url" ;;
    wget)    wget -qO "$file" --timeout=30 "$url" ;;
    *)       return 1 ;;
  esac
}

http_code() {
  url="$1"
  case "$HTTP_TOOL" in
    curl)    curl -fsS -o /dev/null -w "%{http_code}" --max-time 20 "$url" 2>/dev/null || echo 000 ;;
    wget)    wget -S --spider --timeout=20 "$url" 2>&1 | awk '/HTTP\/[0-9.]+/ {c=$2} END{print c?c:0}' || echo 000 ;;
    uclient)
      # uclient-fetch не даёт HEAD/код → пробуем скачать в /dev/null и смотрим RC
      if uclient-fetch -qO /dev/null -T 20 "$url" >/dev/null 2>&1; then
        echo 200
      else
        # частый случай — 404 (ссылка ещё не готова)
        echo 404
      fi
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
  command -v jsonfilter >/dev/null 2>&1 || { log "jsonfilter missing"; exit 1; }
  # для HTTPS к биллингу
  if [ "$HTTP_TOOL" = "uclient" ] || [ "$HTTP_TOOL" = "wget" ] || [ "$HTTP_TOOL" = "curl" ]; then
    if ! opkg list-installed | grep -q 'ca-bundle'; then
      log "warning: ca-bundle not installed; HTTPS may fail"
    fi
  fi
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
  printf "%s" "$CODE"
}

fetch_json() { http_get "$1" 2>/dev/null || return 1; }

json_get() { # json path
  jsonfilter -s "$1" -e "$2" 2>/dev/null || true
}

download_xray_conf() {
  url="$1"
  tmp="$XRAY_CONF.tmp"
  http_download "$url" "$tmp" || { rm -f "$tmp"; return 1; }
  [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }

  # перезапускаем только если изменилось
  old_sum="$(sha256sum "$XRAY_CONF" 2>/dev/null | awk '{print $1}' || true)"
  new_sum="$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}' || true)"
  if [ "$old_sum" != "$new_sum" ]; then
    mv "$tmp" "$XRAY_CONF"
    return 2   # 2 => changed
  else
    rm -f "$tmp"
    return 0   # 0 => same
  fi
}

restart_xray() {
  [ -x "$XRAY_INIT" ] || { log "xray init not found"; return 0; }
  "$XRAY_INIT" enable >/dev/null 2>&1 || true
  "$XRAY_INIT" restart >/dev/null 2>&1 || true
  log "xray restarted"
}

stop_xray() { [ -x "$XRAY_INIT" ] && "$XRAY_INIT" stop >/dev/null 2>&1 || true; }

# ---------- main ----------
main_loop() {
  backoff=$POLL_BASE
  while :; do
    if [ ! -s "$SUB_FILE" ]; then
      CODE="$(get_or_create_code || true)"
      [ -z "$CODE" ] && { sleep "$POLL_BASE"; continue; }

      JSON="$(fetch_json "$API_URL?code=$CODE&format=json" || true)"
      [ -n "$JSON" ] || { sleep "$POLL_BASE"; continue; }

      OK="$(json_get "$JSON" '@.ok' | tr -d '\n' || echo 0)"
      if [ "$OK" = "1" ]; then
        SUB="$(json_get "$JSON" '@.subscription_url' | tr -d '\n' || true)"
        if [ -n "$SUB" ]; then
          printf "%s" "$SUB" >"$SUB_FILE"
          log "got subscription_url"

          if download_xray_conf "$SUB"; then
            : # same config
          else
            rc=$?
            [ "$rc" -eq 2 ] && restart_xray || true
          fi

          echo 1 >"$VPN_READY_FILE"
          backoff=$POLL_BASE
        fi
      fi

      if [ ! -s "$SUB_FILE" ]; then
        # backoff ±15%
        plus=$(( backoff + backoff * POLL_JIT / 100 ))
        sleep "$(rand_range "$backoff" "$plus")"
        backoff=$(( backoff + backoff/2 ))
        [ "$backoff" -gt "$POLL_MAX" ] && backoff="$POLL_MAX"
        continue
      fi
    fi

    SUB_URL="$(cat "$SUB_FILE" 2>/dev/null || true)"
    [ -z "$SUB_URL" ] && { rm -f "$SUB_FILE"; sleep "$POLL_BASE"; continue; }

    code="$(http_code "$SUB_URL")"
    if [ "$code" = "200" ]; then
      [ -s "$VPN_READY_FILE" ] || echo 1 >"$VPN_READY_FILE"

      if [ ! -s "$XRAY_CONF" ]; then
        if download_xray_conf "$SUB_URL"; then :; else rc=$?; [ "$rc" -eq 2 ] && restart_xray || true; fi
      fi

      off="$(rand_range "$OK_JIT_MIN" "$OK_JIT_MAX")"
      sign="$(rand_range 0 1)"; [ "$sign" -eq 0 ] && off=$(( -off ))
      sleep_t=$(( OK_INTERVAL + off ))
      [ "$sleep_t" -lt 60 ] && sleep_t=60
      sleep "$sleep_t"
    else
      log "subscription invalid (code=$code) → reset"
      rm -f "$VPN_READY_FILE" "$SUB_FILE"
      stop_xray
      sleep "$FAIL_INTERVAL"
    fi
  done
}

lock
ensure_prereqs
ensure_state_dir
log "shpun-agent started ($HTTP_TOOL)"
main_loop
