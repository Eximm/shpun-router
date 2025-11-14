#!/bin/sh
# shpun-agent — получает subscription_url и управляет VPN-движком (sing-box / любой другой)

# shellcheck shell=sh

set -eu

STATE_DIR="/etc/shpun"
CODE_FILE="$STATE_DIR/router_code"
SUB_FILE="$STATE_DIR/subscription_url"
VPN_READY_FILE="$STATE_DIR/vpn_ready"
CONF="$STATE_DIR/agent.conf"

# Публичный API в биллинге
API_URL="https://bill.shpyn.online/shm/v1/public/router_public"

# интервалы опроса/проверки
POLL_BASE=30              # базовый интервал ожидания, пока нет SUB
POLL_MAX=$((10*60))       # максимум для бэкоффа
POLL_JIT=15               # джиттер в процентах

OK_INTERVAL=$((6*60*60))  # пере-проверка живости SUB
OK_JIT_MIN=$((10*60))
OK_JIT_MAX=$((30*60))

FAIL_INTERVAL=60          # задержка после невалидной подписки
LOCK="/var/run/shpun-agent.lock"

log() {
    logger -t shpun-agent "$*"
    [ -n "${AGENT_LOG:-}" ] && echo "$(date '+%F %T') $*" >>"$AGENT_LOG"
}

cleanup() { rm -f "$LOCK"; exit 0; }
trap cleanup INT TERM

lock() {
    if [ -e "$LOCK" ]; then
        old="$(cat "$LOCK" 2>/dev/null || echo 0)"
        kill -0 "$old" 2>/dev/null && exit 0
    fi
    echo $$ >"$LOCK"
}

need() {
    command -v "$1" >/dev/null 2>&1 || { log "missing $1"; exit 1; }
}

# таймауты подтягиваются из конфига
http_get() {
    t="${DOWNLOAD_READ_TIMEOUT:-20}"
    uclient-fetch -qO- -T "$t" "$1"
}

http_fetch() {
    t="${DOWNLOAD_READ_TIMEOUT:-30}"
    uclient-fetch -qO "$2" -T "$t" "$1"
}

http_ok() {
    t="${DOWNLOAD_CONNECT_TIMEOUT:-15}"
    uclient-fetch -qO /dev/null -T "$t" "$1" >/dev/null 2>&1
}

# --- генерация случайных чисел без od/hexdump/cksum ---
randu() {
    tr -dc '0-9' </dev/urandom 2>/dev/null | head -c 9
}

randr() {
    min="$1"
    max="$2"
    span=$((max - min + 1))
    n="$(randu)"
    [ -z "$n" ] && n=0
    echo $(( min + (n % span) ))
}

json_ok()  { echo "$1" | sed -n 's/.*"ok":[ ]*\([0-9]\+\).*/\1/p'; }
json_sub() { echo "$1" | sed -n 's/.*"subscription_url":"\([^"]*\)".*/\1/p'; }

# ---------- ENGINE-зависимая часть ----------

load_conf() {
    [ -f "$CONF" ] || { log "config $CONF not found"; exit 1; }
    # shellcheck disable=SC1090
    . "$CONF"

    : "${ENGINE_NAME:=engine}"
    : "${ENGINE_BIN:=/usr/bin/sing-box}"
    : "${ENGINE_CONFIG:=/etc/shpun/sing-box.json}"
    : "${ENGINE_URL:=}"
    : "${ENGINE_SHA256:=}"
    : "${DOWNLOAD_CONNECT_TIMEOUT:=10}"
    : "${DOWNLOAD_READ_TIMEOUT:=60}"
    : "${ENGINE_SERVICE_INIT:=}"
}

engine_download() {
    [ -n "$ENGINE_URL" ] || { log "ENGINE_URL not set"; return 1; }

    tmp="${ENGINE_BIN}.tmp.$$"
    log "downloading $ENGINE_NAME from $ENGINE_URL"
    http_fetch "$ENGINE_URL" "$tmp" || { log "download failed"; rm -f "$tmp"; return 1; }

    if [ -n "$ENGINE_SHA256" ] && [ "$ENGINE_SHA256" != "PUT_REAL_SHA256_HERE" ]; then
        echo "$ENGINE_SHA256  $tmp" | sha256sum -c - >/dev/null 2>&1 || {
            log "sha256 mismatch for $ENGINE_NAME"
            rm -f "$tmp"
            return 1
        }
    else
        log "WARNING: ENGINE_SHA256 not set or placeholder, skipping hash check"
    fi

    mkdir -p "$(dirname "$ENGINE_BIN")"
    mv "$tmp" "$ENGINE_BIN"
    chmod +x "$ENGINE_BIN"
    log "$ENGINE_NAME installed to $ENGINE_BIN"
    return 0
}

engine_check() {
    if [ ! -x "$ENGINE_BIN" ]; then
        log "engine binary missing: $ENGINE_BIN"
        engine_download || return 1
    fi

    if [ -n "$ENGINE_SHA256" ] && [ "$ENGINE_SHA256" != "PUT_REAL_SHA256_HERE" ]; then
        cur="$(sha256sum "$ENGINE_BIN" | awk '{print $1}')"
        if [ "$cur" != "$ENGINE_SHA256" ]; then
            log "engine sha256 mismatch (have $cur, want $ENGINE_SHA256), re-downloading"
            engine_download || return 1
        fi
    fi

    return 0
}

