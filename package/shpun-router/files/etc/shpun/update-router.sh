#!/bin/sh

# /etc/shpun/update-router.sh
#
# Обновление пакета shpun-router из URL, переданного в /etc/shpun/subscription.json
#   router_software.version     – версия на сервере
#   router_software.min_version – минимально допустимая версия (опционально)
#   router_software.update_url  – полный URL до .ipk
#
# Скрипт:
#   - читает локальную версию /etc/shpun/router_version
#   - сверяет её с удалённой
#   - при необходимости качает .ipk в /tmp и ставит через opkg
#   - логирует шаги в системный лог (tag: shpun-update)
#   - перезапускает shpun-agent / shpun-vpn / rpcd / uhttpd

CONF_DIR="/etc/shpun"
SUB_FILE="$CONF_DIR/subscription.json"
LOCAL_VER_FILE="$CONF_DIR/router_version"
LOCAL_VER_PREV_FILE="$CONF_DIR/router_version.prev"

LOG_TAG="shpun-update"
PKG_NAME="shpun-router"
LOCK_FILE="/var/run/shpun-update.lock"

log() {
    logger -t "$LOG_TAG" "$*"
}

# сравнение версий формата X.Y.Z -> возвращает 0 если v1 < v2, 1 если v1 == v2, 2 если v1 > v2
ver_cmp() {
    local v1="$1"
    local v2="$2"

    [ -z "$v1" ] && v1="0.0.0"
    [ -z "$v2" ] && v2="0.0.0"

    local IFS=.
    set -- $v1
    local a1=${1:-0} a2=${2:-0} a3=${3:-0}
    set -- $v2
    local b1=${1:-0} b2=${2:-0} b3=${3:-0}

    # нормализуем до чисел
    a1=$((a1+0)); a2=$((a2+0)); a3=$((a3+0))
    b1=$((b1+0)); b2=$((b2+0)); b3=$((b3+0))

    if [ "$a1" -lt "$b1" ]; then
        echo 0; return 0
    elif [ "$a1" -gt "$b1" ]; then
        echo 2; return 0
    fi

    if [ "$a2" -lt "$b2" ]; then
        echo 0; return 0
    elif [ "$a2" -gt "$b2" ]; then
        echo 2; return 0
    fi

    if [ "$a3" -lt "$b3" ]; then
        echo 0; return 0
    elif [ "$a3" -gt "$b3" ]; then
        echo 2; return 0
    fi

    echo 1
    return 0
}

# простой лок, чтобы не запускать два обновления одновременно
if [ -e "$LOCK_FILE" ]; then
    if kill -0 "$(cat "$LOCK_FILE" 2>/dev/null)" 2>/dev/null; then
        log "another update process is running, exiting"
        exit 1
    fi
fi

echo $$ >"$LOCK_FILE" 2>/dev/null || true

cleanup() {
    rm -f "$LOCK_FILE"
}
trap cleanup EXIT

command -v jsonfilter >/dev/null 2>&1 || {
    log "jsonfilter not found"
    exit 1
}

command -v uclient-fetch >/dev/null 2>&1 || {
    log "uclient-fetch not found"
    exit 1
}

command -v opkg >/dev/null 2>&1 || {
    log "opkg not found"
    exit 1
}

[ -f "$SUB_FILE" ] || {
    log "subscription.json not found: $SUB_FILE"
    exit 1
}

REMOTE_VER="$(jsonfilter -i "$SUB_FILE" -e '@.router_software.version' 2>/dev/null)"
MIN_VER="$(jsonfilter -i "$SUB_FILE" -e '@.router_software.min_version' 2>/dev/null)"
UPDATE_URL="$(jsonfilter -i "$SUB_FILE" -e '@.router_software.update_url' 2>/dev/null)"

LOCAL_VER=""
[ -f "$LOCAL_VER_FILE" ] && LOCAL_VER="$(cat "$LOCAL_VER_FILE" 2>/dev/null | tr -d '\r\n ')" || true

log "local_version='${LOCAL_VER:-unknown}', remote_version='${REMOTE_VER:-unknown}', min_version='${MIN_VER:-none}'"

if [ -z "$UPDATE_URL" ]; then
    log "router_software.update_url is empty, nothing to update"
    exit 1
fi

if [ -z "$REMOTE_VER" ]; then
    log "router_software.version not provided, proceeding without version check"
else
    # если локальной нет — считаем, что нужно обновиться
    if [ -n "$LOCAL_VER" ]; then
        CMP="$(ver_cmp "$LOCAL_VER" "$REMOTE_VER")"
        # 0: local < remote, 1: equal, 2: local > remote
        if [ "$CMP" = "1" ]; then
            log "local version is already up to date"
            exit 0
        elif [ "$CMP" = "2" ]; then
            log "local version (${LOCAL_VER}) is newer than remote (${REMOTE_VER}), skipping update"
            exit 0
        fi
    else
        log "no local version, will install remote=${REMOTE_VER}"
    fi
fi

TMP_IPK="/tmp/${PKG_NAME}_update.ipk"

log "downloading update from $UPDATE_URL to $TMP_IPK"

if ! uclient-fetch -qO "$TMP_IPK" "$UPDATE_URL"; then
    log "failed to download update ipk"
    rm -f "$TMP_IPK"
    exit 1
fi

# проверим, что файл не пустой
if [ ! -s "$TMP_IPK" ]; then
    log "downloaded ipk is empty"
    rm -f "$TMP_IPK"
    exit 1
fi

# сохраняем прошлую версию
if [ -n "$LOCAL_VER" ]; then
    echo "$LOCAL_VER" >"$LOCAL_VER_PREV_FILE" 2>/dev/null || true
fi

log "installing $TMP_IPK via opkg"

if ! opkg install "$TMP_IPK"; then
    log "opkg install failed, keeping previous version"
    rm -f "$TMP_IPK"
    exit 1
fi

rm -f "$TMP_IPK"

# если удалённая версия задана — обновляем router_version
if [ -n "$REMOTE_VER" ]; then
    echo "$REMOTE_VER" >"$LOCAL_VER_FILE" 2>/dev/null || true
fi

log "update installed successfully, restarting services"

# Не падаем, если каких-то init-скриптов нет
/etc/init.d/shpun-agent stop  2>/dev/null || true
/etc/init.d/shpun-vpn stop    2>/dev/null || true

/etc/init.d/shpun-agent start 2>/dev/null || true
/etc/init.d/shpun-vpn start   2>/dev/null || true

/etc/init.d/rpcd restart      2>/dev/null || true
/etc/init.d/uhttpd reload     2>/dev/null || /etc/init.d/uhttpd restart 2>/dev/null || true

log "update procedure finished"

exit 0
