#!/bin/sh
set -eu
src=${1:-$(dirname "$0")/../package/shpun-router/files/etc/shpun}
d=$(mktemp -d /tmp/shpun-portal-resume.XXXXXX)
trap 'rm -rf "$d"' EXIT
mkdir "$d/root" "$d/state" "$d/notice"
printf '#!/bin/sh\nexit 0\n' > "$d/service";chmod +x "$d/service"
cp "$src/subscription-portal-state.uc" "$d/root/"
sed "s|/tmp/shpun-subscription-portal|$d/state|g;s|/tmp/shpun-subscription-notice|$d/notice|g;s|/etc/shpun|$d/root|g;s|/etc/init.d/dnsmasq|$d/service|g;s|/etc/init.d/shpun-dns-policy|$d/service|g" "$src/subscription-portal.sh" > "$d/controller"
echo code > "$d/root/router_code";echo synthetic > "$d/root/subscription_url"
binding=$(cat "$d/root/router_code" "$d/root/subscription_url" | sha256sum | cut -d' ' -f1)
gen=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
printf '{"phase":"captive","binding":"%s","generation":"%s"}' "$binding" "$gen" > "$d/state/state.json"
printf '{"status":"active","source_available":true,"checked_at":%s,"expires_at":0}' "$(date +%s)" > "$d/notice/state.json"
for f in generation blocked profile;do echo "$gen" > "$d/state/$f";done
sh "$d/controller" reconcile
test "$(cat "$d/state/resume-pending")" = "$gen"
test ! -e "$d/state/blocked"
sh "$d/controller" reconcile
test -s "$d/state/resume-pending"
sh "$d/controller" stop
test ! -e "$d/state/resume-pending"
echo PASS actual-controller-paid-marker-release-repeat-and-stop
