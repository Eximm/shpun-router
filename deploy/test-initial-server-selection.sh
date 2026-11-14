#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
auto="$root/package/shpun-router/files/etc/shpun/auto-failover.sh"
state=$(mktemp -d)
trap 'pkill -f "$state/sel." 2>/dev/null || true; rm -rf "$state"' EXIT
mkdir "$state/bin"
export STATE_DIR="$state" AUTO_FAILOVER_LOCKDIR="$state/lock"
export ENGINE_BIN="$state/bin/engine" BUILD_SCRIPT="$state/bin/builder"
export SWITCH_SCRIPT="$state/bin/switch"
export SELECTION_DIR_PREFIX="$state/sel."
export PROBE_TCP_TABLE="$state/tcp" MEMINFO_FILE="$state/meminfo"
export SELECTION_SCORES_FILE="$state/scores"
export SELECTION_PROGRESS_FILE="$state/progress" SELECTION_MEASURED_AT_FILE="$state/measured-at"
export GATEWAY_COOLDOWN_FILE="$state/gateway-cooldown" SELECTION_PROBE_GAP=0
export REALITY_BLOCK_FILE="$state/reality-blocked"
# Retrying failed direct candidates has its own scenario at the end.
export SELECTION_RETRY=0
export PATH="$state/bin:$PATH"
printf '{}\n' > "$STATE_DIR/subscription.json"
printf 'TUNNEL_QUALITY_PROBE_MIN_BYTES=1\n' > "$STATE_DIR/agent.conf"
printf 'MemAvailable:     500000 kB\n' > "$MEMINFO_FILE"
: > "$PROBE_TCP_TABLE"
cat > "$state/bin/builder" <<'MOCK'
#!/bin/sh
idx=$(cat "$SELECTED_LINK_FILE")
printf '%s\n' "$idx" >> "$STATE_DIR/tried"
printf '%s\n' "$idx" > "$STATE_DIR/probing"
printf '{}\n' > "$OUT_CFG"
MOCK
# candidates SUB ONLY SKIP FIRST EXCLUDE_RU
cat > "$state/bin/ucode" <<'MOCK'
#!/bin/sh
if [ "$1" = -e ]; then
  [ "$4" = 18809 ] && [ -s "$3" ]
  exit $?
fi
[ "$2" != representatives ] || { echo '0 1 3'; exit 0; }
# endpoints SUB: RELAY_INDEXES go through one RU gateway.
[ "$2" != endpoints ] || { for i in ${RELAY_INDEXES:-}; do
  case " ${XHTTP_INDEXES:-} " in *" $i "*) k=xhttp ;; *) k=tcp ;; esac; echo "$i gw.example 1 $k"; done; exit 0; }
case "$4:$5" in
  -:-) list='0 1 3 2' ;;
  1:-|2:-) list='1 2' ;;
  2:2) list='1' ;;
  *) exit 1 ;;
esac
first="${6:--}"
if [ "$first" != - ] && case " $list " in *" $first "*) true ;; *) false ;; esac; then
  rest=$(for i in $list; do [ "$i" = "$first" ] || printf '%s ' "$i"; done)
  list="$first $rest"
fi
echo $list
MOCK
cat > "$state/bin/curl" <<'MOCK'
#!/bin/sh
# Plain TLS handshake to the gateway address: GATEWAY_TLS is time_appconnect.
for a in "$@"; do [ "$a" != https://10.0.0.9/ ] || { echo "${GATEWAY_TLS:-0.050}"; exit 0; }; done
output= transfers=0 live=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    # 10809 is the live tunnel: it works unless LIVE_FAIL_INDEXES has the selected index.
    -x) case "$2" in http://127.0.0.1:18809) ;; http://127.0.0.1:10809) live=1 ;; *) exit 2 ;; esac; shift ;;
    # One curl may fetch several URLs on one connection: the first -o is the sample.
    -o) [ -n "$output" ] || output="$2"; transfers=$((transfers + 1)); shift ;;
  esac
  shift
done
if [ "$live" = 1 ]; then
  sel=$(cat "$STATE_DIR/selected_link_index")
  echo "$sel" >> "$STATE_DIR/live-checks"
  case " ${LIVE_FAIL_INDEXES:-} " in *" $sel "*) exit 1 ;; esac
  printf 'x' > "$output"; exit 0
