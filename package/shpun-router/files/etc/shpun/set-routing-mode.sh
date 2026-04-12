#!/bin/sh

MODE="$1"
MODE_FILE="/etc/shpun/routes/mode"

case "$MODE" in
	full|split_ru)
		;;
	*)
		echo "Usage: $0 [full|split_ru]" >&2
		exit 1
		;;
esac

mkdir -p /etc/shpun/routes 2>/dev/null || true
echo "$MODE" > "$MODE_FILE"

if [ -x /etc/shpun/firewall-xray.sh ]; then
	/etc/shpun/firewall-xray.sh restart || exit 1
fi

echo "ok"