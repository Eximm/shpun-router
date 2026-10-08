#!/bin/sh
set -eu
d="$1"
for v in ${TEST_VARIANTS:-24 25}; do
 state="$d/guard-$v"
 mkdir -p "$state/init"
 sed "s#/etc/shpun/#$state/#g; s#/etc/init.d/#$state/init/#g" "$d/switch-$v.sh" > "$state/switch.sh"
 printf '#!/bin/sh\nexit 1\n' > "$state/unsupported-engine"
 printf '#!/bin/sh\ncat > "$OUT_CFG" <<EOF\n{\n "inbounds": [],\n "outbounds": [{"protocol":"hysteria"}]\n}\nEOF\n' > "$state/build-config.sh"
 chmod +x "$state/unsupported-engine" "$state/build-config.sh"
 printf 'ENGINE_BIN="%s/unsupported-engine"\nENGINE_CONFIG="%s/xray.json"\nSWITCH_SERVER_VALIDATE=0\n' "$state" "$state" > "$state/agent.conf"
 echo 0 > "$state/selected_link_index"
 echo 1 > "$state/server_auto_select"
 echo unchanged-live-config > "$state/xray.json"
 echo ready > "$state/vpn_ready"
 before=$(sha256sum "$state/xray.json" "$state/selected_link_index" "$state/server_auto_select" "$state/vpn_ready")
 set +e
 result=$(AUTO_FAILOVER_LOCKDIR="$state/selection.lock" CONFIG_LOCKDIR="$state/config.lock" sh "$state/switch.sh" 1)
 rc=$?
 set -e
 [ "$rc" -ne 0 ] && [ "$result" = config_invalid ]
 [ "$before" = "$(sha256sum "$state/xray.json" "$state/selected_link_index" "$state/server_auto_select" "$state/vpn_ready")" ]
 [ ! -d "$state/selection.lock" ] && [ ! -d "$state/config.lock" ]
 echo "PASS version=$v unsupported-Hysteria-engine-keeps-live-Reality-even-validation-OFF"
 # Real-engine positive path catches config format detection regressions.
 if [ -x /tmp/xray ]; then
  printf '#!/bin/sh\nexec /tmp/xray "$@"\n' > "$state/unsupported-engine"
  printf '#!/bin/sh\nexit 0\n' > "$state/init/shpun-agent"
  chmod +x "$state/init/shpun-agent"
  cat > "$state/build-config.sh" <<'BUILDER'
#!/bin/sh
cat > "$OUT_CFG" <<'CONFIG'
{
 "inbounds": [],
 "outbounds": [{"tag":"proxy","protocol":"hysteria","settings":{"version":2,"address":"example.com","port":443},"streamSettings":{"network":"hysteria","security":"tls","tlsSettings":{"serverName":"example.com"},"hysteriaSettings":{"version":2,"auth":"test"}}}]
}
CONFIG
BUILDER
  result=$(AUTO_FAILOVER_LOCKDIR="$state/selection.lock" CONFIG_LOCKDIR="$state/config.lock" sh "$state/switch.sh" 1)
  [ "$result" = ok ]
  [ "$(cat "$state/selected_link_index")" = 1 ]
  [ "$(cat "$state/server_auto_select")" = 0 ]
  echo "PASS version=$v real-Hysteria-engine-validation-format-and-manual-Auto-OFF"
 fi
done