fi
echo x >> "$STATE_DIR/curl-calls"
idx=$(cat "$STATE_DIR/probing")
case " $PASS_INDEXES " in *" $idx "*) ;; *) exit 1 ;; esac
[ "${CANCEL_DURING_PROBE:-0}" != 1 ] || echo 0 > "$STATE_DIR/server_auto_select"
printf 'x' > "$output"
case "$idx" in 0) t=0.12 ;; 1) t=0.55 ;; 2) t=0.31 ;; 3) t=0.22 ;; *) t=0.40 ;; esac
# -w "%{time_appconnect} %{time_starttransfer}" per transfer: the score is the
# difference; reused connections report appconnect 0.
echo "0.05 $(awk -v t="$t" 'BEGIN { print t + 0.05 }')"
n=1; while [ "$n" -lt "$transfers" ]; do echo "0 $t"; n=$((n + 1)); done
MOCK
cat > "$SWITCH_SCRIPT" <<'MOCK'
#!/bin/sh
cmp -s "$SHPUN_SELECTION_SOURCE" "$STATE_DIR/subscription.json" || exit 1
printf '%s\n' "$1" > "$STATE_DIR/selected_link_index"
[ "${SHPUN_AUTO_ONE_SHOT:-0}" != 1 ] || echo 0 > "$STATE_DIR/server_auto_select"
printf '%s\n' "$1" >> "$STATE_DIR/switches"
# The agent brings the new engine up and marks the tunnel ready.
echo 1 > "$STATE_DIR/vpn_ready"
echo ok
MOCK
# The engine publishes its listener like the kernel does and withdraws it on exit.
cat > "$ENGINE_BIN" <<'MOCK'
#!/bin/sh
[ "${ENGINE_NEVER_LISTENS:-0}" = 1 ] || echo "   1: 0100007F:4979 00000000:0000 0A 00000000:00000000 00:00000000 00000000" > "$PROBE_TCP_TABLE"
trap ': > "$PROBE_TCP_TABLE"; exit 0' TERM INT
sleep 30 &
wait
MOCK
printf '%s\n' '#!/bin/sh' 'exit 0' > "$state/bin/logger"
printf '%s\n' '#!/bin/sh' 'echo "Address: 10.0.0.9"' > "$state/bin/nslookup"
chmod +x "$state/bin/"*

fails() {
	if "$@"; then echo "FAIL: unexpected success: $*" >&2; exit 1; fi
}

reset_recovery() {
	rm -f "$STATE_DIR/auto_failover_last_attempt" "$STATE_DIR/auto_failover_fail_count" \
		"$STATE_DIR/auto_failover_next_attempt" "$STATE_DIR/switches" "$STATE_DIR/vpn_ready"
	: > "$STATE_DIR/tried"
}

# Initial selection picks the best scored connection without switching a live tunnel.
echo 1 > "$STATE_DIR/server_auto_select"
PASS_INDEXES='1 2 3' sh "$auto" --initial
[ "$(cat "$STATE_DIR/tried")" = "$(printf '0\n1\n3\n2')" ]
[ "$(cat "$STATE_DIR/selected_link_index")" = 3 ]
[ "$(cat "$STATE_DIR/server_auto_select")" = 1 ]
[ ! -e "$STATE_DIR/switches" ]
[ ! -d "$AUTO_FAILOVER_LOCKDIR" ]
[ ! -s "$PROBE_TCP_TABLE" ]

: > "$STATE_DIR/tried"
fails env PASS_INDEXES=1 sh "$auto" --initial
[ ! -s "$STATE_DIR/tried" ]
[ "$(cat "$STATE_DIR/selected_link_index")" = 3 ]

# Manual pin tests every transport of the chosen server.
hash=$(sha256sum "$STATE_DIR/subscription.json" | awk '{print $1}')
PASS_INDEXES='0 1 2 3' sh "$auto" --choose-server 1 "$hash"
[ "$(cat "$STATE_DIR/tried")" = "$(printf '1\n2')" ]
[ "$(cat "$STATE_DIR/selected_link_index")" = 2 ]
[ "$(cat "$STATE_DIR/server_auto_select")" = 0 ]
grep -qx 'ok:2' "$STATE_DIR/auto_select_status"

