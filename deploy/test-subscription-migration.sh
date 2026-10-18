#!/bin/sh
# Isolated regression suite: no real credentials, network, live config or services.
set -eu
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
d=$(mktemp -d /tmp/shpun-source-test.XXXXXX)
cleanup() { case "$d" in /tmp/shpun-source-test.*) [ "$(readlink -f "$d")" = "$d" ] && rm -rf -- "$d" ;; esac; }
trap cleanup EXIT
src="$repo/package/shpun-router/files"
. "$src/usr/share/shpun/subscription-sources.sh"
state="$d/state"; mkdir "$state"
SUB_URL_FILE="$state/subscription_url"; SUB_MIRROR_URL_FILE="$state/subscription_mirror_url"
SUBSCRIPTION_MIRROR_BASE_URL=https://cdn.netget.online
echo 'https://melori.site/sub/token123?x=1#name' > "$SUB_URL_FILE"
echo 'https://mirepo.space/token123' > "$SUB_MIRROR_URL_FILE"
printf '%s\n' '# keep comment' "SUBSCRIPTION_MIRROR_BASE_URL='https://mirepo.space/'" 'CUSTOM=preserved' > "$state/agent.conf"
echo live-tunnel > "$state/xray.json"
before=$(sha256sum "$state/xray.json")
sub_migrate_state "$state"
[ "$(cat "$SUB_URL_FILE")" = 'https://sub.netget.online/sub/token123?x=1#name' ]
[ "$(cat "$SUB_MIRROR_URL_FILE")" = 'https://cdn.netget.online/token123' ]
grep -q '^CUSTOM=preserved$' "$state/agent.conf"
grep -q '^SUBSCRIPTION_MIRROR_BASE_URL="https://cdn.netget.online"$' "$state/agent.conf"
[ "$before" = "$(sha256sum "$state/xray.json")" ]
sub_legacy_eligible "${SUB_URL_FILE}.legacy"
sub_legacy_eligible "${SUB_MIRROR_URL_FILE}.legacy"
snapshot=$(sha256sum "$state/"*)
sub_migrate_state "$state"
[ "$snapshot" = "$(sha256sum "$state/"*)" ]
mktemp() { echo 'unexpected write after migration' >&2; return 1; }
sub_migrate_state "$state"
unset -f mktemp
[ "$(ls -ld "$SUB_URL_FILE" | cut -c1-10)" = '-rw-------' ]
for custom in https://melori.site.evil.test/token https://user@melori.site/token https://custom.invalid/token https://melori.site:8443/token; do
 [ "$(sub_canonical_url "$custom")" = "$custom" ]
done
echo PASS migration-known-host-path-query-fragment-idempotence-private-mode-no-tunnel-change
for quote in double single bare; do
 case "$quote" in
 double) echo 'SUBSCRIPTION_MIRROR_BASE_URL="https://mirepo.space"' > "$state/agent.conf" ;;
 single) echo "SUBSCRIPTION_MIRROR_BASE_URL='http://mirepo.space/'" > "$state/agent.conf" ;;
 bare) echo 'SUBSCRIPTION_MIRROR_BASE_URL=https://mirepo.space' > "$state/agent.conf" ;;
 esac
 sub_migrate_state "$state"
 grep -q 'https://cdn.netget.online' "$state/agent.conf"
done
echo 'SUBSCRIPTION_MIRROR_BASE_URL="https://custom.invalid"' > "$state/agent.conf"
sub_migrate_state "$state"
grep -q 'https://custom.invalid' "$state/agent.conf"
echo PASS preserved-config-quote-forms-custom-base
printf '%s\n' '{"subscription":{"links":["hy2://test@a.invalid","vless://test@b.invalid"]}}' > "$d/old.json"
printf '%s\n' '{"subscription":{"links":[{"url":"vless://test@b.invalid"},{"hy2":"hy2://test@a.invalid"}]}}' > "$d/new.json"
[ "$(sub_find_selected_index "$d/old.json" "$d/new.json" 0)" = 1 ]
! sub_find_selected_index "$d/old.json" "$d/new.json" 99
echo PASS selected-node-preserved-across-reorder-and-object-links
for fn in save_subscription_url download_subscription_from_url_file refresh_subscription_source_metadata check_subscription_alive probe_url_through_tunnel reconcile_vpn_ready; do
 awk -v fn="$fn" '$0 == fn "() {" {emit=1} emit {print} emit && /^}/ {emit=0}' "$src/etc/shpun/agent.sh" >> "$d/functions.sh"
