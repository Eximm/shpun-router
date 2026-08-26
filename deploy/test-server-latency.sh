#!/bin/sh

# Validate the public server latency API without changing the active server.
set -eu

BEFORE_SELECTED="$(ubus call shpun servers_get | jsonfilter -e '@.selected')"
START="$(cut -d' ' -f1 /proc/uptime)"
RESULT="$(ubus -t 10 call shpun servers_get)"
END="$(cut -d' ' -f1 /proc/uptime)"

SERVER_COUNT="$(printf '%s' "$RESULT" | jsonfilter -e '@.count')"
LATENCY_FIELDS="$(printf '%s' "$RESULT" | grep -o '"latency_ms"' | wc -l | tr -d ' ')"
AFTER_SELECTED="$(printf '%s' "$RESULT" | jsonfilter -e '@.selected')"
ELAPSED_MS="$(awk -v s="$START" -v e="$END" 'BEGIN { printf "%d", (e-s)*1000 }')"

[ "$SERVER_COUNT" -gt 0 ]
[ "$LATENCY_FIELDS" = "$SERVER_COUNT" ]
[ "$AFTER_SELECTED" = "$BEFORE_SELECTED" ]
[ "$ELAPSED_MS" -le 5000 ]

printf 'ok servers=%s latency_fields=%s elapsed_ms=%s selected=%s\n' \
	"$SERVER_COUNT" "$LATENCY_FIELDS" "$ELAPSED_MS" "$AFTER_SELECTED"
