#!/bin/sh

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
PKG_DIR="$REPO_DIR/package/shpun-router"
AUTO_SCRIPT="$PKG_DIR/files/etc/shpun/auto-failover.sh"
SWITCH_SCRIPT="$PKG_DIR/files/etc/shpun/switch-server.sh"
AGENT_SCRIPT="$PKG_DIR/files/etc/shpun/agent.sh"
RPC_SCRIPT="$PKG_DIR/files/usr/share/rpcd/ucode/shpun.uc"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM
MOCK_DIR="$TMP_DIR/mock"
STATE_DIR="$TMP_DIR/state"
mkdir -p "$MOCK_DIR" "$STATE_DIR"

printf '%s\n' '#!/bin/sh' 'exit 0' > "$MOCK_DIR/logger"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "{\"subscription\":{\"links\":[\"vless://test\"]}}"' > "$MOCK_DIR/jsonfilter"
printf '%s\n' \
	'#!/bin/sh' \
	'url=""' \
	'for arg in "$@"; do url="$arg"; done' \
	'case "$url" in' \
	'  *speed-test*) exit 1 ;;' \
	'  *fail-confirm*) exit 1 ;;' \
	'esac' \
	'exit 0' > "$MOCK_DIR/curl"
chmod +x "$MOCK_DIR/logger" "$MOCK_DIR/jsonfilter" "$MOCK_DIR/curl"

printf '%s\n' \
	'TUNNEL_QUALITY_PROBE_URL="https://probe.invalid/speed-test"' \
	'TUNNEL_QUALITY_CONFIRM_URLS="https://ok-one.invalid/ https://ok-two.invalid/ https://ok-three.invalid/"' \
	'TUNNEL_QUALITY_CONFIRM_MIN_SUCCESS=2' > "$STATE_DIR/agent.conf"
printf '%s\n' '{"subscription":{"links":["vless://test"]}}' > "$STATE_DIR/subscription.json"
printf '%s\n' 0 > "$STATE_DIR/selected_link_index"
printf '%s\n' ready > "$STATE_DIR/vpn_ready"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$1" >> "'"$TMP_DIR"'/switches"' 'printf "%s\n" ok' > "$TMP_DIR/switch.sh"
chmod +x "$TMP_DIR/switch.sh"

PATH="$MOCK_DIR:$PATH" \
STATE_DIR="$STATE_DIR" \
CONF="$STATE_DIR/agent.conf" \
SUB_FILE="$STATE_DIR/subscription.json" \
SELECTED_LINK_FILE="$STATE_DIR/selected_link_index" \
SWITCH_SCRIPT="$TMP_DIR/switch.sh" \
VPN_READY_FILE="$STATE_DIR/vpn_ready" \
AUTO_FAILOVER_LOCKDIR="$TMP_DIR/selection.lock" \
AUTO_FAILOVER_CANDIDATES=0 \
AUTO_FAILOVER_IGNORE_COOLDOWN=1 \
sh "$AUTO_SCRIPT"

grep -qx 'ok:0' "$STATE_DIR/auto_select_status"
[ ! -e "$TMP_DIR/switches" ]

printf '%s\n' \
	'TUNNEL_QUALITY_PROBE_URL="https://probe.invalid/speed-test"' \
	'TUNNEL_QUALITY_CONFIRM_URLS="https://fail-confirm-one.invalid/ https://fail-confirm-two.invalid/ https://fail-confirm-three.invalid/"' \
	'TUNNEL_QUALITY_CONFIRM_MIN_SUCCESS=2' > "$STATE_DIR/agent.conf"
rm -f "$STATE_DIR/auto_select_status" "$STATE_DIR/auto_failover_last_attempt"
if PATH="$MOCK_DIR:$PATH" \
	STATE_DIR="$STATE_DIR" \
	CONF="$STATE_DIR/agent.conf" \
	SUB_FILE="$STATE_DIR/subscription.json" \
	SELECTED_LINK_FILE="$STATE_DIR/selected_link_index" \
	SWITCH_SCRIPT="$TMP_DIR/switch.sh" \
	VPN_READY_FILE="$STATE_DIR/vpn_ready" \
	AUTO_FAILOVER_LOCKDIR="$TMP_DIR/selection.lock" \
	AUTO_FAILOVER_CANDIDATES=0 \
	AUTO_FAILOVER_IGNORE_COOLDOWN=1 \
	sh "$AUTO_SCRIPT"; then
	echo "quality quorum failure was accepted" >&2
	exit 1
fi
grep -qx 'failed:0' "$STATE_DIR/auto_select_status"

mkdir "$TMP_DIR/selection.lock"
printf '%s\n' "$$" > "$TMP_DIR/selection.lock/pid"
busy_result="$(AUTO_FAILOVER_LOCKDIR="$TMP_DIR/selection.lock" CONFIG_LOCKDIR="$TMP_DIR/config.lock" sh "$SWITCH_SCRIPT" 0 2>/dev/null || true)"
[ "$busy_result" = "automatic_selection_busy" ]
rm -f "$TMP_DIR/selection.lock/pid"
rmdir "$TMP_DIR/selection.lock"

mkdir "$TMP_DIR/selection.lock"
printf '%s\n' 999999 > "$TMP_DIR/selection.lock/pid"
stale_result="$(AUTO_FAILOVER_LOCKDIR="$TMP_DIR/selection.lock" CONFIG_LOCKDIR="$TMP_DIR/config.lock" sh "$SWITCH_SCRIPT" 0 2>/dev/null || true)"
[ "$stale_result" = "build_not_ready" ]
[ ! -d "$TMP_DIR/selection.lock" ]

find "$PKG_DIR/files/etc/shpun" "$PKG_DIR/files/etc/init.d" "$PKG_DIR/files/etc/uci-defaults" -type f \( -name '*.sh' -o -path '*/init.d/*' -o -path '*/uci-defaults/*' \) -exec sh -n {} \;
grep -q 'return 2' "$AGENT_SCRIPT"
grep -q 'automatic selection is running' "$RPC_SCRIPT"

printf '%s\n' "ok: quality quorum, separate degradation result, and selection lock"

