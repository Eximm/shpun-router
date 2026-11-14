#!/bin/sh
# The agent reuses the config switch-server.sh has just built only when it is
# exactly that config, for the selected server, fresh, and the subscription has
# not changed since; the note works once.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
STATE_DIR="$state" SUB_FILE="$state/subscription.json" ENGINE_CONFIG="$state/xray.json"
CONFIG_PREBUILT_FILE="$state/prebuilt"
eval "$(sed -n '/^calc_sha256_file() {$/,/^}$/p; /^prebuilt_config_current() {$/,/^}$/p' "$root/package/shpun-router/files/etc/shpun/agent.sh")"

echo '{}' > "$SUB_FILE"; touch -d '@1000' "$SUB_FILE"
echo '{"x":1}' > "$ENGINE_CONFIG"
echo 4 > "$state/selected_link_index"
sha=$(sha256sum "$ENGINE_CONFIG" | cut -d' ' -f1)
note() { printf '%s %s %s\n' "$1" "$2" "$3" > "$CONFIG_PREBUILT_FILE"; }
fails() { if "$@"; then echo "FAIL: unexpected success" >&2; exit 1; fi; }

note "$sha" 4 "$(date +%s)"; prebuilt_config_current
fails prebuilt_config_current                     # used once
note "$sha" 5 "$(date +%s)"; fails prebuilt_config_current    # another server
note "$sha" 4 "$(( $(date +%s) - 300 ))"; fails prebuilt_config_current   # stale
note deadbeef 4 "$(date +%s)"; fails prebuilt_config_current  # config changed
note "$sha" 4 "$(date +%s)"; touch -d "@$(( $(date +%s) + 5 ))" "$SUB_FILE"; fails prebuilt_config_current   # newer subscription
echo 'PASS prebuilt config is reused only when it is current'
