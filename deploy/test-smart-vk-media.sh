#!/bin/sh
# Synthetic state only; real builder/DNS functions, no live services or traffic.
set -eu
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
builder=${1:-$repo/package/shpun-router/files/etc/shpun/build-config.sh}
dns=${2:-$repo/package/shpun-router/files/etc/shpun/dns-xray.sh}
builtin=${3:-$repo/package/shpun-router/files/etc/shpun/routes/presets/smart_ru.domains}
d=$(mktemp -d /tmp/shpun-vk-rules.XXXXXX)
cleanup() { case "$d" in /tmp/shpun-vk-rules.*) [ "$(readlink -f "$d")" = "$d" ] && rm -rf -- "$d" ;; esac; }
trap cleanup EXIT
for fn in json_escape get_routing_mode build_smart_ru_domain_rule; do
 awk -v fn="$fn" '$0 == fn "() {" {emit=1} emit {print} emit && /^}/ {emit=0}' "$builder" >> "$d/functions"
done
for fn in sort_unique_file apply_direct_nftsets; do
 awk -v fn="$fn" '$0 == fn "() {" {emit=1} emit {print} emit && /^}/ {emit=0}' "$dns" >> "$d/functions"
done
. "$d/functions"
log() { :; }
logger() { :; }
jsonfilter() { :; }
dnsmasq_available() { return 0; }
dnsmasq_nftset_available() { return 0; }
restart_dnsmasq() { echo restart >> "$d/restarts"; }
nft() { :; }
ROUTES_MODE_FILE="$d/mode"; MODE_FILE="$d/mode"; PROFILE_FILE="$d/profile"
SMART_RU_DOMAINS_FILE="$d/remote"; SMART_DOMAINS_FILE="$d/remote"
SMART_RU_BUILTIN_DOMAINS_FILE="$builtin"; SMART_BUILTIN_DOMAINS_FILE="$builtin"
CUSTOM_ROUTES_FILE="$d/custom"; NFTSET_CONF_FILE="$d/nftset.conf"
NFTSET_RELOAD_FILE="$d/reload"; NFTSET_SUFFIX='4#inet#shpun#domain_direct'
printf 'vk.com\nremote-preserved.example\n' > "$d/remote"
echo smart_ru > "$d/mode"
build_smart_ru_domain_rule > "$d/rules"
apply_direct_nftsets
count=0
while IFS= read -r root; do
 case "$root" in ''|\#*) continue;; esac
 grep -Fq "\"domain:$root\"" "$d/rules" || { echo "FAIL missing TCP domain $root"; exit 1; }
 grep -Fqx "nftset=/$root/$NFTSET_SUFFIX" "$d/nftset.conf" || { echo "FAIL missing UDP/DNS domain $root"; exit 1; }
 count=$((count+1))
done < "$builtin"
grep -Fq 'domain:remote-preserved.example' "$d/rules"
echo "PASS all-$count-VK-roots-in-TCP-and-DNS-UDP-policies"
before=$(sha256sum "$d/nftset.conf"); restarts=$(wc -l < "$d/restarts")
apply_direct_nftsets
test "$before" = "$(sha256sum "$d/nftset.conf")"
test "$restarts" = "$(wc -l < "$d/restarts")"
echo PASS idempotent-no-unnecessary-DNS-restart
printf 'replacement.example\n' > "$d/remote"
build_smart_ru_domain_rule > "$d/rules"
grep -Fq 'domain:vkuservideo.net' "$d/rules"
grep -Fq 'domain:replacement.example' "$d/rules"
echo PASS downloaded-feed-refresh-cannot-remove-built-in-VK-baseline
rm "$d/remote"
build_smart_ru_domain_rule > "$d/rules"
grep -Fq 'domain:vkuserphoto.ru' "$d/rules"
echo PASS built-in-baseline-works-without-downloaded-file
for mode in full split_ru; do
 echo "$mode" > "$d/mode"
 test -z "$(build_smart_ru_domain_rule)"
 apply_direct_nftsets
 test ! -e "$d/nftset.conf"
done
echo PASS full-and-split-mode-contracts-unchanged
