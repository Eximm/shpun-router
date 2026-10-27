#!/bin/sh
# Actual agent functions with synthetic subscription/config and stubbed services.
set -eu
src=${1:-$(dirname "$0")/../package/shpun-router/files/etc/shpun/agent.sh}
d=$(mktemp -d /tmp/shpun-paid-resume.XXXXXX)
trap 'rm -rf "$d"' EXIT
for fn in resume_paid_subscription ensure_vpn_from_subscription;do
 awk -v fn="$fn" '$0 == fn "() {" {emit=1} emit {print} emit && /^}/ {emit=0}' "$src" >> "$d/functions"
done
sed "s|/etc/shpun/build-config.sh|$d/builder|g;s|/tmp/shpun-subscription-portal/blocked|$d/blocked|g" "$d/functions" > "$d/test-functions"
. "$d/test-functions"
PAID_RESUME_FILE="$d/resume";PAID_RESUME_ATTEMPT_FILE="$d/attempt"
SUB_FILE="$d/sub";SUB_URL_FILE="$d/url";SUB_MIRROR_URL_FILE="$d/mirror"
VPN_READY_FILE="$d/ready";ENGINE_CONFIG="$d/config";CONFIG_ACTIVE_FILE="$d/active"
CONFIG_PENDING_FILE="$d/pending";VERROR_FILE="$d/error";SHPUN_CONFIG_LOCK_HELD=0
export ENGINE_CONFIG
printf '#!/bin/sh\necho fresh > "$ENGINE_CONFIG"\n' > "$d/builder";chmod +x "$d/builder"
log(){ :; }
wait_for_default_route(){ :; }
ensure_routes_ready(){ :; }
is_vpn_process_running(){ [ -e "$d/running" ]; }
engine_download(){ :; }
ensure_tproxy_modules(){ :; }
config_lock_acquire(){ :; }
config_lock_release_if_owned(){ :; }
calc_sha256_file(){ sha256sum "$1" | cut -d' ' -f1; }
validate_engine_config(){ [ "${invalid:-0}" = 0 ]; }
restart_vpn(){ echo apply >> "$d/events";touch "$d/running"; }
wait_vpn_started(){ :; }
enable_protected_dns_forwarding(){ :; }
disable_protected_dns_forwarding(){ :; }
refresh_subscription_from_url(){
 echo fetch >> "$d/events"
 [ "${unavailable:-0}" = 0 ] || return 1
 # A changed subscription invokes ensure during its own installation.
 ensure_vpn_from_subscription
}
reset(){
 rm -f "$d/resume" "$d/attempt" "$d/pending" "$d/events" "$d/error"
 echo synthetic > "$SUB_FILE";echo old > "$ENGINE_CONFIG"
 calc_sha256_file "$ENGINE_CONFIG" > "$CONFIG_ACTIVE_FILE"
 touch "$d/running";echo ok > "$VPN_READY_FILE"
 invalid=0;unavailable=0;SHPUN_PAID_RESUME=0
}
reset
ensure_vpn_from_subscription
test -s "$CONFIG_PENDING_FILE";test ! -e "$d/events"
echo PASS ordinary-refresh-still-defers-without-restart
reset
resume_paid_subscription
test ! -e "$d/events"
echo PASS normal-active-path-does-not-fetch
reset
echo generation > "$PAID_RESUME_FILE"
if ensure_vpn_from_subscription;then echo FAIL stale-ensure-allowed;exit 1;fi
test ! -e "$d/events"
resume_paid_subscription
test "$(cat "$d/events")" = "$(printf 'fetch\napply')"
test ! -e "$PAID_RESUME_FILE";test ! -e "$CONFIG_PENDING_FILE"
test "$(cat "$CONFIG_ACTIVE_FILE")" = "$(calc_sha256_file "$ENGINE_CONFIG")"
echo PASS paid-resume-fetches-before-apply-and-restarts-once
reset
echo generation > "$PAID_RESUME_FILE";unavailable=1
if resume_paid_subscription;then exit 1;fi
n=$(wc -l < "$d/events")
if resume_paid_subscription;then exit 1;fi
test "$(wc -l < "$d/events")" = "$n"
test -s "$PAID_RESUME_FILE";! grep -q apply "$d/events"
echo PASS unavailable-source-keeps-pending-and-thirty-minute-budget
reset
echo generation > "$PAID_RESUME_FILE";invalid=1
if resume_paid_subscription;then exit 1;fi
test "$(cat "$ENGINE_CONFIG")" = old
test -s "$PAID_RESUME_FILE";! grep -q apply "$d/events"
echo PASS invalid-config-restores-previous-without-activation
