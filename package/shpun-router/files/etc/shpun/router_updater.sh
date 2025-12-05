#!/bin/sh
# /etc/shpun/router_updater
# Safe OTA updater for shpun-router

CONF_DIR="/etc/shpun"
SUB_FILE="$CONF_DIR/subscription.json"
LOCAL_VER_FILE="$CONF_DIR/router_version"
LOCAL_VER_PREV_FILE="$CONF_DIR/router_version.prev"
LOCK_FILE="/var/run/shpun-update.lock"
LOG_TAG="shpun-update"
PKG_NAME="shpun-router"

log() {
    logger -t "$LOG_TAG" "$*"
}

# --- version compare ---
ver_cmp() {
    local v1="${1:-0.0.0}"
    local v2="${2:-0.0.0}"

    local IFS=.
    set -- $v1 ; local a1=${1:-0} a2=${2:-0} a3=${3:-0}
    set -- $v2 ; local b1=${1:-0} b2=${2:-0} b3=${3:-0}

    a1=$((a1+0)); a2=$((a2+0)); a3=$((a3+0))
    b1=$((b1+0)); b2=$((b2+0)); b3=$((b3+0))

    [ $a1 -lt $b1 ] && { echo 0; return; }
    [ $a1 -gt $b1 ] && { echo 2; return; }

    [ $a2 -lt $b2 ] && { echo 0; return; }
    [ $a2 -gt $b2 ] && { echo 2; return; }

    [ $a3 -lt $b3 ] && { echo 0; return; }
    [ $a3 -gt $b3 ] && { echo 2; return; }

    echo 1
}

# --- lock ---
if [ -e "$LOCK_FILE" ]; then
    if kill -0 "$(cat "$LOCK_FILE" 2>/dev/null)" 2>/dev/null; then
        log "another update process is running"
        exit 1
    fi
fi
echo $$ >"$LOCK_FILE"
trap "rm -f $LOCK_FILE" EXIT

# --- deps ---
for bin in jsonfilter uclient-fetch opkg; do
    command -v "$bin" >/dev/null || { log "$bin missing"; exit 1; }
done

[ -f "$SUB_FILE" ] || { log "subscription.json missing"; exit 1; }

REMOTE_VER="$(jsonfilter -i "$SUB_FILE" -e '@.router_software.version' 2>/dev/null)"
UPDATE_URL="$(jsonfilter -i "$SUB_FILE" -e '@.router_software.update_url' 2>/dev/null)"
MIN_VER="$(jsonfilter -i "$SUB_FILE" -e '@.router_software.min_version' 2>/dev/null)"

LOCAL_VER=""
[ -f "$LOCAL_VER_FILE" ] && LOCAL_VER="$(tr -d '\r\n ' < "$LOCAL_VER_FILE")"

log "local=${LOCAL_VER:-none}, remote=${REMOTE_VER:-none}, min=${MIN_VER:-none}"

[ -z "$UPDATE_URL" ] && { log "empty update_url"; exit 1; }

# --- version check ---
if [ -n "$REMOTE_VER" ] && [ -n "$LOCAL_VER" ]; then
    cmp="$(ver_cmp "$LOCAL_VER" "$REMOTE_VER")"
    [ "$cmp" = "1" ] && { log "already up-to-date"; exit 0; }
    [ "$cmp" = "2" ] && { log "local version newer; skipping"; exit 0; }
fi

TMP_IPK="/tmp/${PKG_NAME}_update.ipk"

log "downloading: $UPDATE_URL"

if ! uclient-fetch -qO "$TMP_IPK" "$UPDATE_URL"; then
    log "download failed"
    rm -f "$TMP_IPK"
    exit 1
fi

# --- size check ---
if [ ! -s "$TMP_IPK" ]; then
    log "empty file"
    rm -f "$TMP_IPK"
    exit 1
fi

# --- validate ipk ---
if ! tar -tf "$TMP_IPK" >/dev/null 2>&1; then
    log "invalid ipk archive"
    rm -f "$TMP_IPK"
    exit 1
fi

# save old version
[ -n "$LOCAL_VER" ] && echo "$LOCAL_VER" >"$LOCAL_VER_PREV_FILE"

log "installing update"

if ! opkg install --force-reinstall "$TMP_IPK"; then
    log "opkg failed"
    rm -f "$TMP_IPK"
    exit 1
fi

rm -f "$TMP_IPK"

# write new version
[ -n "$REMOTE_VER" ] && echo "$REMOTE_VER" >"$LOCAL_VER_FILE"

log "restart services"

# avoid killing uhttpd too early; minimal restarts only
/etc/init.d/shpun-agent stop  2>/dev/null || true
/etc/init.d/shpun-vpn stop    2>/dev/null || true

/etc/init.d/shpun-agent start 2>/dev/null || true
/etc/init.d/shpun-vpn start   2>/dev/null || true

# rpcd reload is safe
/etc/init.d/rpcd restart 2>/dev/null || true

log "update finished OK"
exit 0
