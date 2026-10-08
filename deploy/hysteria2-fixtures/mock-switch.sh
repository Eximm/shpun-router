#!/bin/sh
set -eu
printf '%s:%s:%s\n' "$1" "${SHPUN_AUTO_FAILOVER:-0}" "${SHPUN_AUTO_ONE_SHOT:-0}" >> "$MOCK_STATE/switches"
echo "$1" > "$MOCK_STATE/selected_link_index"
echo ready > "$MOCK_STATE/vpn_ready"
if [ "${SHPUN_AUTO_ONE_SHOT:-0}" = 1 ]; then echo 0 > "$MOCK_STATE/server_auto_select"; fi
if [ "$(cat "$MOCK_STATE/scenario")" = cancel ]; then echo 0 > "$MOCK_STATE/server_auto_select"; fi
echo ok
