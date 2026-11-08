#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
auto="$root/package/shpun-router/files/etc/shpun/auto-failover.sh"
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
mkdir "$state/bin"
export STATE_DIR="$state" AUTO_FAILOVER_LOCKDIR="$state/lock"
export ENGINE_BIN="$state/bin/engine" BUILD_SCRIPT="$state/bin/builder"
export SWITCH_SCRIPT="$state/bin/switch"
export PATH="$state/bin:$PATH"
printf '{}\n' > "$STATE_DIR/subscription.json"
printf 'TUNNEL_QUALITY_PROBE_MIN_BYTES=1\n' > "$STATE_DIR/agent.conf"
cat > "$state/bin/builder" <<'MOCK'
#!/bin/sh
idx=$(cat "$SELECTED_LINK_FILE")
printf '%s\n' "$idx" >> "$STATE_DIR/tried"
printf '%s\n' "$idx" > "$STATE_DIR/probing"
printf '{}\n' > "$OUT_CFG"
MOCK
cat > "$state/bin/ucode" <<'MOCK'
#!/bin/sh
if [ "$1" = -e ]; then
  [ "$4" = 18809 ] && [ -s "$3" ]
  exit $?
fi
case "$4:$5" in
  -:-) echo '0 1 3 2' ;;
  1:-|2:-) echo '1 2' ;;
  2:2) echo '1' ;;
  *) exit 1 ;;
esac
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
printf '%s\n' '#!/bin/sh' 'exec sleep 30' > "$ENGINE_BIN"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$state/bin/logger"
chmod +x "$state/bin/"*

echo 1 > "$STATE_DIR/server_auto_select"
PASS_INDEXES='1 2 3' sh "$auto" --initial
[ "$(cat "$STATE_DIR/tried")" = "$(printf '0\n1\n3\n2')" ]
[ "$(cat "$STATE_DIR/selected_link_index")" = 3 ]
[ "$(cat "$STATE_DIR/server_auto_select")" = 1 ]
[ ! -e "$STATE_DIR/switches" ]
[ ! -d "$AUTO_FAILOVER_LOCKDIR" ]

: > "$STATE_DIR/tried"
! PASS_INDEXES=1 sh "$auto" --initial
[ ! -s "$STATE_DIR/tried" ]
[ "$(cat "$STATE_DIR/selected_link_index")" = 3 ]

hash=$(sha256sum "$STATE_DIR/subscription.json" | awk '{print $1}')
PASS_INDEXES='0 1 2 3' sh "$auto" --choose-server 1 "$hash"
[ "$(cat "$STATE_DIR/tried")" = "$(printf '1\n2')" ]
[ "$(cat "$STATE_DIR/selected_link_index")" = 2 ]
[ "$(cat "$STATE_DIR/server_auto_select")" = 0 ]
grep -qx 'ok:2' "$STATE_DIR/auto_select_status"

: > "$STATE_DIR/tried"
PASS_INDEXES='0 1 3' sh "$auto" --recover-failed
[ "$(cat "$STATE_DIR/tried")" = 1 ]
[ "$(cat "$STATE_DIR/selected_link_index")" = 1 ]
[ "$(cat "$STATE_DIR/server_auto_select")" = 0 ]

PASS_INDEXES='0 1 2 3' sh "$auto" --choose-all
[ "$(cat "$STATE_DIR/selected_link_index")" = 0 ]
[ "$(cat "$STATE_DIR/server_auto_select")" = 1 ]
grep -qx 'ok:0' "$STATE_DIR/auto_select_status"

rm "$STATE_DIR/selected_link_index"
! PASS_INDEXES=0 CANCEL_DURING_PROBE=1 sh "$auto" --initial
[ ! -e "$STATE_DIR/selected_link_index" ]
[ ! -d "$AUTO_FAILOVER_LOCKDIR" ]
# A persistent fault can be checked again after cooldown, without
# starting a competing scan while one already holds the selection lock.
agent="$root/package/shpun-router/files/etc/shpun/agent.sh"
eval "$(sed -n '/^grouped_recovery_due() {$/,/^}$/p' "$agent")"
AUTO_FAILOVER_ENABLE=1
AUTO_FAILOVER_SCRIPT="$ENGINE_BIN"
AUTO_FAILOVER_COOLDOWN=600
date +%s > "$STATE_DIR/auto_failover_last_attempt"
! grouped_recovery_due
printf '%s\n' "$(( $(date +%s) - 601 ))" > "$STATE_DIR/auto_failover_last_attempt"
grouped_recovery_due
mkdir "$AUTO_FAILOVER_LOCKDIR"
! grouped_recovery_due
echo 'PASS initial best score, pinned recovery, global auto, cancellation and cooldown'
