#!/bin/sh
# Isolated control-plane regression tests. No live config or services changed.
# Run on OpenWrt with ucode/jsonfilter; network and credentials are not needed.
set -eu
deploy=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo=$(dirname "$deploy")
src="$repo/package/shpun-router/files"
work=$(mktemp -d /tmp/shpun-hy2-control.XXXXXX)
cleanup() {
 case "$work" in /tmp/shpun-hy2-control.*)
  [ "$(readlink -f "$work")" = "$work" ] && rm -rf -- "$work" ;;
 esac
}
trap cleanup EXIT
command -v ucode >/dev/null
command -v jsonfilter >/dev/null
TEST_VARIANTS=$(sed -n 's/^PKG_VERSION:=\([12]\)\..*/\1/p' "$repo/package/shpun-router/Makefile")
case "$TEST_VARIANTS" in 1) TEST_VARIANTS=24 ;; 2) TEST_VARIANTS=25 ;; *) exit 1 ;; esac
export TEST_VARIANTS
cp "$src/etc/shpun/auto-failover.sh" "$work/auto-$TEST_VARIANTS.sh"
cp "$src/etc/shpun/agent.sh" "$work/agent-$TEST_VARIANTS.sh"
cp "$src/etc/shpun/switch-server.sh" "$work/switch-$TEST_VARIANTS.sh"
cp "$src/usr/share/rpcd/ucode/shpun.uc" "$work/rpc-$TEST_VARIANTS.uc"
cp "$deploy/hysteria2-fixtures/"* "$work/"
sh "$work/rpc.sh" "$work"
sh "$work/bootstrap.sh" "$work"
sh "$work/control.sh" "$work"
sh "$work/engine-guard.sh" "$work"
echo HYSTERIA_CONTROL_TESTS_OK
