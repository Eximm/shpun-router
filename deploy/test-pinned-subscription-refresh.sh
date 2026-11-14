#!/bin/sh
# A pinned server that disappears from (or is renamed in) a refreshed
# subscription must never block the refresh: the router would otherwise keep
# stale expiry data and dead servers forever.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
files="$root/package/shpun-router/files"
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

STATE_DIR="$state"
SUB_FILE="$state/subscription.json"
SERVER_AUTO_SELECT_FILE="$state/server_auto_select"
VERROR_FILE="$state/vpn_error"
# Never touch the real measurements of the machine running the test.
export SELECTION_SCORES_FILE="$state/scores" SELECTION_MEASURED_AT_FILE="$state/measured-at"
cp "$files/etc/shpun/server-groups.uc" "$files/etc/shpun/server-selection.uc" "$state/"

. "$files/usr/share/shpun/subscription-sources.sh"
eval "$(sed -n '/^install_updated_subscription_candidate() {$/,/^}$/p' "$files/etc/shpun/agent.sh")"

log() { printf '%s\n' "$*" >> "$state/log"; }
config_lock_acquire() { return 0; }
config_lock_release() { return 0; }
ensure_selected_link_valid() { return 0; }
auto_select_current() { cat "$SERVER_AUTO_SELECT_FILE"; }
ensure_vpn_from_subscription() { return "${ENSURE_RC:-0}"; }

feed() {
	printf '{"subscription":{"links":['
	sep=
	for label in "$@"; do
		printf '%s"hy2://x@h.example:443#%s"' "$sep" "$label"
		sep=,
	done
	printf ']}}\n'
}

old='%E2%9A%A1%20%D0%90%D0%B2%D1%82%D0%BE%D0%B2%D1%8B%D0%B1%D0%BE%D1%80'
fi_old='Helsinki%20/%20Hysteria%202'
fi_new='%F0%9F%87%AB%F0%9F%87%AE%20Helsinki%20FI%20/%20Hysteria%202'
pl='%F0%9F%87%B5%F0%9F%87%B1%20Warsaw%20PL%20/%20Hysteria%202'

# 1. Pinned server still present but reordered: follow it, stay pinned.
feed "$old" "$fi_new" "$pl" > "$SUB_FILE"
feed "$old" "$pl" "$fi_new" > "$state/candidate"
echo 1 > "$state/selected_link_index"
echo 0 > "$SERVER_AUTO_SELECT_FILE"
install_updated_subscription_candidate "$state/candidate" test
[ "$(cat "$state/selected_link_index")" = 2 ]
[ "$(cat "$SERVER_AUTO_SELECT_FILE")" = 0 ]
grep -q 'Warsaw%20PL' "$SUB_FILE"

# 2. Pinned server renamed in the panel: the refresh is accepted, automatic selection resumes.
feed "$old" "$fi_old" "$pl" > "$SUB_FILE"
feed "$old" "$fi_new" "$pl" > "$state/candidate"
echo 1 > "$state/selected_link_index"
echo 0 > "$SERVER_AUTO_SELECT_FILE"
install_updated_subscription_candidate "$state/candidate" test
grep -q 'Helsinki%20FI' "$SUB_FILE"
[ "$(cat "$SERVER_AUTO_SELECT_FILE")" = 1 ]
grep -q 'returning to automatic selection' "$state/log"

# 3. The "Автовыбор" alias was pinned (index 0): same safe fallback.
feed "$old" "$fi_new" > "$SUB_FILE"
feed "$old" "$fi_new" "$pl" > "$state/candidate"
echo 0 > "$state/selected_link_index"
echo 0 > "$SERVER_AUTO_SELECT_FILE"
install_updated_subscription_candidate "$state/candidate" test
grep -q 'Warsaw' "$SUB_FILE"
[ "$(cat "$SERVER_AUTO_SELECT_FILE")" = 1 ]

# 4. A candidate that cannot be applied restores both the feed and the pin.
feed "$old" "$fi_old" > "$SUB_FILE"
cp "$SUB_FILE" "$state/expected"
feed "$old" "$fi_new" > "$state/candidate"
echo 1 > "$state/selected_link_index"
echo 0 > "$SERVER_AUTO_SELECT_FILE"
if ENSURE_RC=1 install_updated_subscription_candidate "$state/candidate" test; then
	echo 'FAIL: rejected candidate reported success' >&2; exit 1
fi
cmp -s "$SUB_FILE" "$state/expected"
[ "$(cat "$SERVER_AUTO_SELECT_FILE")" = 0 ]
[ "$(cat "$state/selected_link_index")" = 1 ]

echo 'PASS pinned server rename/removal never blocks subscription refresh'

# 5. Measurements are per index: a changed link list drops them, the same list keeps them.
echo 0 > "$SERVER_AUTO_SELECT_FILE"; echo 1 > "$state/selected_link_index"
feed "$old" "$fi_new" "$pl" > "$SUB_FILE"
{ printf '{"x":1,'; feed "$old" "$fi_new" "$pl" | cut -c2-; } > "$state/candidate"
echo '1 0.050 1' > "$SELECTION_SCORES_FILE"; echo 1 > "$SELECTION_MEASURED_AT_FILE"
install_updated_subscription_candidate "$state/candidate" test
[ -s "$SELECTION_SCORES_FILE" ] || { echo 'FAIL: unchanged links dropped measurements' >&2; exit 1; }
feed "$old" "$pl" "$fi_new" > "$state/candidate"
install_updated_subscription_candidate "$state/candidate" test
[ ! -e "$SELECTION_SCORES_FILE" ] && [ ! -e "$SELECTION_MEASURED_AT_FILE" ] || { echo 'FAIL: stale measurements kept' >&2; exit 1; }
echo 'PASS measurements are dropped when the server list changes'
