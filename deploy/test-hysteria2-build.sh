#!/bin/sh
set -eu
d="$1"
export SUB_FILE="$d/sub.json" OUT_CFG="$d/config.json" CONF="$d/absent"
export SELECTED_LINK_FILE="$d/selected" ROUTES_MODE_FILE="$d/mode"
export SMART_RU_DOMAINS_FILE="$d/absent" ALWAYS_VPN_DOMAINS_FILE="$d/absent" CUSTOM_ROUTES_FILE="$d/absent"
export HY2_BUILDER="$d/hysteria2-outbound.uc"
echo 0 > "$SELECTED_LINK_FILE"
echo split_ru > "$ROUTES_MODE_FILE"
for version in 24 25; do
 sh -n "$d/build-$version.sh"
 sh -n "$d/agent-$version.sh"
 ucode -c -o /dev/null "$d/rpc-$version.uc"
 # Extract only pure subscription helpers, never source or launch the agent.
 awk '/^(json_escape_string|base64_decode_subscription|extract_uri_links_file|write_links_json_from_lines|normalize_subscription_file)\(\)/ { emit=1 } emit { print } emit && /^}/ { emit=0 }' "$d/agent-$version.sh" > "$d/helpers.sh"
 (
  . "$d/helpers.sh"
  log() { :; }
  printf '%s\n' 'vless://test@example.com:443' 'hysteria2://test@example.com/?sni=example.com' 'hy2://test@example.com:443' > "$d/mixed"
  normalize_subscription_file "$d/mixed"
  [ "$(jsonfilter -i "$d/mixed" -e '@.subscription.links[*]' | wc -l)" -eq 3 ]
  printf '%s' 'aHkyOi8vdGVzdEBleGFtcGxlLmNvbTo0NDM=' > "$d/encoded"
  normalize_subscription_file "$d/encoded"
  [ "$(jsonfilter -i "$d/encoded" -e '@.subscription.links[0]')" = 'hy2://test@example.com:443' ]
 )
 echo "PASS mixed and base64 subscription OpenWrt$version"
 for uri in 'hysteria2://test%40auth@example.com/?sni=example.com' 'hy2://user:pass@[2001:db8::1]:8443?insecure=0' 'hy2://a@example.com?obfs=salamander&obfs-password=abc%2Bdef' 'vless://00000000-0000-0000-0000-000000000001@example.com:443?security=tls&type=tcp&sni=example.com'; do
  printf '{"subscription":{"links":["%s"]}}' "$uri" > "$SUB_FILE"
  sh "$d/build-$version.sh"
  /tmp/xray run -test -config "$OUT_CFG" >/dev/null
  echo "PASS build OpenWrt$version ${uri%%://*}"
 done
 for uri in 'hy2://a@example.com:70000' 'hy2://a@example.com?obfs=unsupported' 'hy2://a@example.com?obfs=salamander' 'hy2://bad%ZZ@example.com' 'hy2://a@example.com?insecure=maybe' 'hy2://a@example.com?insecure=1'; do
  printf '{"subscription":{"links":["%s"]}}' "$uri" > "$SUB_FILE"
  before=$(md5sum "$OUT_CFG")
  if sh "$d/build-$version.sh"; then echo 'FAIL accepted invalid URI'; exit 1; fi
  [ "$before" = "$(md5sum "$OUT_CFG")" ] || { echo 'FAIL invalid URI changed config'; exit 1; }
 done
 echo "PASS rejected invalid links without config changes OpenWrt$version"
done
