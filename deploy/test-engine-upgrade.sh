#!/bin/sh
# The router must run exactly the pinned Xray build: install it only after its
# SHA-256 and self-test pass, replace an older running build with one restart,
# keep the previous binary until the tunnel works and restore it otherwise.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
agent="$root/package/shpun-router/files/etc/shpun/agent.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for fn in calc_sha256_file engine_url_from_base engine_expected_sha256 engine_installed_sha256 \
	engine_candidate_ok engine_fetch_candidate engine_upgrade_due engine_upgrade_failed \
	maybe_upgrade_engine engine_download; do
	body="$(sed -n "/^$fn() {\$/,/^}\$/p" "$agent")"
	[ -n "$body" ] || { echo "FAIL: $fn not found in agent.sh"; exit 1; }
	eval "$body"
done

fake_engine() { # NAME [fail-test]
	{
		echo '#!/bin/sh'
		echo "# build $1"
		if [ "${2:-}" = fail-test ]; then
			echo '[ "$1" = version ] && exit 0; exit 1'
		else
			echo 'exit 0'
		fi
	} > "$work/$1"
	chmod 755 "$work/$1"
}
sha() { sha256sum "$1" | awk '{print $1}'; }

fake_engine old
fake_engine good
fake_engine evil
fake_engine strict fail-test
mkdir -p "$work/server" "$work/cache"

ENGINE_BIN="$work/xray"
ENGINE_CONFIG="$work/xray.json"
echo '{}' > "$ENGINE_CONFIG"
ENGINE_URL="https://router.example/files/xray/xray-aarch64-26.6.27"
ENGINE_BASE_URL="https://router.example/files/xray"
ENGINE_BASE_URLS="$ENGINE_BASE_URL"
ENGINE_ARCH=aarch64
ENGINE_VERSION=26.6.27
ENGINE_VERSION_DEFAULT=26.6.27
ENGINE_BUILD=26.6.27-reply-close1
ENGINE_SHA256=
ENGINE_BUILD_SHA256_AARCH64="$(sha "$work/good")"
ENGINE_CACHE_FILE="$work/cache/xray.gz"
ENGINE_SHA_CACHE_FILE="$work/sha-cache"
ENGINE_UPGRADE_FAIL_FILE="$work/upgrade-failed-at"
ENGINE_UPGRADE_RETRY_INTERVAL=3600
ENGINE_DOWNLOAD_FAIL_FILE="$work/download-failed-at"
ENGINE_DOWNLOAD_RETRY_INTERVAL=300
HTTP_BIN=curl

log() { printf '%s\n' "$*" >> "$work/log"; }
detect_engine_arch() { echo aarch64; }
detect_http_client() { :; }
ensure_bootstrap_dns() { :; }
http_get_to_file() { # serve files from $work/server by basename
	echo "$1" >> "$work/downloads"
	[ -f "$work/server/${1##*/}" ] || return 1
	cp "$work/server/${1##*/}" "$2"
}
RUNNING=0
restart_vpn() { echo restart >> "$work/restarts"; RUNNING=1; }
wait_vpn_started() { :; }
is_vpn_process_running() { [ "$RUNNING" = 1 ]; }
planned_vpn_restart_active() { return 1; }
config_lock_acquire() { :; }
config_lock_release() { :; }
engine_running_is_installed() { :; }
TUNNEL_WORKS=1
engine_tunnel_confirmed() { [ "$TUNNEL_WORKS" = 1 ]; }

reset() {
	rm -f "$ENGINE_BIN" "$ENGINE_BIN.previous" "$ENGINE_BIN.candidate" "$work/server/"* "$ENGINE_CACHE_FILE" \
		"$ENGINE_SHA_CACHE_FILE" "$ENGINE_UPGRADE_FAIL_FILE" "$ENGINE_DOWNLOAD_FAIL_FILE" \
		"$work/downloads" "$work/restarts" "$work/log"
	RUNNING=0
	TUNNEL_WORKS=1
}
count() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
installed_is() { cmp -s "$ENGINE_BIN" "$work/$1"; }
fail() { echo "FAIL: $*"; cat "$work/log" 2>/dev/null; exit 1; }

