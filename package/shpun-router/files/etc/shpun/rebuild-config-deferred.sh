#!/bin/sh

CONF="/etc/shpun/agent.conf"
BUILD_SCRIPT="/etc/shpun/build-config.sh"
LOGTAG="shpun-config"

ENGINE_BIN_DEFAULT="/tmp/xray"
ENGINE_CONFIG_DEFAULT="/etc/shpun/xray.json"
CONFIG_PENDING_FILE="/etc/shpun/xray_config_pending"
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
			log "cannot prepare deferred config: config lock timeout"
			return 1
		}
		sleep 1
	done

	echo "$$" > "$CONFIG_LOCKDIR/pid"
	trap 'rm -f "$CONFIG_LOCKDIR/pid" 2>/dev/null; rmdir "$CONFIG_LOCKDIR" 2>/dev/null' EXIT INT TERM
	return 0
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

restore_previous_config() {
	if [ -s "$CONFIG_BACKUP" ]; then
		mv "$CONFIG_BACKUP" "$ENGINE_CONFIG"
	else
		rm -f "$ENGINE_CONFIG" "$CONFIG_BACKUP"
	fi
}

[ -f "$CONF" ] && . "$CONF"
[ -z "$ENGINE_BIN" ] && ENGINE_BIN="$ENGINE_BIN_DEFAULT"
[ -z "$ENGINE_CONFIG" ] && ENGINE_CONFIG="$ENGINE_CONFIG_DEFAULT"

if [ ! -x "$BUILD_SCRIPT" ] || [ ! -x "$ENGINE_BIN" ]; then
	log "cannot prepare deferred config: builder or xray binary is missing"
	echo "config_build_failed" > "$VERROR_FILE"
	exit 1
fi

if ! lock_config; then
	echo "config_busy" > "$VERROR_FILE"
	exit 1
fi

CONFIG_BACKUP="${ENGINE_CONFIG}.deferred.$$"
rm -f "$CONFIG_BACKUP"
if [ -s "$ENGINE_CONFIG" ] && ! cp "$ENGINE_CONFIG" "$CONFIG_BACKUP" 2>/dev/null; then
	log "cannot prepare deferred config: failed to back up current xray config"
	echo "config_backup_failed" > "$VERROR_FILE"
	exit 1
fi

if ! "$BUILD_SCRIPT"; then
	restore_previous_config
	log "deferred xray config build failed, previous config restored"
	echo "build_config_failed" > "$VERROR_FILE"
	exit 1
fi

if ! "$ENGINE_BIN" run -test -config "$ENGINE_CONFIG" >/dev/null 2>&1; then
	restore_previous_config
	log "deferred xray config validation failed, previous config restored"
	echo "xray_config_invalid" > "$VERROR_FILE"
	exit 1
fi

new_sha="$(calc_sha256_file "$ENGINE_CONFIG" 2>/dev/null || true)"
[ -n "$new_sha" ] && echo "$new_sha" > "$CONFIG_PENDING_FILE" || date +%s > "$CONFIG_PENDING_FILE"
rm -f "$CONFIG_BACKUP" "$VERROR_FILE"
[ -s /etc/shpun/dns_proxy_ready ] && [ -x /etc/shpun/dns-xray.sh ] && \
	/etc/shpun/dns-xray.sh apply >/dev/null 2>&1 || true
log "valid xray config prepared; activation deferred to preserve active sessions"

exit 0