dl_conf() {
    url="$1"
    tmp="$ENGINE_CONFIG.tmp"

    http_fetch "$url" "$tmp" || { rm -f "$tmp"; return 1; }
    [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }

    mkdir -p "$(dirname "$ENGINE_CONFIG")"

    if [ -f "$ENGINE_CONFIG" ] && cmp -s "$tmp" "$ENGINE_CONFIG"; then
        rm -f "$tmp"
        return 0    # без изменений
    fi

    mv "$tmp" "$ENGINE_CONFIG"
    return 2        # конфиг обновился
}

svc_status() {
    if [ -n "$ENGINE_SERVICE_INIT" ] && [ -x "$ENGINE_SERVICE_INIT" ]; then
        "$ENGINE_SERVICE_INIT" status 2>/dev/null | grep -qi running && return 0
    fi
    return 1
}

svc_restart() {
    if [ -n "$ENGINE_SERVICE_INIT" ] && [ -x "$ENGINE_SERVICE_INIT" ]; then
        "$ENGINE_SERVICE_INIT" enable >/dev/null 2>&1 || true
        "$ENGINE_SERVICE_INIT" restart >/dev/null 2>&1 || true
        return 0
    fi
    log "ENGINE_SERVICE_INIT not set, cannot restart $ENGINE_NAME automatically"
    return 1
}

wait_running() {
    i=0
    while [ $i -lt 15 ]; do
        svc_status && return 0
        sleep 1
        i=$((i+1))
    done
    return 1
}

mark_ready() {
    if wait_running; then
        echo 1 >"$VPN_READY_FILE"
        log "vpn_ready=1"
    else
        rm -f "$VPN_READY_FILE"
        log "vpn still not running"
    fi
}

# ---------- общая логика агента ----------

ensure() {
    need uclient-fetch
    need sed
    need awk
    need sha256sum

    mkdir -p "$STATE_DIR"

    load_conf
    engine_check || log "engine check failed (will still handle subscription)"
}

# Код генерирует wizard/gen_code.sh, агент только читает готовый файл.
get_code() {
    if [ ! -s "$CODE_FILE" ]; then
        log "router_code not set, waiting for setup..."
        return 1
    fi
    cat "$CODE_FILE"
}

main_loop() {
    backoff=$POLL_BASE

    while :; do
        # 1) если нет subscription_url — пытаемся его получить по коду
        if [ ! -s "$SUB_FILE" ]; then
            CODE="$(get_code || true)"
            [ -z "$CODE" ] && { sleep "$POLL_BASE"; continue; }

            JSON="$(http_get "$API_URL?code=$CODE&format=json" || true)"
            [ "$(json_ok "$JSON")" = "1" ] && SUB="$(json_sub "$JSON" || true)" || SUB=""

            if [ -n "$SUB" ]; then
                echo "$SUB" >"$SUB_FILE"
                log "got subscription_url"

                changed=0
                if dl_conf "$SUB"; then
                    :
                else
                    rc=$?
                    [ "$rc" -eq 2 ] && changed=1
                fi

                if [ "$changed" -eq 1 ]; then
                    engine_check || true
                    svc_restart || true
                    mark_ready
                else
                    mark_ready
                fi
                backoff=$POLL_BASE
            fi

            if [ ! -s "$SUB_FILE" ]; then
                max=$((backoff + backoff * POLL_JIT / 100))
                sleep "$(randr "$backoff" "$max")"
                backoff=$(( backoff + backoff/2 ))
                [ "$backoff" -gt "$POLL_MAX" ] && backoff="$POLL_MAX"
                continue
            fi
        fi

        # 2) subscription_url есть — проверяем, что он жив
        SUB_URL="$(cat "$SUB_FILE" 2>/dev/null || true)"
        [ -z "$SUB_URL" ] && { rm -f "$SUB_FILE"; sleep "$POLL_BASE"; continue; }

        if http_ok "$SUB_URL"; then
            # если конфиг ещё не скачан — пробуем скачать
            if [ ! -s "$ENGINE_CONFIG" ]; then
                changed=0
                if dl_conf "$SUB_URL"; then
                    :
                else
                    rc=$?
                    [ "$rc" -eq 2 ] && changed=1
                fi

                [ "$changed" -eq 1 ] && { engine_check || true; svc_restart || true; }
            fi

            mark_ready

            off="$(randr "$OK_JIT_MIN" "$OK_JIT_MAX")"
            [ "$(randr 0 1)" -eq 0 ] && off=$((-off))
            t=$(( OK_INTERVAL + off ))
            [ "$t" -lt 60 ] && t=60
            sleep "$t"
        else
            log "subscription invalid -> reset"
            rm -f "$VPN_READY_FILE" "$SUB_FILE"
            if [ -n "$ENGINE_SERVICE_INIT" ] && [ -x "$ENGINE_SERVICE_INIT" ]; then
                "$ENGINE_SERVICE_INIT" stop >/dev/null 2>&1 || true
            fi
            sleep "$FAIL_INTERVAL"
        fi
    done
}

# ---------- entrypoint ----------

lock
ensure
log "shpun-agent started (ENGINE_NAME=${ENGINE_NAME:-unknown})"
main_loop