# 1. Fresh boot: a tampered file under the build name is skipped, the matching
#    one under the version name is installed.
reset
cp "$work/evil" "$work/server/xray-aarch64-26.6.27-reply-close1"
cp "$work/good" "$work/server/xray-aarch64-26.6.27"
engine_download || fail "fresh download failed"
installed_is good || fail "fresh download installed the wrong build"
[ ! -e "$ENGINE_BIN.candidate" ] || fail "candidate left behind"
echo "PASS fresh install verifies sha256 and skips a tampered file"

# 2. No matching build anywhere: nothing is installed, the failure is rate limited.
reset
cp "$work/evil" "$work/server/xray-aarch64-26.6.27"
if engine_download; then fail "a wrong build was accepted"; fi
[ ! -e "$ENGINE_BIN" ] || fail "a wrong build was installed"
[ -s "$ENGINE_DOWNLOAD_FAIL_FILE" ] || fail "download failure not recorded"
echo "PASS wrong build is never installed"

# 3. The right build is present: no download, hash computed once per file.
reset
cp "$work/good" "$ENGINE_BIN"
engine_download || fail "present engine rejected"
engine_download || fail "present engine rejected on second call"
[ "$(count "$work/downloads")" = 0 ] || fail "downloaded although the build matches"
[ -s "$ENGINE_SHA_CACHE_FILE" ] || fail "sha not cached"
echo "PASS matching engine is kept without downloads"

# 4. Older build present but not running yet: replaced before the first start,
#    from the flash cache when it matches, without restarts.
reset
cp "$work/old" "$ENGINE_BIN"
gzip -c "$work/good" > "$ENGINE_CACHE_FILE"
engine_download || fail "pre-start replacement failed"
installed_is good || fail "older build not replaced before start"
[ "$(count "$work/downloads")" = 0 ] || fail "cache was not used"
[ "$(count "$work/restarts")" = 0 ] || fail "restarted although nothing ran"
echo "PASS older boot copy replaced from verified cache before start"

# 5. Older build running: engine_download leaves it, the main loop replaces it
#    with exactly one restart and drops the previous copy.
reset
cp "$work/old" "$ENGINE_BIN"
cp "$work/good" "$work/server/xray-aarch64-26.6.27-reply-close1"
RUNNING=1
engine_download || fail "running engine rejected"
installed_is old || fail "running engine replaced outside the main loop"
maybe_upgrade_engine
installed_is good || fail "running older build not upgraded"
[ "$(count "$work/restarts")" = 1 ] || fail "expected one restart, got $(count "$work/restarts")"
[ ! -e "$ENGINE_BIN.previous" ] || fail "previous binary kept after success"
maybe_upgrade_engine
[ "$(count "$work/restarts")" = 1 ] || fail "restarted again after the upgrade"
echo "PASS running older build replaced with one restart"

# 6. New build starts but the tunnel does not work: previous binary restored,
#    retry postponed.
reset
cp "$work/old" "$ENGINE_BIN"
cp "$work/good" "$work/server/xray-aarch64-26.6.27-reply-close1"
RUNNING=1
TUNNEL_WORKS=0
maybe_upgrade_engine
installed_is old || fail "previous binary not restored"
[ "$(count "$work/restarts")" = 2 ] || fail "expected upgrade and rollback restarts"
[ -s "$ENGINE_UPGRADE_FAIL_FILE" ] || fail "rollback not recorded"
maybe_upgrade_engine
[ "$(count "$work/restarts")" = 2 ] || fail "retried before the interval"
echo "PASS failed upgrade rolls back and waits"

# 7. Candidate that rejects the current config is never swapped in.
reset
cp "$work/old" "$ENGINE_BIN"
ENGINE_BUILD_SHA256_AARCH64="$(sha "$work/strict")"
cp "$work/strict" "$work/server/xray-aarch64-26.6.27-reply-close1"
RUNNING=1
maybe_upgrade_engine
installed_is old || fail "candidate failing the config test was installed"
[ "$(count "$work/restarts")" = 0 ] || fail "restarted for a rejected candidate"
ENGINE_BUILD_SHA256_AARCH64="$(sha "$work/good")"
echo "PASS candidate must accept the current config"

# 8. An admin-chosen version is not pinned: the present engine stays.
reset
cp "$work/old" "$ENGINE_BIN"
RUNNING=1
ENGINE_VERSION=99.0.0
engine_download || fail "unpinned engine rejected"
maybe_upgrade_engine
installed_is old || fail "unpinned engine replaced"
ENGINE_VERSION=26.6.27
echo "PASS custom ENGINE_VERSION keeps the admin's engine"
