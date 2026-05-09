#!/bin/sh

MODE="$1"
MODE_FILE="/etc/shpun/routes/mode"
LOGTAG="shpun-routing-mode"
CONF="/etc/shpun/agent.conf"

ROUTES_DIR="/etc/shpun/routes"
ROUTES_CIDRS_FILE="$ROUTES_DIR/ru.cidrs"
ROUTES_VER_FILE="$ROUTES_DIR/ru.version"
ROUTES_SHA_FILE="$ROUTES_DIR/ru.sha256"
ROUTER_PROFILE_FILE="$ROUTES_DIR/router_profile"
SMART_RU_DOMAINS_FILE="$ROUTES_DIR/presets/smart_ru.domains"
SMART_RU_DOMAINS_VER_FILE="$ROUTES_DIR/presets/smart_ru.domains.version"
SMART_RU_DOMAINS_SHA_FILE="$ROUTES_DIR/presets/smart_ru.domains.sha256"
ROUTES_URL_BASE_DEFAULT="https://spb.shpyn.online/files/routes"
SPLIT_RU_MIN_MEM_KB_DEFAULT=131072
SPLIT_RU_WARN_MEM_KB_DEFAULT=196608

HTTP_BIN=""

log() {
    logger -t "$LOGTAG" "$*"
}

load_conf() {
    [ -f "$CONF" ] && . "$CONF"
    [ -z "$ROUTES_URL_BASE" ] && ROUTES_URL_BASE="$ROUTES_URL_BASE_DEFAULT"
    [ -z "$SPLIT_RU_MIN_MEM_KB" ] && SPLIT_RU_MIN_MEM_KB="$SPLIT_RU_MIN_MEM_KB_DEFAULT"
    [ -z "$SPLIT_RU_WARN_MEM_KB" ] && SPLIT_RU_WARN_MEM_KB="$SPLIT_RU_WARN_MEM_KB_DEFAULT"

    case "$SPLIT_RU_MIN_MEM_KB" in
        ''|*[!0-9]*) SPLIT_RU_MIN_MEM_KB="$SPLIT_RU_MIN_MEM_KB_DEFAULT" ;;
    esac
    case "$SPLIT_RU_WARN_MEM_KB" in
        ''|*[!0-9]*) SPLIT_RU_WARN_MEM_KB="$SPLIT_RU_WARN_MEM_KB_DEFAULT" ;;
    esac
}

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
    url="$1"
    out="$2"

    case "$HTTP_BIN" in
        curl) curl -fsS "$url" -o "$out" ;;
        wget) wget -qO "$out" "$url" ;;
        uclient-fetch) uclient-fetch -qO "$out" "$url" ;;
        *) return 1 ;;
    esac
}

http_get_stdout() {
    url="$1"

    case "$HTTP_BIN" in
        curl) curl -fsS "$url" ;;
        wget) wget -qO- "$url" ;;
        uclient-fetch) uclient-fetch -qO- "$url" ;;
        *) return 1 ;;
    esac
}

