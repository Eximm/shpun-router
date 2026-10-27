#!/bin/sh
# Real shell/curl-stdin integration against a fake transport; never touches production state.
set -eu
src=${1:-$(dirname "$0")/../package/shpun-router/files/etc/shpun}
d=$(mktemp -d /tmp/shpun-notice-fixture.XXXXXX)
cleanup() { case "$d" in /tmp/shpun-notice-fixture.*) test "$(readlink -f "$d")" = "$d" && rm -rf -- "$d" ;; esac; }
trap cleanup EXIT
mkdir "$d/root" "$d/bin"
echo 'https://sub.example.test/direct' > "$d/root/subscription_url"
echo 'https://sub.example.test/mirror' > "$d/root/subscription_mirror_url"
echo 9.9.9 > "$d/root/fw_current"
export SHPUN_NOTICE_ROOT="$d/root" SHPUN_NOTICE_RUNTIME="$d/runtime" SHPUN_NOTICE_HELPER="$src/subscription-notice.uc" NOTICE_FIXTURE="$d"
cat > "$d/bin/curl" <<'CURL'
#!/bin/sh
set -eu
request=$(cat)
echo request >> "$NOTICE_FIXTURE/requests"
header=''; head=0; ua=''
while [ "$#" -gt 0 ]; do
 case "$1" in --user-agent) shift;ua=$1 ;; --dump-header) shift;header=$1 ;; --head) head=1 ;; https://*|http://*) echo URL_IN_ARGV >&2;exit 1 ;; esac
 shift
done
test "$head" = 1
test "$ua" = ShpunRouter/9.9.9
mode=$(cat "$NOTICE_FIXTURE/mode")
case "$mode" in fail) exit 7 ;; mirror) case "$request" in *direct*) printf 'HTTP/2 502\r\n\r\n' > "$header";exit 0 ;; esac ;; esac
now=$(date +%s);expiry=$((now+86400))
case "$mode" in expired) expiry=$((now-100)) ;; malformed) expiry=garbage ;; unlimited) expiry=0 ;; esac
server_date=$(date -u '+%a, %d %b %Y %H:%M:%S GMT')
printf 'HTTP/2 200\r\nDate: %s\r\nsubscription-userinfo: expire=%s\r\n\r\n' "$server_date" "$expiry" > "$header"
CURL
chmod +x "$d/bin/curl"
export PATH="$d/bin:$PATH"
check() {
 rm -f "$d/runtime/state.json"
 echo "$1" > "$d/mode"
 sh "$src/subscription-notice.sh" once
 actual=$(jsonfilter -i "$d/runtime/state.json" -e '@.status')
 test "$actual" = "$2" || { echo "FAIL $1 got=$actual expected=$2";exit 1; }
 test ! -e "$d/runtime/request";test ! -e "$d/runtime/headers";test ! -e "$d/runtime/lock"
 echo "PASS observer $1=$2"
}
check expired expired
check fail unknown
check active active
check expired expired
check active active
check malformed unknown
check unlimited active
before=$(wc -l < "$d/requests");check mirror active;after=$(wc -l < "$d/requests");test "$((after-before))" = 2
mkdir "$d/runtime/lock";echo 999999 > "$d/runtime/lock/pid";check active active
before=$(wc -l < "$d/requests")
sh "$src/subscription-notice.sh" once
sh "$src/subscription-notice.sh" once
after=$(wc -l < "$d/requests");test "$before" = "$after"
echo https://sub.example.test/rebound > "$d/root/subscription_url"
sh "$src/subscription-notice.sh" once
after=$(wc -l < "$d/requests");test "$after" -eq "$((before+1))"
echo PASS shared-deadline-and-binding-change
rm "$d/root/subscription_url" "$d/root/subscription_mirror_url"
check active unknown
echo PASS expiry-renewal-outage-mirror-recovery-and-unbound-no-vpn-mutation