# Pinned recovery re-checks the current transport first, then stays inside the server.
reset_recovery
PASS_INDEXES='0 1 3' sh "$auto" --recover-failed
[ "$(cat "$STATE_DIR/tried")" = "$(printf '2\n1')" ]
[ "$(cat "$STATE_DIR/selected_link_index")" = 1 ]
[ "$(cat "$STATE_DIR/server_auto_select")" = 0 ]
[ ! -e "$STATE_DIR/auto_failover_fail_count" ]

# Nothing works: the live tunnel is left alone (no restart storm) and the
# next attempt is pushed out; an immediate retry does nothing at all.
reset_recovery
fails env PASS_INDEXES='' sh "$auto" --recover-failed
[ ! -e "$STATE_DIR/switches" ]
[ "$(cat "$STATE_DIR/auto_failover_fail_count")" = 1 ]
next=$(cat "$STATE_DIR/auto_failover_next_attempt")
[ "$((next - $(date +%s)))" -ge 590 ] && [ "$((next - $(date +%s)))" -le 600 ]
: > "$STATE_DIR/tried"
PASS_INDEXES='1 2' sh "$auto" --recover-failed
[ ! -s "$STATE_DIR/tried" ]
[ ! -e "$STATE_DIR/switches" ]

# Backoff escalates: 600, 1200, 2400 ... capped at 3600.
echo 2 > "$STATE_DIR/auto_failover_fail_count"
echo 0 > "$STATE_DIR/auto_failover_next_attempt"
fails env PASS_INDEXES='' sh "$auto" --recover-failed
next=$(cat "$STATE_DIR/auto_failover_next_attempt")
[ "$((next - $(date +%s)))" -ge 2390 ] && [ "$((next - $(date +%s)))" -le 2400 ]
echo 9 > "$STATE_DIR/auto_failover_fail_count"
echo 0 > "$STATE_DIR/auto_failover_next_attempt"
fails env PASS_INDEXES='' sh "$auto" --recover-failed
next=$(cat "$STATE_DIR/auto_failover_next_attempt")
[ "$((next - $(date +%s)))" -le 3600 ]

# The current transport works in a fresh engine: only the live engine is stuck,
# so it is restarted once on the same server.
reset_recovery
PASS_INDEXES='1' sh "$auto" --recover-failed
[ "$(head -n 1 "$STATE_DIR/tried")" = 1 ]
[ "$(cat "$STATE_DIR/switches")" = 1 ]
[ "$(cat "$STATE_DIR/selected_link_index")" = 1 ]

# Quality recovery keeps the current connection when it is still the best one.
reset_recovery
PASS_INDEXES='1' sh "$auto" --recover-quality
[ ! -e "$STATE_DIR/switches" ]

# Low memory: no probe engine is started and nothing changes.
reset_recovery
printf 'MemAvailable:      40000 kB\n' > "$MEMINFO_FILE"
fails env PASS_INDEXES='0 1 2 3' sh "$auto" --recover-failed
[ ! -e "$STATE_DIR/switches" ]
[ "$(cat "$STATE_DIR/selected_link_index")" = 1 ]
printf 'MemAvailable:     500000 kB\n' > "$MEMINFO_FILE"

# An engine that never listens fails the candidate quickly instead of hanging.
reset_recovery
started=$(date +%s)
fails env SELECTION_START_TIMEOUT=1 ENGINE_NEVER_LISTENS=1 PASS_INDEXES='0 1 2 3' sh "$auto" --recover-failed
[ "$(( $(date +%s) - started ))" -le 12 ]
[ ! -e "$STATE_DIR/switches" ]

# A probe left by a killed selector is stopped and its directory removed.
reset_recovery
mkdir "$state/sel.STALE"
ln -s "$ENGINE_BIN" "$state/sel.STALE/shpun-probe"
"$state/sel.STALE/shpun-probe" run -config "$state/sel.STALE/config.json" &
stale=$!
sleep 1
PASS_INDEXES='1 2' sh "$auto" --recover-failed
stale_state=$(awk '/^State:/ {print $2}' "/proc/$stale/status" 2>/dev/null || echo gone)
[ "$stale_state" = Z ] || [ "$stale_state" = gone ]
wait "$stale" 2>/dev/null || true
[ ! -e "$state/sel.STALE" ]

