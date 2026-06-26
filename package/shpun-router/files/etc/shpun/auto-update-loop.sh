#!/bin/sh

UPDATER="/etc/shpun/router_updater"
CHECK_INTERVAL="${SHPUN_AUTO_UPDATE_INTERVAL:-21600}"
START_DELAY="${SHPUN_AUTO_UPDATE_START_DELAY:-600}"
MAX_JITTER="${SHPUN_AUTO_UPDATE_JITTER:-1800}"

number_or_default() {
	case "$1" in
		''|*[!0-9]*) printf '%s' "$2" ;;
		*) printf '%s' "$1" ;;
	esac
}

CHECK_INTERVAL="$(number_or_default "$CHECK_INTERVAL" 21600)"
START_DELAY="$(number_or_default "$START_DELAY" 600)"
MAX_JITTER="$(number_or_default "$MAX_JITTER" 1800)"

seed="$(cat /etc/shpun/router_code 2>/dev/null || cat /sys/class/net/br-lan/address 2>/dev/null || echo shpun)"
if [ "$MAX_JITTER" -gt 0 ] && command -v cksum >/dev/null 2>&1; then
	jitter="$(printf '%s' "$seed" | cksum | awk -v max="$MAX_JITTER" '{ print $1 % max }')"
else
	jitter=0
fi

sleep "$((START_DELAY + jitter))"

while :; do
	if [ -x "$UPDATER" ]; then
		AUTO_ONLY=1 "$UPDATER" >/dev/null 2>&1
	fi
	sleep "$CHECK_INTERVAL"
done
