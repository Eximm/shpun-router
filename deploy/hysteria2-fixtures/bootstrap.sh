#!/bin/sh
set -eu
d="$1"
for v in ${TEST_VARIANTS:-24 25}; do
 state="$d/bootstrap-$v"
 mkdir -p "$state"
 awk '/^download_subscription_from_url_file\(\)/ { emit=1 } emit { print } emit && /^}/ { emit=0 }' "$d/agent-$v.sh" > "$state/function.sh"
 (
  . "$state/function.sh"
  unset HTTP_BIN
  log() { :; }
  detect_http_client() { HTTP_BIN=curl; }
  http_get_subscription_to_file() {
   [ "${HTTP_BIN:-}" = curl ] || return 1
   printf '%s\n' 'vless://test@example.com:443' 'hysteria2://test@example.com:443' > "$2"
  }
  normalize_subscription_file() { [ -s "$1" ]; }
  echo https://subscription.invalid > "$state/url"
  download_subscription_from_url_file "$state/out" "$state/url" direct
  grep -q '^hysteria2://' "$state/out"
 )
 echo "PASS version=$v subscription-fetch-selects-HTTP-client-on-first-start"
done
