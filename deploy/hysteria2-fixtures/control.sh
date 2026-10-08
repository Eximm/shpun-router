#!/bin/sh
set -eu
d="$1"
mkdir -p "$d/control" "$d/mock"
export MOCK_STATE="$d/control"
cp "$d/mock-curl.sh" "$d/mock/curl"
printf '#!/bin/sh\nexit 0\n' > "$d/mock/logger"
chmod +x "$d/mock/curl" "$d/mock/logger" "$d/mock-switch.sh"
export PATH="$d/mock:$PATH"
export STATE_DIR="$MOCK_STATE" CONF="$MOCK_STATE/agent.conf"
export SUB_FILE="$MOCK_STATE/subscription.json" SELECTED_LINK_FILE="$MOCK_STATE/selected_link_index"
export SWITCH_SCRIPT="$d/mock-switch.sh" VPN_READY_FILE="$MOCK_STATE/vpn_ready"
export AUTO_FAILOVER_LOCKDIR="$MOCK_STATE/lock"
export AUTO_FAILOVER_IGNORE_COOLDOWN=1
unset AUTO_FAILOVER_CANDIDATES
reset() {
 rm -f "$MOCK_STATE/switches" "$MOCK_STATE/auto_failover_last_success" "$MOCK_STATE/auto_select_status" "$MOCK_STATE/vpn_error"
 echo 0 > "$SELECTED_LINK_FILE"
 echo 1 > "$MOCK_STATE/server_auto_select"
 echo 0 > "$MOCK_STATE/server_auto_exclude_ru"
 echo ready > "$VPN_READY_FILE"
 printf '%s\n' 'AUTO_FAILOVER_READY_TIMEOUT=2' 'TUNNEL_QUALITY_PROBE_URL="https://probe.invalid/speed"' 'TUNNEL_QUALITY_CONFIRM_URLS="https://probe.invalid/one https://probe.invalid/two https://probe.invalid/three"' > "$CONF"
 printf '%s\n' '{"subscription":{"links":["hy2://test@foreign.invalid:443","vless://test@foreign.invalid:443"]}}' > "$SUB_FILE"
}
for v in ${TEST_VARIANTS:-24 25}; do
 reset; echo fallback > "$MOCK_STATE/scenario"
 sh "$d/auto-$v.sh"
 [ "$(cat "$SELECTED_LINK_FILE")" = 1 ]
 grep -qx '1:1:0' "$MOCK_STATE/switches"
 echo "PASS version=$v Hysteria-failure-to-Reality-control"
 reset; echo preferred > "$MOCK_STATE/scenario"
 printf '%s\n' '{"subscription":{"links":["hy2://test@foreign.invalid:443","vless://test@reserve.invalid:443",{"hy2":"hy2://test@other.invalid:443"}]}}' > "$SUB_FILE"
 sh "$d/auto-$v.sh"
 [ "$(cat "$SELECTED_LINK_FILE")" = 2 ]
 grep -qx '2:1:0' "$MOCK_STATE/switches"
 echo "PASS version=$v Hysteria-first-Reality-reserve-object-links"
 reset; echo fallback > "$MOCK_STATE/scenario"; echo 0 > "$MOCK_STATE/server_auto_select"
 sh "$d/auto-$v.sh"
 [ ! -f "$MOCK_STATE/switches" ] && [ "$(cat "$SELECTED_LINK_FILE")" = 0 ]
 echo "PASS version=$v Auto-OFF-no-switch"
 reset; echo all_fail > "$MOCK_STATE/scenario"
 if sh "$d/auto-$v.sh"; then echo FAIL-all-failed; exit 1; fi
 [ "$(cat "$SELECTED_LINK_FILE")" = 0 ]
 [ ! -f "$MOCK_STATE/auto_failover_last_success" ]
 grep -qx '0:1:0' "$MOCK_STATE/switches"
 echo "PASS version=$v all-failed-restores-original"
 reset; echo fallback > "$MOCK_STATE/scenario"; echo 1 > "$MOCK_STATE/server_auto_exclude_ru"
 printf '%s\n' '{"subscription":{"links":["hy2://test@foreign.invalid:443","vless://test@rush1.lenivo.site:443"]}}' > "$SUB_FILE"
 if sh "$d/auto-$v.sh"; then echo FAIL-RU-fallback; exit 1; fi
 [ ! -f "$MOCK_STATE/switches" ] && [ "$(cat "$SELECTED_LINK_FILE")" = 0 ]
 echo "PASS version=$v strict-RU-exclusion"
 reset; echo fallback > "$MOCK_STATE/scenario"; echo 0 > "$MOCK_STATE/server_auto_select"
 AUTO_FAILOVER_CANDIDATES=1 sh "$d/auto-$v.sh"
 grep -qx '1:1:1' "$MOCK_STATE/switches"
 [ "$(cat "$MOCK_STATE/server_auto_select")" = 0 ]
 echo "PASS version=$v one-shot-keeps-Auto-OFF"
 reset; echo quality > "$MOCK_STATE/scenario"
 AUTO_FAILOVER_CANDIDATES=0 sh "$d/auto-$v.sh"
 [ ! -f "$MOCK_STATE/switches" ] && [ "$(cat "$SELECTED_LINK_FILE")" = 0 ]
 echo "PASS version=$v quality-quorum-keeps-current"
 reset; echo cancel > "$MOCK_STATE/scenario"
 printf '%s\n' '{"subscription":{"links":["hy2://test@foreign.invalid:443","vless://test@one.invalid:443","hy2://test@two.invalid:443"]}}' > "$SUB_FILE"
 sh "$d/auto-$v.sh"
 [ "$(wc -l < "$MOCK_STATE/switches")" -eq 1 ]
 grep -qx 'cancelled:user_disabled' "$MOCK_STATE/auto_select_status"
 echo "PASS version=$v cancel-stops-next-candidate"
done
