#!/bin/sh

MODE="$1"
MODE_FILE="/etc/shpun/routes/mode"
LOGTAG="shpun-routing-mode"

case "$MODE" in
    full|split_ru)
        ;;
    *)
        echo "Usage: $0 [full|split_ru]" >&2
        logger -t "$LOGTAG" "invalid mode: $MODE"
        exit 1
        ;;
esac

mkdir -p /etc/shpun/routes 2>/dev/null || true
echo "$MODE" > "$MODE_FILE"

logger -t "$LOGTAG" "mode set to $MODE, restarting shpun-vpn"

/etc/init.d/shpun-vpn restart || {
    logger -t "$LOGTAG" "failed to restart shpun-vpn after mode=$MODE"
    exit 1
}

echo "ok"
exit 0