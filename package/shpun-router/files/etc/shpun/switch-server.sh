#!/bin/sh

NEW_INDEX="$1"
CONF="/etc/shpun/agent.conf"
SELECTED_LINK_FILE="/etc/shpun/selected_link_index"
BUILD_SCRIPT="/etc/shpun/build-config.sh"
LOGTAG="shpun-server"

ENGINE_BIN_DEFAULT="/tmp/xray"
ENGINE_CONFIG_DEFAULT="/etc/shpun/xray.json"
CONFIG_ACTIVE_FILE="/etc/shpun/xray_config_active"
CONFIG_PENDING_FILE="/etc/shpun/xray_config_pending"
VPN_READY_FILE="/etc/shpun/vpn_ready"
VERROR_FILE="/etc/shpun/vpn_error"
CONFIG_LOCKDIR="/tmp/shpun-config.lock"

log() {
	logger -t "$LOGTAG" "$*"
}

lock_config() {
	i=0
	while ! mkdir "$CONFIG_LOCKDIR" 2>/dev/null; do
		lock_pid="$(cat "$CONFIG_LOCKDIR/pid" 2>/dev/null || true)"
		case "$lock_pid" in
			''|*[!0-9]*)
				if [ "$i" -ge 2 ]; then
					rm -f "$CONFIG_LOCKDIR/pid" 2>/dev/null
					rmdir "$CONFIG_LOCKDIR" 2>/dev/null || true
					continue
				fi
				;;
			*)
				if ! kill -0 "$lock_pid" 2>/dev/null; then
					rm -f "$CONFIG_LOCKDIR/pid" 2>/dev/null
					rmdir "$CONFIG_LOCKDIR" 2>/dev/null || true
					continue
				fi
				;;
		esac
		i=$((i + 1))
		[ "$i" -gt 60 ] && {
			log "cannot switch server: config lock timeout"
			return 1
		}
		sleep 1
	done

	echo "$$" > "$CONFIG_LOCKDIR/pid"
	trap 'rm -f "$CONFIG_LOCKDIR/pid" 2>/dev/null; rmdir "$CONFIG_LOCKDIR" 2>/dev/null' EXIT INT TERM
	return 0
}

case "$NEW_INDEX" in
	''|*[!0-9]*)
		echo "invalid_index"
		exit 1
		;;
esac

[ -f "$CONF" ] && . "$CONF"
[ -z "$ENGINE_BIN" ] && ENGINE_BIN="$ENGINE_BIN_DEFAULT"
[ -z "$ENGINE_CONFIG" ] && ENGINE_CONFIG="$ENGINE_CONFIG_DEFAULT"

if [ ! -x "$BUILD_SCRIPT" ] || [ ! -x "$ENGINE_BIN" ]; then
	log "cannot switch server: builder or xray binary is missing"
	echo "build_not_ready"
	exit 1
fi

OLD_INDEX="$(cat "$SELECTED_LINK_FILE" 2>/dev/null | tr -d '\r\n ' || true)"
case "$OLD_INDEX" in
	''|*[!0-9]*) OLD_INDEX=0 ;;
esac

if ! lock_config; then
	echo "config_busy"
	exit 1
fi

SELECTED_CANDIDATE="${SELECTED_LINK_FILE}.candidate.$$"
CONFIG_CANDIDATE="${ENGINE_CONFIG}.candidate.$$"
CONFIG_BACKUP="${ENGINE_CONFIG}.server-backup.$$"
rm -f "$SELECTED_CANDIDATE" "$CONFIG_CANDIDATE" "$CONFIG_BACKUP"

printf '%s\n' "$NEW_INDEX" > "$SELECTED_CANDIDATE" || {
	rm -f "$SELECTED_CANDIDATE" "$CONFIG_CANDIDATE" "$CONFIG_BACKUP"
	echo "selection_write_failed"
	exit 1
}

if ! OUT_CFG="$CONFIG_CANDIDATE" SELECTED_LINK_FILE="$SELECTED_CANDIDATE" "$BUILD_SCRIPT"; then
	rm -f "$SELECTED_CANDIDATE" "$CONFIG_CANDIDATE" "$CONFIG_BACKUP"
	log "server index $NEW_INDEX rejected: candidate config build failed, keeping current tunnel"
	echo "config_build_failed"
	exit 1
fi

if ! "$ENGINE_BIN" run -test -config "$CONFIG_CANDIDATE" >/dev/null 2>&1; then
	rm -f "$SELECTED_CANDIDATE" "$CONFIG_CANDIDATE" "$CONFIG_BACKUP"
	log "server index $NEW_INDEX rejected: candidate xray validation failed, keeping current tunnel"
	echo "config_invalid"
	exit 1
fi

if [ -s "$ENGINE_CONFIG" ] && ! cp "$ENGINE_CONFIG" "$CONFIG_BACKUP" 2>/dev/null; then
	rm -f "$SELECTED_CANDIDATE" "$CONFIG_CANDIDATE" "$CONFIG_BACKUP"
	log "cannot switch server: failed to back up current xray config"
	echo "config_backup_failed"
	exit 1
fi

if ! mv "$CONFIG_CANDIDATE" "$ENGINE_CONFIG"; then
	[ -s "$CONFIG_BACKUP" ] && mv "$CONFIG_BACKUP" "$ENGINE_CONFIG" 2>/dev/null || true
	rm -f "$SELECTED_CANDIDATE" "$CONFIG_CANDIDATE" "$CONFIG_BACKUP"
	log "cannot switch server: failed to install candidate xray config"
	echo "config_install_failed"
	exit 1
fi

if ! mv "$SELECTED_CANDIDATE" "$SELECTED_LINK_FILE"; then
	[ -s "$CONFIG_BACKUP" ] && mv "$CONFIG_BACKUP" "$ENGINE_CONFIG" 2>/dev/null || true
	rm -f "$SELECTED_CANDIDATE" "$CONFIG_CANDIDATE" "$CONFIG_BACKUP"
	log "cannot switch server: failed to persist selected server index"
	echo "selection_write_failed"
	exit 1
fi

rm -f "$CONFIG_BACKUP" "$CONFIG_PENDING_FILE" "$CONFIG_ACTIVE_FILE" "$VERROR_FILE" "$VPN_READY_FILE"
log "server index $NEW_INDEX validated, restarting VPN once to apply it"
/etc/init.d/shpun-vpn stop >/dev/null 2>&1 || true
/etc/init.d/shpun-agent restart >/dev/null 2>&1 &

echo "ok"
exit 0
