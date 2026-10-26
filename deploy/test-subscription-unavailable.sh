#!/bin/sh
# Isolated regression: synthetic state and stubbed transport/service operations.
set -eu
src=${1:-$(dirname "$0")/../package/shpun-router/files/etc/shpun/agent.sh}
d=$(mktemp -d /tmp/shpun-sub-unavailable.XXXXXX)
cleanup() { case "$d" in /tmp/shpun-sub-unavailable.*) [ "$(readlink -f "$d")" = "$d" ] && rm -rf -- "$d" ;; esac; }
trap cleanup EXIT
for fn in reset_subscription_unavailable_count reset_subscription_state note_subscription_unavailable check_subscription_alive; do
 awk -v fn="$fn" '$0 == fn "() {" {emit=1} emit {print} emit && /^}/ {emit=0}' "$src" >> "$d/functions"
done
. "$d/functions"
STATE_DIR="$d/state"; mkdir "$STATE_DIR"
SUB_FILE="$STATE_DIR/subscription.json"; SUB_URL_FILE="$STATE_DIR/subscription_url"
SUB_MIRROR_URL_FILE="$STATE_DIR/mirror"; CONFIG_URL_FILE="$STATE_DIR/profile"
LAST_CHECK_FILE="$STATE_DIR/lastcheck"; SUB_UNAVAILABLE_COUNT_FILE="$STATE_DIR/failures"
CONFIG_ACTIVE_FILE="$STATE_DIR/active"; CONFIG_PENDING_FILE="$STATE_DIR/pending"
TUNNEL_EXIT_IP_FILE="$STATE_DIR/exit_ip"; TUNNEL_EXIT_CHECK_MS_FILE="$STATE_DIR/exit_ms"
TUNNEL_EXIT_PING_MS_FILE="$STATE_DIR/ping_ms"; TUNNEL_EXIT_LAST_OK_FILE="$STATE_DIR/last_ok"
TUNNEL_QUALITY_DEGRADED_FILE="$STATE_DIR/degraded"; AUTO_RECOVERY_LAST_ATTEMPT_FILE="$STATE_DIR/recovery"
AUTO_RECOVERY_FAIL_COUNT_FILE="$STATE_DIR/recovery_count"; VERROR_FILE="$STATE_DIR/error"
SUB_CHECK_INTERVAL=0; SUB_UNAVAILABLE_RESET_LIMIT=3
log() { printf '%s\n' "$*" >> "$d/events"; }
disable_dead_vpn_path() { echo stopped >> "$d/stops"; }
refresh_subscription_source_metadata() { :; }
refresh_subscription_from_url() { return 1; }
detect_http_client() { HTTP_BIN=; }
for f in "$SUB_FILE" "$SUB_URL_FILE" "$SUB_MIRROR_URL_FILE" "$CONFIG_URL_FILE" "$CONFIG_ACTIVE_FILE" "$STATE_DIR/selected_link_index"; do echo synthetic > "$f"; done
sha256sum "$SUB_FILE" "$SUB_URL_FILE" "$SUB_MIRROR_URL_FILE" "$CONFIG_URL_FILE" "$CONFIG_ACTIVE_FILE" "$STATE_DIR/selected_link_index" > "$d/snapshot"
i=0
while [ "$i" -lt 5 ]; do check_subscription_alive || true; i=$((i+1)); done
sha256sum -c "$d/snapshot" >/dev/null || { echo FAIL transient-unavailability-destroys-state; exit 1; }
test ! -e "$d/stops"
test "$(cat "$SUB_UNAVAILABLE_COUNT_FILE")" = 5
echo PASS repeated-transport-failure-preserves-subscription-selection-and-vpn
echo corrupt > "$SUB_UNAVAILABLE_COUNT_FILE"
note_subscription_unavailable profile_gateway_invalid_response 123
test "$(cat "$SUB_UNAVAILABLE_COUNT_FILE")" = 1
sha256sum -c "$d/snapshot" >/dev/null
echo PASS invalid-counter-and-invalid-response-preserve-state
reset_subscription_unavailable_count
test ! -e "$SUB_UNAVAILABLE_COUNT_FILE"
echo PASS recovery-clears-counter
# Explicit authoritative rejection must still revoke the profile.
detect_http_client() { HTTP_BIN=synthetic; }
public_config_url() { printf '%s' "$1"; }
save_config_url() { :; }
append_format_json() { printf '%s' "$1"; }
http_get_stdout() { printf '%s' '{"ok":0,"error":"subscription_removed"}'; }
save_router_software_metadata_text() { :; }
jsonfilter() { case "$*" in *@.ok*) echo 0 ;; *@.error*) echo subscription_removed ;; esac; }
check_subscription_alive || true
test ! -e "$SUB_FILE"; test ! -e "$SUB_URL_FILE"; test ! -e "$CONFIG_URL_FILE"
test "$(cat "$d/stops")" = stopped
test "$(cat "$VERROR_FILE")" = subscription_removed
echo PASS authoritative-rejection-still-clears-subscription-and-stops-vpn
