#!/bin/sh
set -eu
base=${1:-$(dirname "$0")/../package/shpun-router/files}
d=$(mktemp -d /tmp/shpun-portal-cgi.XXXXXX)
trap 'rm -rf "$d"' EXIT
mkdir "$d/state"
echo 192.168.9.1:2080 > "$d/state/authority"
echo 192.168.9.1/24 > "$d/state/network"
printf aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa > "$d/state/token"
printf '#!/bin/sh\ncat > "%s/ack"\n' "$d" > "$d/controller";chmod +x "$d/controller"
sed "s|/tmp/shpun-subscription-portal|$d/state|g;s|/etc/shpun/subscription-portal.sh|$d/controller|g" "$base/usr/share/shpun/portal/cgi-bin/index" > "$d/cgi"
request(){
 printf '%s' "$body" | env REMOTE_ADDR="$addr" HTTP_HOST="$host" REQUEST_METHOD=POST CONTENT_LENGTH="$length" HTTP_ORIGIN="$origin" sh "$d/cgi" > "$d/result"
 grep -q "Status: $wanted" "$d/result"
}
addr=192.168.9.10;host=192.168.9.1:2080;length=38
body=token=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
for origin in http://192.168.9.1:2080 '' null;do wanted=303;request;done
test "$(cat "$d/ack")" = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
rm "$d/ack"
origin=https://attacker.invalid;wanted=403;request
test ! -e "$d/ack"
origin=null;body=token=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb;wanted=403;request
test ! -e "$d/ack"
body=token=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;addr=203.0.113.2;wanted=403;request
addr=192.168.9.10;host=attacker.invalid;wanted=403;request
host=192.168.9.1:2080;length=39;wanted=400;request
test ! -e "$d/ack"
echo PASS portal-button-normal-missing-opaque-origin-and-LAN-host-token-length-guards
