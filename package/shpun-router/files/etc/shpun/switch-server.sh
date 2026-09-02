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
CONFIG_LOCKDIR="${CONFIG_LOCKDIR:-/tmp/shpun-config.lock}"
SELECTION_LOCKDIR="${AUTO_FAILOVER_LOCKDIR:-/tmp/shpun-auto-failover.lock}"
SELECTION_LOCK_HELD=0
CONFIG_LOCK_HELD=0

log() {
	logger -t "$LOGTAG" "$*"
}

cleanup_locks() {
	if [ "$CONFIG_LOCK_HELD" -eq 1 ]; then
		rm -f "$CONFIG_LOCKDIR/pid" 2>/dev/null
		rmdir "$CONFIG_LOCKDIR" 2>/dev/null || true
	fi
	if [ "$SELECTION_LOCK_HELD" -eq 1 ]; then
		rm -f "$SELECTION_LOCKDIR/pid" 2>/dev/null
		rmdir "$SELECTION_LOCKDIR" 2>/dev/null || true
	fi
}

lock_manual_selection() {
	[ "${SHPUN_AUTO_FAILOVER:-0}" = "1" ] && return 0

	if ! mkdir "$SELECTION_LOCKDIR" 2>/dev/null; then
		lock_pid="$(cat "$SELECTION_LOCKDIR/pid" 2>/dev/null || true)"
		case "$lock_pid" in
			''|*[!0-9]*) return 1 ;;
			*) kill -0 "$lock_pid" 2>/dev/null && return 1 ;;
		esac
		rm -f "$SELECTION_LOCKDIR/pid" 2>/dev/null
		rmdir "$SELECTION_LOCKDIR" 2>/dev/null || return 1
		mkdir "$SELECTION_LOCKDIR" 2>/dev/null || return 1
	fi
	echo "$$" > "$SELECTION_LOCKDIR/pid"
	SELECTION_LOCK_HELD=1
	return 0
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
	CONFIG_LOCK_HELD=1
	return 0
}

make_validation_config() {
	local src="$1"
	local dst="$2"

	awk '
		BEGIN {
			in_inbounds = 0
			depth = 0
			replaced = 0
		}
		{
			if (!in_inbounds && $0 ~ /^[[:space:]]*"inbounds"[[:space:]]*:/) {
				print "  \"inbounds\": [],"
				in_inbounds = 1
				replaced = 1
				for (i = 1; i <= length($0); i++) {
					ch = substr($0, i, 1)
					if (ch == "[") depth++
					else if (ch == "]") depth--
				}
				if (depth <= 0)
					in_inbounds = 0
				next
			}
			if (in_inbounds) {
				for (i = 1; i <= length($0); i++) {
					ch = substr($0, i, 1)
					if (ch == "[") depth++
					else if (ch == "]") depth--
				}
				if (depth <= 0)
					in_inbounds = 0
				next
			}
			print
		}
		END {
			if (!replaced)
				exit 1
		}
	' "$src" > "$dst"
}

case "$NEW_INDEX" in
	''|*[!0-9]*)
		echo "invalid_index"
		exit 1
		;;
esac

trap cleanup_locks EXIT
trap 'cleanup_locks; exit 1' INT TERM
if ! lock_manual_selection; then
	log "cannot switch server manually: automatic selection is running"
	echo "automatic_selection_busy"
	exit 1
fi

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
CONFIG_VALIDATE="${ENGINE_CONFIG}.validate.$$"
CONFIG_BACKUP="${ENGINE_CONFIG}.server-backup.$$"
rm -f "$SELECTED_CANDIDATE" "$CONFIG_CANDIDATE" "$CONFIG_VALIDATE" "$CONFIG_BACKUP"

printf '%s\n' "$NEW_INDEX" > "$SELECTED_CANDIDATE" || {
	rm -f "$SELECTED_CANDIDATE" "$CONFIG_CANDIDATE" "$CONFIG_VALIDATE" "$CONFIG_BACKUP"
	echo "selection_write_failed"
	exit 1
}

if ! OUT_CFG="$CONFIG_CANDIDATE" SELECTED_LINK_FILE="$SELECTED_CANDIDATE" "$BUILD_SCRIPT"; then
	rm -f "$SELECTED_CANDIDATE" "$CONFIG_CANDIDATE" "$CONFIG_VALIDATE" "$CONFIG_BACKUP"
	log "server index $NEW_INDEX rejected: candidate config build failed, keeping current tunnel"
	echo "config_build_failed"
	exit 1
fi

if [ "${SWITCH_SERVER_VALIDATE:-0}" = "1" ]; then
	if ! make_validation_config "$CONFIG_CANDIDATE" "$CONFIG_VALIDATE" ||
		! "$ENGINE_BIN" run -test -config "$CONFIG_VALIDATE" >/dev/null 2>&1; then
		rm -f "$SELECTED_CANDIDATE" "$CONFIG_CANDIDATE" "$CONFIG_VALIDATE" "$CONFIG_BACKUP"
		log "server index $NEW_INDEX rejected: candidate xray validation failed, keeping current tunnel"
		echo "config_invalid"
		exit 1
	fi
fi
rm -f "$CONFIG_VALIDATE"

if [ -s "$ENGINE_CONFIG" ] && ! cp "$ENGINE_CONFIG" "$CONFIG_BACKUP" 2>/dev/null; then
	rm -f "$SELECTED_CANDIDATE" "$CONFIG_CANDIDATE" "$CONFIG_VALIDATE" "$CONFIG_BACKUP"
	log "cannot switch server: failed to back up current xray config"
	echo "config_backup_failed"
	exit 1
fi

if ! mv "$CONFIG_CANDIDATE" "$ENGINE_CONFIG"; then
	[ -s "$CONFIG_BACKUP" ] && mv "$CONFIG_BACKUP" "$ENGINE_CONFIG" 2>/dev/null || true
	rm -f "$SELECTED_CANDIDATE" "$CONFIG_CANDIDATE" "$CONFIG_VALIDATE" "$CONFIG_BACKUP"
	log "cannot switch server: failed to install candidate xray config"
	echo "config_install_failed"
	exit 1
fi

if ! mv "$SELECTED_CANDIDATE" "$SELECTED_LINK_FILE"; then
	[ -s "$CONFIG_BACKUP" ] && mv "$CONFIG_BACKUP" "$ENGINE_CONFIG" 2>/dev/null || true
	rm -f "$SELECTED_CANDIDATE" "$CONFIG_CANDIDATE" "$CONFIG_VALIDATE" "$CONFIG_BACKUP"
	log "cannot switch server: failed to persist selected server index"
	echo "selection_write_failed"
	exit 1
fi

rm -f "$CONFIG_BACKUP" "$CONFIG_PENDING_FILE" "$CONFIG_ACTIVE_FILE" "$VERROR_FILE" "$VPN_READY_FILE"
if [ "${SHPUN_AUTO_FAILOVER:-0}" != "1" ]; then
	rm -f /etc/shpun/auto_failover_last_attempt /etc/shpun/auto_failover_last_success /etc/shpun/auto_failover_from
fi
log "server index $NEW_INDEX validated, restarting VPN once to apply it"
/etc/init.d/shpun-vpn stop >/dev/null 2>&1 || true
/etc/init.d/shpun-agent restart >/dev/null 2>&1 &

echo "ok"
exit 0