calc_sha256_file() {
    file="$1"

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

fetch_routes_once() {
    remote_ver="$(http_get_stdout "$ROUTES_URL_BASE/ru.version" 2>/dev/null | tr -d '\r\n ' || true)"
    local_ver="$(cat "$ROUTES_VER_FILE" 2>/dev/null | tr -d '\r\n ' || echo "0")"

    if [ -z "$remote_ver" ]; then
        log "routes preflight: empty remote version"
        return 1
    fi

    if [ "$remote_ver" = "$local_ver" ] && [ -s "$ROUTES_CIDRS_FILE" ]; then
        log "routes preflight: already up-to-date (v=$local_ver)"
        return 0
    fi

    tmp_cidrs="${ROUTES_CIDRS_FILE}.tmp"
    tmp_sha="${ROUTES_SHA_FILE}.tmp"

    rm -f "$tmp_cidrs" "$tmp_sha"

    log "routes preflight: downloading local=$local_ver remote=$remote_ver"

    if ! http_get_to_file "$ROUTES_URL_BASE/ru.cidrs" "$tmp_cidrs" 2>/dev/null; then
        log "routes preflight: failed to download ru.cidrs"
        rm -f "$tmp_cidrs" "$tmp_sha"
        return 1
    fi

    if [ ! -s "$tmp_cidrs" ]; then
        log "routes preflight: downloaded ru.cidrs is empty"
        rm -f "$tmp_cidrs" "$tmp_sha"
        return 1
    fi

    if ! http_get_to_file "$ROUTES_URL_BASE/ru.sha256" "$tmp_sha" 2>/dev/null; then
        log "routes preflight: failed to download ru.sha256"
        rm -f "$tmp_cidrs" "$tmp_sha"
        return 1
    fi

    remote_sha="$(tr -d '\r\n ' < "$tmp_sha" 2>/dev/null)"
    local_sha="$(calc_sha256_file "$tmp_cidrs" 2>/dev/null || true)"

    if [ -z "$remote_sha" ] || [ -z "$local_sha" ] || [ "$local_sha" != "$remote_sha" ]; then
        log "routes preflight: sha256 mismatch local=$local_sha remote=$remote_sha"
        rm -f "$tmp_cidrs" "$tmp_sha"
        return 1
    fi

    mv "$tmp_cidrs" "$ROUTES_CIDRS_FILE"
    echo "$remote_sha" > "$ROUTES_SHA_FILE"
    echo "$remote_ver" > "$ROUTES_VER_FILE"
    date +%s > "$ROUTES_DIR/last_check"
    rm -f "$tmp_sha"

    log "routes preflight: ready version $remote_ver"
    return 0
}

fetch_smart_ru_once() {
    remote_ver="$(http_get_stdout "$ROUTES_URL_BASE/presets/smart_ru.domains.version" 2>/dev/null | tr -d '\r\n ' || true)"
    local_ver="$(cat "$SMART_RU_DOMAINS_VER_FILE" 2>/dev/null | tr -d '\r\n ' || echo "0")"

    if [ -z "$remote_ver" ]; then
        log "smart_ru preflight: empty remote version"
        return 1
    fi

    if [ "$remote_ver" = "$local_ver" ] && [ -s "$SMART_RU_DOMAINS_FILE" ]; then
        log "smart_ru preflight: already up-to-date (v=$local_ver)"
        return 0
    fi

    tmp_domains="${SMART_RU_DOMAINS_FILE}.tmp"
    tmp_sha="${SMART_RU_DOMAINS_SHA_FILE}.tmp"

    rm -f "$tmp_domains" "$tmp_sha"

    log "smart_ru preflight: downloading local=$local_ver remote=$remote_ver"

    if ! http_get_to_file "$ROUTES_URL_BASE/presets/smart_ru.domains" "$tmp_domains" 2>/dev/null; then
        log "smart_ru preflight: failed to download domains"
        rm -f "$tmp_domains" "$tmp_sha"
        return 1
    fi

    if [ ! -s "$tmp_domains" ]; then
        log "smart_ru preflight: downloaded domains file is empty"
        rm -f "$tmp_domains" "$tmp_sha"
        return 1
    fi

    if ! http_get_to_file "$ROUTES_URL_BASE/presets/smart_ru.domains.sha256" "$tmp_sha" 2>/dev/null; then
        log "smart_ru preflight: failed to download sha256"
        rm -f "$tmp_domains" "$tmp_sha"
        return 1
    fi

    remote_sha="$(tr -d '\r\n ' < "$tmp_sha" 2>/dev/null)"
    local_sha="$(calc_sha256_file "$tmp_domains" 2>/dev/null || true)"

    if [ -z "$remote_sha" ] || [ -z "$local_sha" ] || [ "$local_sha" != "$remote_sha" ]; then
        log "smart_ru preflight: sha256 mismatch local=$local_sha remote=$remote_sha"
        rm -f "$tmp_domains" "$tmp_sha"
        return 1
    fi

    mkdir -p "$ROUTES_DIR/presets" 2>/dev/null || true
    mv "$tmp_domains" "$SMART_RU_DOMAINS_FILE"
    echo "$remote_sha" > "$SMART_RU_DOMAINS_SHA_FILE"
    echo "$remote_ver" > "$SMART_RU_DOMAINS_VER_FILE"
    rm -f "$tmp_sha"

    log "smart_ru preflight: ready version $remote_ver"
    return 0
}

get_current_mode() {
    old="full"
    [ -f "$MODE_FILE" ] && old="$(tr -d '\r\n ' < "$MODE_FILE")"
    case "$old" in
        full|smart_ru|split_ru) echo "$old" ;;
        *) echo "full" ;;
    esac
}

get_mem_kb() {
    awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0
}

get_cpu_count() {
    cnt="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 0)"
    case "$cnt" in
        ''|*[!0-9]*) cnt=0 ;;
    esac
    [ "$cnt" -gt 0 ] || cnt=1
    echo "$cnt"
}

