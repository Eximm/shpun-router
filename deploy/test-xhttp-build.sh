#!/bin/sh
set -eu
d="$1"
case "$d" in /tmp/shpun-xhttp-*) ;; *) exit 64 ;; esac
test -f "$d/owned"
before_pid="$(pidof xray)"
before_config="$(sha256sum /etc/shpun/xray.json)"
export SUB_FILE="$d/sub.json" OUT_CFG="$d/config.json" CONF="$d/absent"
export SELECTED_LINK_FILE="$d/selected" ROUTES_MODE_FILE="$d/mode"
export SMART_RU_DOMAINS_FILE="$d/absent" SMART_RU_BUILTIN_DOMAINS_FILE="$d/absent"
export PROFILE_FILE="$d/absent"
export ALWAYS_VPN_DOMAINS_FILE="$d/absent" CUSTOM_ROUTES_FILE="$d/absent"
export HY2_BUILDER="$d/hysteria2-outbound.uc" XHTTP_BUILDER="$d/xhttp-outbound.uc"
echo 0 > "$SELECTED_LINK_FILE"
echo full > "$ROUTES_MODE_FILE"
ucode -c -o /dev/null "$XHTTP_BUILDER"
for v in ${2:-current}; do
  sh -n "$d/build-$v.sh"
  ucode -c -o /dev/null "$d/rpc-$v.uc"
  ucode "$d/rpc-test-$v.uc"
  while read -r n ok; do
    cp "$d/sub-$n.json" "$SUB_FILE"
    previous="$(sha256sum "$OUT_CFG" 2>/dev/null || true)"
    if sh "$d/build-$v.sh"; then
      test "$ok" = 1 || { echo "FAIL accepted $v/$n"; exit 1; }
      /tmp/xray run -test -config "$OUT_CFG" > "$d/core-test-$v-$n.log" 2>&1
      cp "$OUT_CFG" "$d/result-$v-$n.json"
    else
      test "$ok" = 0 || { echo "FAIL rejected $v/$n"; exit 1; }
      test "$previous" = "$(sha256sum "$OUT_CFG" 2>/dev/null || true)"
    fi
    echo "PASS config $v/$n expected=$ok"
  done < "$d/cases.tsv"
  for mode in full smart_ru split_ru; do
    echo "$mode" > "$ROUTES_MODE_FILE"
    for kind in xhttp tcp; do
      n=0; [ "$kind" = tcp ] && n=20
      cp "$d/sub-$n.json" "$SUB_FILE"
      sh "$d/build-$v.sh"
      /tmp/xray run -test -config "$OUT_CFG" >/dev/null 2>&1
      cp "$OUT_CFG" "$d/routing-$v-$mode-$kind.json"
    done
    echo "PASS routing config $v/$mode"
  done
done
test "$before_pid" = "$(pidof xray)"
test "$before_config" = "$(sha256sum /etc/shpun/xray.json)"
echo LAB_ACTIVE_PID_CONFIG_UNCHANGED