# Background measurement: one probe per server, records results, never switches.
reset_recovery
before=$(cat "$STATE_DIR/selected_link_index")
: > "$SELECTION_SCORES_FILE"
PASS_INDEXES='0 1' sh "$auto" --measure
[ "$(cat "$STATE_DIR/tried")" = "$(printf '0
1
3')" ]
[ ! -e "$STATE_DIR/switches" ]
[ "$(cat "$STATE_DIR/selected_link_index")" = "$before" ]
grep -qx 'measured:3' "$STATE_DIR/auto_select_status"
grep -q '^0 0.120 ' "$SELECTION_SCORES_FILE"
grep -q '^3 fail ' "$SELECTION_SCORES_FILE"
[ -s "$SELECTION_MEASURED_AT_FILE" ]
[ ! -e "$SELECTION_PROGRESS_FILE" ]

# Global automatic selection.
echo 0 > "$STATE_DIR/server_auto_select"
PASS_INDEXES='0 1 2 3' sh "$auto" --choose-all
[ "$(cat "$STATE_DIR/selected_link_index")" = 0 ]
[ "$(cat "$STATE_DIR/server_auto_select")" = 1 ]
grep -qx 'ok:0' "$STATE_DIR/auto_select_status"

rm "$STATE_DIR/selected_link_index"
fails env PASS_INDEXES=0 CANCEL_DURING_PROBE=1 sh "$auto" --initial
[ ! -e "$STATE_DIR/selected_link_index" ]
[ ! -d "$AUTO_FAILOVER_LOCKDIR" ]

# A persistent fault can be checked again after cooldown, without
# starting a competing scan while one already holds the selection lock.
agent="$root/package/shpun-router/files/etc/shpun/agent.sh"
eval "$(sed -n '/^grouped_recovery_due() {$/,/^}$/p' "$agent")"
AUTO_FAILOVER_ENABLE=1
AUTO_FAILOVER_SCRIPT="$ENGINE_BIN"
AUTO_FAILOVER_COOLDOWN=600
rm -f "$STATE_DIR/auto_failover_next_attempt"
date +%s > "$STATE_DIR/auto_failover_last_attempt"
fails grouped_recovery_due
printf '%s\n' "$(( $(date +%s) - 601 ))" > "$STATE_DIR/auto_failover_last_attempt"
grouped_recovery_due
# The escalated schedule written by auto-failover.sh takes precedence.
printf '%s\n' "$(( $(date +%s) + 1200 ))" > "$STATE_DIR/auto_failover_next_attempt"
fails grouped_recovery_due
printf '%s\n' "$(( $(date +%s) - 1 ))" > "$STATE_DIR/auto_failover_next_attempt"
grouped_recovery_due
mkdir "$AUTO_FAILOVER_LOCKDIR"
fails grouped_recovery_due
echo 'PASS initial, pinned/global recovery without restart storm, backoff, memory guard, stale probe cleanup, measurement'

# Relays share one RU gateway: a dead gateway is tried once and then paused,
# a live one is tried at most twice per pass; direct connections are unaffected.
rm -rf "$AUTO_FAILOVER_LOCKDIR"
# Automatic choice orders by fresh measurements; without them direct first, then relays.
reset_recovery; rm -f "$GATEWAY_COOLDOWN_FILE"; : > "$SELECTION_SCORES_FILE"
fails env RELAY_INDEXES='0 1 3' PASS_INDEXES= GATEWAY_TLS=0.000 sh "$auto" --choose-all
[ "$(cat "$STATE_DIR/tried")" = "$(printf '2\n0')" ] || { echo "FAIL: dead gateway retried: $(tr '\n' ' ' < "$STATE_DIR/tried")"; exit 1; }
grep -q '^10.0.0.9 ' "$GATEWAY_COOLDOWN_FILE"
# While paused, its relays are not touched at all.
reset_recovery
fails env RELAY_INDEXES='0 1 3' PASS_INDEXES= sh "$auto" --choose-all
[ "$(cat "$STATE_DIR/tried")" = 2 ] || { echo "FAIL: paused gateway probed: $(tr '\n' ' ' < "$STATE_DIR/tried")"; exit 1; }
# A Reality relay that left the gateway silent keeps Reality out for a day;
# XHTTP through the same gateway is tried again once the short pause is over.
grep -q '^10.0.0.9 ' "$REALITY_BLOCK_FILE"
reset_recovery; rm -f "$GATEWAY_COOLDOWN_FILE"; : > "$SELECTION_SCORES_FILE"
fails env RELAY_INDEXES='0 1 3' XHTTP_INDEXES='1' PASS_INDEXES= sh "$auto" --choose-all
[ "$(cat "$STATE_DIR/tried")" = "$(printf '2\n1')" ] || { echo "FAIL: Reality not left out: $(tr '\n' ' ' < "$STATE_DIR/tried")"; exit 1; }
# A failing XHTTP relay pauses the gateway but does not mark Reality.
reset_recovery; rm -f "$GATEWAY_COOLDOWN_FILE" "$REALITY_BLOCK_FILE"
fails env RELAY_INDEXES='0 1 3' XHTTP_INDEXES='0' PASS_INDEXES= GATEWAY_TLS=0.000 sh "$auto" --choose-all
[ ! -s "$REALITY_BLOCK_FILE" ] || { echo "FAIL: XHTTP failure marked Reality"; exit 1; }
# A live gateway: relays limited to two per pass.
reset_recovery; rm -f "$GATEWAY_COOLDOWN_FILE" "$REALITY_BLOCK_FILE"; : > "$SELECTION_SCORES_FILE"
fails env RELAY_INDEXES='0 1 3' PASS_INDEXES= GATEWAY_TLS=0.050 sh "$auto" --choose-all
[ "$(cat "$STATE_DIR/tried")" = "$(printf '2\n0\n1')" ] || { echo "FAIL: relay budget: $(tr '\n' ' ' < "$STATE_DIR/tried")"; exit 1; }
[ ! -s "$GATEWAY_COOLDOWN_FILE" ]
echo 'PASS relays through one gateway are paced, limited and paused when it stops answering'

# Relays are a reserve: never probed once a connection works, never measured
# in background, and a probe is a single curl (one upstream connection).
reset_recovery; rm -f "$GATEWAY_COOLDOWN_FILE" "$STATE_DIR/curl-calls"; : > "$SELECTION_SCORES_FILE"
RELAY_INDEXES='1 3' PASS_INDEXES='0 1 2 3' sh "$auto" --choose-all
[ "$(cat "$STATE_DIR/tried")" = "$(printf '0\n2')" ] || { echo "FAIL: relay probed although direct works: $(tr '\n' ' ' < "$STATE_DIR/tried")"; exit 1; }
[ "$(cat "$STATE_DIR/selected_link_index")" = 0 ]
[ "$(wc -l < "$STATE_DIR/curl-calls")" -eq 2 ] || { echo "FAIL: more than one request per probe: $(wc -l < "$STATE_DIR/curl-calls")"; exit 1; }
# A relay that works is kept only until a direct connection is found; other relays are skipped.
reset_recovery; : > "$SELECTION_SCORES_FILE"
RELAY_INDEXES='0 1 3' PASS_INDEXES='0 1 2 3' sh "$auto" --choose-all
[ "$(cat "$STATE_DIR/tried")" = 2 ] || { echo "FAIL: relay after relay: $(tr '\n' ' ' < "$STATE_DIR/tried")"; exit 1; }
[ "$(cat "$STATE_DIR/selected_link_index")" = 2 ] || { echo "FAIL: relay preferred over direct"; exit 1; }
reset_recovery; : > "$SELECTION_SCORES_FILE"
RELAY_INDEXES='1' PASS_INDEXES='0 1 3' sh "$auto" --measure
[ "$(cat "$STATE_DIR/tried")" = "$(printf '0\n3')" ] || { echo "FAIL: relay measured in background: $(tr '\n' ' ' < "$STATE_DIR/tried")"; exit 1; }
echo 'PASS relays are a reserve: not probed when a connection works, not measured in background, one request per probe'

# A failed direct connection is checked once more; a failed relay is not.
reset_recovery; rm -f "$GATEWAY_COOLDOWN_FILE" "$REALITY_BLOCK_FILE"; : > "$SELECTION_SCORES_FILE"
fails env SELECTION_RETRY=1 RELAY_INDEXES='3' PASS_INDEXES= sh "$auto" --choose-all
[ "$(cat "$STATE_DIR/tried")" = "$(printf '0\n0\n1\n1\n2\n2\n3')" ] || { echo "FAIL: retry: $(tr '\n' ' ' < "$STATE_DIR/tried")"; exit 1; }
echo 'PASS a failed direct connection is checked twice, a relay once'

# Manual choice connects at once with the best transport of the server (no
# private probes), verifies the live tunnel, falls back to the next transport,
# and returns to the previous connection when none works.
export SELECTION_PHASE_FILE="$state/phase"
connect_reset() {
	reset_recovery; : > "$SELECTION_SCORES_FILE"; rm -f "$STATE_DIR/live-checks"
	echo 0 > "$STATE_DIR/selected_link_index"; echo 1 > "$STATE_DIR/server_auto_select"
}
connect_reset
sh "$auto" --connect-server 1 "$hash"
[ ! -s "$STATE_DIR/tried" ] || { echo "FAIL: manual choice probed privately: $(tr '\n' ' ' < "$STATE_DIR/tried")"; exit 1; }
[ "$(cat "$STATE_DIR/switches")" = 1 ] && [ "$(cat "$STATE_DIR/live-checks")" = 1 ]
[ "$(cat "$STATE_DIR/selected_link_index")" = 1 ] && [ "$(cat "$STATE_DIR/server_auto_select")" = 0 ]
grep -qx 'ok:1' "$STATE_DIR/auto_select_status"; grep -qx 'done 1' "$SELECTION_PHASE_FILE"
connect_reset
LIVE_FAIL_INDEXES=1 sh "$auto" --connect-server 1 "$hash"
[ "$(tr '\n' ' ' < "$STATE_DIR/switches")" = '1 2 ' ] || { echo "FAIL: next transport: $(tr '\n' ' ' < "$STATE_DIR/switches")"; exit 1; }
grep -qx 'ok:2' "$STATE_DIR/auto_select_status"
connect_reset
fails env LIVE_FAIL_INDEXES='1 2' sh "$auto" --connect-server 1 "$hash"
[ "$(tr '\n' ' ' < "$STATE_DIR/switches")" = '1 2 0 ' ] || { echo "FAIL: revert: $(tr '\n' ' ' < "$STATE_DIR/switches")"; exit 1; }
[ "$(cat "$STATE_DIR/selected_link_index")" = 0 ] && [ "$(cat "$STATE_DIR/server_auto_select")" = 1 ]
grep -qx 'failed:0' "$STATE_DIR/auto_select_status"; grep -q '^failed' "$SELECTION_PHASE_FILE"
echo 'PASS manual choice connects at once, falls back to the next transport and reverts when none works'

# Automatic choice with fresh measurements re-checks the best ones first and
# stops after three direct passes; the live tunnel is verified after the switch.
connect_reset
now=$(date +%s)
printf '0 0.120 %s\n1 0.550 %s\n2 0.310 %s\n3 0.220 %s\n' "$now" "$now" "$now" "$now" > "$SELECTION_SCORES_FILE"
PASS_INDEXES='0 1 2 3' LIVE_FAIL_INDEXES=0 sh "$auto" --choose-all
[ "$(tr '\n' ' ' < "$STATE_DIR/tried")" = '0 3 2 ' ] || { echo "FAIL: early stop: $(tr '\n' ' ' < "$STATE_DIR/tried")"; exit 1; }
[ "$(tr '\n' ' ' < "$STATE_DIR/switches")" = '0 3 ' ] || { echo "FAIL: live check fallback: $(tr '\n' ' ' < "$STATE_DIR/switches")"; exit 1; }
[ "$(cat "$STATE_DIR/selected_link_index")" = 3 ] && [ "$(cat "$STATE_DIR/server_auto_select")" = 1 ]
grep -qx 'ok:3' "$STATE_DIR/auto_select_status"
echo 'PASS automatic choice checks the best measured first, stops early and verifies the live tunnel'