write_router_profile() {
    mem_kb="$1"
    cpu_count="$2"
    class="$3"
    reason="$4"

    {
        printf 'class=%s\n' "$class"
        printf 'mem_kb=%s\n' "$mem_kb"
        printf 'cpu_count=%s\n' "$cpu_count"
        printf 'reason=%s\n' "$reason"
        date +%s 2>/dev/null | awk '{print "checked_at="$1}'
    } > "$ROUTER_PROFILE_FILE" 2>/dev/null || true
}

router_allows_split_ru() {
    mem_kb="$(get_mem_kb)"
    cpu_count="$(get_cpu_count)"
    class="ok"
    reason="ok"

    case "$mem_kb" in
        ''|*[!0-9]*) mem_kb=0 ;;
    esac

    if [ "$mem_kb" -gt 0 ] && [ "$mem_kb" -lt "$SPLIT_RU_MIN_MEM_KB" ]; then
        class="weak"
        reason="low_memory"
    elif [ "$mem_kb" -gt 0 ] && [ "$mem_kb" -lt "$SPLIT_RU_WARN_MEM_KB" ] && [ "$cpu_count" -lt 2 ]; then
        class="weak"
        reason="low_memory_single_core"
    fi

    write_router_profile "$mem_kb" "$cpu_count" "$class" "$reason"

    if [ "$class" = "weak" ] && [ "$SPLIT_RU_ALLOW_WEAK" != "1" ]; then
        log "split_ru blocked: weak router detected mem=${mem_kb}KB cpu=${cpu_count} reason=$reason"
        return 1
    fi

    if [ "$class" = "weak" ]; then
        log "split_ru allowed by override on weak router mem=${mem_kb}KB cpu=${cpu_count} reason=$reason"
    else
        log "split_ru preflight: router OK mem=${mem_kb}KB cpu=${cpu_count}"
    fi

    return 0
}

case "$MODE" in
    full|smart_ru|split_ru)
        ;;
    *)
        echo "Usage: $0 [full|split_ru]" >&2
        log "invalid mode: $MODE"
        exit 1
        ;;
esac

load_conf
mkdir -p "$ROUTES_DIR" 2>/dev/null || true
mkdir -p "$ROUTES_DIR/presets" 2>/dev/null || true

OLD_MODE="$(get_current_mode)"

if [ "$MODE" = "smart_ru" ] && [ ! -s "$SMART_RU_DOMAINS_FILE" ]; then
    detect_http_client
    if [ -z "$HTTP_BIN" ]; then
        log "smart_ru preflight: no HTTP client, keeping mode=$OLD_MODE"
        echo "smart_ru_not_ready"
        exit 1
    fi

    if ! fetch_smart_ru_once; then
        log "smart_ru preflight failed, keeping mode=$OLD_MODE"
        echo "smart_ru_not_ready"
        exit 1
    fi
elif [ "$MODE" = "smart_ru" ]; then
    detect_http_client
    [ -n "$HTTP_BIN" ] && fetch_smart_ru_once >/dev/null 2>&1 || true
fi

if [ "$MODE" = "split_ru" ] && [ ! -s "$ROUTES_CIDRS_FILE" ]; then
    if ! router_allows_split_ru; then
        echo "weak_router"
        exit 1
    fi

    detect_http_client
    if [ -z "$HTTP_BIN" ]; then
        log "routes preflight: no HTTP client, keeping mode=$OLD_MODE"
        echo "routes_not_ready"
        exit 1
    fi

    if ! fetch_routes_once; then
        log "routes preflight failed, keeping mode=$OLD_MODE"
        echo "routes_not_ready"
        exit 1
    fi
elif [ "$MODE" = "split_ru" ]; then
    if ! router_allows_split_ru; then
        echo "weak_router"
        exit 1
    fi
fi

printf '%s\n' "$MODE" > "${MODE_FILE}.tmp" || exit 1
mv "${MODE_FILE}.tmp" "$MODE_FILE" || exit 1

log "mode set to $MODE, restarting shpun-vpn"

/etc/init.d/shpun-vpn restart || {
    log "failed to restart shpun-vpn after mode=$MODE, rolling back to $OLD_MODE"
    printf '%s\n' "$OLD_MODE" > "$MODE_FILE"
    /etc/init.d/shpun-vpn restart >/dev/null 2>&1 || true
    exit 1
}

echo "ok"
exit 0