done
. "$d/functions.sh"
log() { echo "$*" >> "$d/events"; }
save_subscription_url https://melori.site/sub/token456
[ "$(cat "$SUB_URL_FILE")" = https://sub.netget.online/sub/token456 ]
[ "$(cat "$SUB_MIRROR_URL_FILE")" = https://cdn.netget.online/token456 ]
! sub_legacy_eligible "${SUB_MIRROR_URL_FILE}.legacy"
echo PASS old-billing-host-canonicalized-stale-token-fallback-rejected
HTTP_USER_AGENT=test
CONFIG_URL_FILE="$state/profile"
echo https://router.invalid/profile > "$CONFIG_URL_FILE"
curl() { printf '%s' '{"ok":1,"subscription_url":"https://sub.netget.online/sub/newtoken"}'; }
jsonfilter() { case "$*" in *@.ok*) echo 1 ;; esac; }
extract_subscription_url_from_json_text() { echo https://sub.netget.online/sub/newtoken; }
append_format_json() { printf '%s' "$1"; }
save_router_software_metadata_text() { :; }
detect_http_client() { HTTP_BIN=curl; }
SUB_FILE="$state/subscription.json"; echo active > "$SUB_FILE"
LAST_CHECK_FILE="$state/lastcheck"; echo 0 > "$LAST_CHECK_FILE"
SUB_CHECK_INTERVAL=21600
refresh_subscription_from_url() { echo "data:$2" >> "$d/order"; return 0; }
reset_subscription_unavailable_count() { :; }
check_subscription_alive
[ "$(cat "$SUB_URL_FILE")" = https://sub.netget.online/sub/newtoken ]
grep -q 'metadata refreshed' "$d/events"
grep -q 'data:direct' "$d/order"
[ "$(cat "$SUB_FILE")" = active ]
echo PASS metadata-updated-before-successful-direct-without-installing-profile-links
curl() { return 28; }
refresh_subscription_source_metadata
[ "$(cat "$SUB_URL_FILE")" = https://sub.netget.online/sub/newtoken ]
echo PASS billing-failure-keeps-saved-URLs
# Verify real download helper rejects invalid content and stale legacy token.
http_get_subscription_to_file() { echo '<html>error</html>' > "$2"; }
normalize_subscription_file() { return 1; }
! download_subscription_from_url_file "$d/out" "$SUB_URL_FILE" direct
! download_subscription_from_url_file "$d/out" "${SUB_MIRROR_URL_FILE}.legacy" legacy
[ "$(cat "$SUB_FILE")" = active ]
echo PASS invalid-body-and-stale-legacy-cannot-replace-active-subscription
# Verify priority without any real HTTP: new direct, new CDN, old direct, old CDN.
: > "$d/order"
refresh_subscription_from_url() {
 echo "$2" >> "$d/order"
 [ "$2" = 'legacy mirror' ]
}
check_subscription_alive
[ "$(tr '\n' ',' < "$d/order")" = 'direct,mirror,legacy direct,legacy mirror,' ]
echo PASS fallback-order-new-direct-new-CDN-old-direct-old-CDN
HTTP_PROXY_PORT=10809
curl() { echo 'http=000 connect=0.001 start=0 total=8'; return 28; }
if probe_url_through_tunnel https://secret.invalid/private-token; then exit 1; else [ "$?" = 28 ]; fi
grep -q 'proxy probe failed (rc=28' "$d/events"
! grep -q 'private-token' "$d/events"
echo PASS probe-error-details-no-private-URLs
VPN_READY_FILE="$state/vpn_ready"
echo ok > "$VPN_READY_FILE"
is_vpn_process_running() { return 0; }
planned_vpn_restart_active() { return 1; }
reconcile_vpn_ready
test -s "$VPN_READY_FILE"
is_vpn_process_running() { return 1; }
planned_vpn_restart_active() { return 0; }
reconcile_vpn_ready
test -s "$VPN_READY_FILE"
planned_vpn_restart_active() { return 1; }
reconcile_vpn_ready
test ! -e "$VPN_READY_FILE"
echo PASS missing-xray-clears-stale-ready-but-keeps-running-and-planned-restarts
