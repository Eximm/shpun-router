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
while [ "$#" -gt 0 ]; do
  case "$1" in
    -x) [ "$2" = http://127.0.0.1:18809 ] || exit 2; shift ;;
    -o) output="$2"; shift ;;
  esac
  shift
done
idx=$(cat "$STATE_DIR/probing")
case " $PASS_INDEXES " in *" $idx "*) ;; *) exit 1 ;; esac
[ "${CANCEL_DURING_PROBE:-0}" != 1 ] || echo 0 > "$STATE_DIR/server_auto_select"
printf 'x' > "$output"
case "$idx" in 0) echo 0.12 ;; 1) echo 0.55 ;; 2) echo 0.31 ;; 3) echo 0.22 ;; esac
MOCK
cat > "$SWITCH_SCRIPT" <<'MOCK'
#!/bin/sh
cmp -s "$SHPUN_SELECTION_SOURCE" "$STATE_DIR/subscription.json" || exit 1
printf '%s\n' "$1" > "$STATE_DIR/selected_link_index"
[ "${SHPUN_AUTO_ONE_SHOT:-0}" != 1 ] || echo 0 > "$STATE_DIR/server_auto_select"
printf '%s\n' "$1" >> "$STATE_DIR/switches"
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
chmod +x "$state/bin/"*

fails() {
	if "$@"; then echo "FAIL: unexpected success: $*" >&2; exit 1; fi
}

reset_recovery() {
	rm -f "$STATE_DIR/auto_failover_last_attempt" "$STATE_DIR/auto_failover_fail_count" \
		"$STATE_DIR/auto_failover_next_attempt" "$STATE_DIR/switches"
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
