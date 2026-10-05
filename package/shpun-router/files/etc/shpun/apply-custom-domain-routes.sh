#!/bin/sh

CONF="/etc/shpun/agent.conf"
BUILD_SCRIPT="/etc/shpun/build-config.sh"
FIREWALL_SCRIPT="/etc/shpun/firewall-xray.sh"
DNS_SCRIPT="/etc/shpun/dns-xray.sh"
ENGINE_BIN_DEFAULT="/tmp/xray"
ENGINE_CONFIG_DEFAULT="/etc/shpun/xray.json"
CONFIG_PENDING_FILE="/etc/shpun/xray_config_pending"
CONFIG_ACTIVE_FILE="/etc/shpun/xray_config_active"
VPN_READY_FILE="/etc/shpun/vpn_ready"
VERROR_FILE="/etc/shpun/vpn_error"
CONFIG_LOCKDIR="/tmp/shpun-config.lock"
LOGTAG="shpun-custom-routes"

log() {
    logger -t "$LOGTAG" "$*"
}

calc_sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    else
        openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'
    fi
}

is_vpn_process_running() {
    engine_base="$(basename "$ENGINE_BIN" 2>/dev/null || echo xray)"
    config_base="$(basename "$ENGINE_CONFIG" 2>/dev/null || echo xray.json)"
    pgrep -f "$ENGINE_BIN.*run.*-config.*$ENGINE_CONFIG" >/dev/null 2>&1 ||
        pgrep -f "$engine_base.*run.*-config.*$config_base" >/dev/null 2>&1
}

wait_vpn_started() {
    i=0
    while [ "$i" -lt 20 ]; do
        is_vpn_process_running && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

lock_config() {
    i=0
    while ! mkdir "$CONFIG_LOCKDIR" 2>/dev/null; do
        lock_pid="$(cat "$CONFIG_LOCKDIR/pid" 2>/dev/null || true)"
        case "$lock_pid" in
            ''|*[!0-9]*) ;;
            *) kill -0 "$lock_pid" 2>/dev/null || {
                rm -f "$CONFIG_LOCKDIR/pid" 2>/dev/null
                rmdir "$CONFIG_LOCKDIR" 2>/dev/null || true
                continue
            } ;;
        esac
        i=$((i + 1))
        [ "$i" -gt 60 ] && return 1
        sleep 1
    done
    echo "$$" > "$CONFIG_LOCKDIR/pid"
    trap 'rm -f "$CONFIG_LOCKDIR/pid" 2>/dev/null; rmdir "$CONFIG_LOCKDIR" 2>/dev/null' EXIT INT TERM
    return 0
}

restore_config() {
    if [ -s "$CONFIG_BACKUP" ]; then
        mv "$CONFIG_BACKUP" "$ENGINE_CONFIG"
    else
        rm -f "$ENGINE_CONFIG" "$CONFIG_BACKUP"
    fi
}

restore_and_restart() {
    restore_config
    SHPUN_PRESERVE_FIREWALL=1 SHPUN_MODE_PREPARED=1 /etc/init.d/shpun-vpn restart >/dev/null 2>&1 || true
}

[ -f "$CONF" ] && . "$CONF"
[ -z "$ENGINE_BIN" ] && ENGINE_BIN="$ENGINE_BIN_DEFAULT"
[ -z "$ENGINE_CONFIG" ] && ENGINE_CONFIG="$ENGINE_CONFIG_DEFAULT"

[ -x "$BUILD_SCRIPT" ] && [ -x "$ENGINE_BIN" ] || {
    echo "config_build_failed"
    exit 1
}

lock_config || {
    echo "config_busy"
    exit 1
}

CONFIG_BACKUP="${ENGINE_CONFIG}.custom-backup.$$"
rm -f "$CONFIG_BACKUP"
if [ -s "$ENGINE_CONFIG" ] && ! cp "$ENGINE_CONFIG" "$CONFIG_BACKUP"; then
    echo "config_backup_failed"
    exit 1
fi

if ! "$BUILD_SCRIPT" >/dev/null 2>&1; then
    restore_config
    echo "config_build_failed"
    exit 1
fi

if ! "$ENGINE_BIN" run -test -config "$ENGINE_CONFIG" >/dev/null 2>&1; then
    restore_config
    echo "config_invalid"
    exit 1
fi

new_sha="$(calc_sha256_file "$ENGINE_CONFIG" 2>/dev/null || true)"
[ -n "$new_sha" ] && printf '%s\n' "$new_sha" > "$CONFIG_PENDING_FILE"

log "applying validated domain routes with controlled xray restart"
if ! SHPUN_PRESERVE_FIREWALL=1 SHPUN_MODE_PREPARED=1 /etc/init.d/shpun-vpn restart >/dev/null 2>&1 || ! wait_vpn_started; then
    log "new domain route config failed, restoring previous xray config"
    restore_and_restart
    echo "vpn_start_failed"
    exit 1
fi

rm -f "$CONFIG_BACKUP" "$CONFIG_PENDING_FILE" "$VERROR_FILE"
[ -n "$new_sha" ] && printf '%s\n' "$new_sha" > "$CONFIG_ACTIVE_FILE"
printf 'ok\n' > "$VPN_READY_FILE"
[ -x "$DNS_SCRIPT" ] && "$DNS_SCRIPT" apply >/dev/null 2>&1 || true
log "domain routes activated successfully"
echo "ok"
exit 0
