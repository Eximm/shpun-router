#!/bin/sh
# Real ucode and shell transport-budget tests; all network responses are synthetic.
set -eu
root=$(pwd)
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
mkdir "$d/bin"
cat > "$d/bin/jsonfilter" <<'FILTER'
#!/usr/bin/env python3
import json,sys
args=sys.argv
value=json.load(open(args[args.index('-i')+1]))
for key in args[args.index('-e')+1].removeprefix('@.').split('.'):
 value=value.get(key) if isinstance(value,dict) else None
if value is not None: print(str(value).lower() if isinstance(value,bool) else value)
FILTER
chmod +x "$d/bin/jsonfilter"
export PATH="$d/bin:$PATH"
node deploy/test-subscription-notice.cjs prepare "$d/notice"
for f in "$d"/notice/*.json;do ucode package/shpun-router/files/etc/shpun/subscription-notice.uc < "$f" > "${f%.json}.result.json";done
node deploy/test-subscription-notice.cjs verify "$d/notice"
node deploy/test-subscription-portal.cjs prepare "$d/portal"
for f in "$d"/portal/*.json;do ucode package/shpun-router/files/etc/shpun/subscription-portal-state.uc < "$f" > "${f%.json}.result.json";done
node deploy/test-subscription-portal.cjs verify "$d/portal"
sh deploy/test-subscription-notice.sh "$root/package/shpun-router/files/etc/shpun"
