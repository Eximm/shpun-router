#!/bin/sh
# Independent read-only metadata observer. Never changes subscription, binding, DNS or VPN state.
set -eu
umask 077
ROOT=${SHPUN_NOTICE_ROOT:-/etc/shpun}
RUNTIME=${SHPUN_NOTICE_RUNTIME:-/tmp/shpun-subscription-notice}
HELPER=${SHPUN_NOTICE_HELPER:-/etc/shpun/subscription-notice.uc}

sanitize() {
	ucode -e 'import {readfile} from "fs"; let p;try{p=json(readfile(ARGV[0]+"/state.json"));}catch(e){};print(sprintf("%J",{headers:readfile(ARGV[0]+"/headers")||"",previous:p,now:int(ARGV[1]),fingerprint:ARGV[2]}));' \
		"$RUNTIME" "$(date +%s)" "$fingerprint" > "$RUNTIME/request"
	ucode "$HELPER" < "$RUNTIME/request" > "$RUNTIME/next"
}

observe() {
	mkdir -p "$RUNTIME"; chmod 700 "$RUNTIME"
	# Recover the private lock after a killed observer, preserving a live owner's lock.
	if [ -s "$RUNTIME/lock/pid" ]; then
		owner=$(cat "$RUNTIME/lock/pid")
		case "$owner" in ''|*[!0-9]*) return 1 ;; esac
		if ! kill -0 "$owner" 2>/dev/null; then rm -f "$RUNTIME/lock/pid"; rmdir "$RUNTIME/lock" 2>/dev/null || true; fi
	fi
	mkdir "$RUNTIME/lock" 2>/dev/null || return 0
	printf '%s\n' "$$" > "$RUNTIME/lock/pid"
	trap 'rm -f "$RUNTIME/headers" "$RUNTIME/next" "$RUNTIME/request" "$RUNTIME/lock/pid"; rmdir "$RUNTIME/lock" 2>/dev/null || true' EXIT
	trap 'exit 130' HUP INT TERM
	url=''; fingerprint=''; valid=0
	rm -f "$RUNTIME/headers"
	for file in subscription_url subscription_mirror_url; do
		test -s "$ROOT/$file" || continue
		url=$(cat "$ROOT/$file")
		# Only an existing HTTPS source is eligible. No URL/credentials in argv, environment or logs.
		case "$url" in https://*) ;; *) continue ;; esac
		case "$url" in *'"'*|*'\'*|*"$(printf '\r')"*|*'
'*) url=''; continue ;; esac
		fingerprint=$(printf '%s' "$url" | sha256sum | cut -d' ' -f1)
		if printf 'url = "%s"\n' "$url" | curl -q -K - --head --silent --show-error \
			--proto '=https' --noproxy '*' --connect-timeout 4 --max-time 10 \
			--user-agent ShpunRouter --header 'Cache-Control: no-cache' \
			--dump-header "$RUNTIME/headers" --output /dev/null 2>/dev/null; then
			sanitize
			if [ "$(jsonfilter -i "$RUNTIME/next" -e '@.source_available')" = true ]; then valid=1; break; fi
		fi
		rm -f "$RUNTIME/headers"
	done
	unset url
	# Keep raw response headers in the private runtime only until sanitized by ucode.
	[ "$valid" = 1 ] || sanitize
	mv "$RUNTIME/next" "$RUNTIME/state.json"
}

case "${1:-once}" in
	once) observe ;;
	watch) while :; do sh "$0" once || true; sleep 300; done ;;
	*) exit 2 ;;
esac
