#!/bin/sh
# Unattended validation of a shpun-router build on a live router, with
# automatic rollback. Intended for a night window while nobody uses the VPN.
#
#   Layout:  $BASE/src/{deploy,package}   files of the build under test
#   Run:     sh $BASE/src/deploy/night-validation.sh        (cron or manual)
#   Output:  $BASE/run-<stamp>/report.txt and run.log, syslog tag shpun-night
#
# Every step is gated by a tunnel health check. The router ends in its
# original routing mode and server selection. The new build stays installed
# only when no test failed; otherwise the backed-up release is restored.
# A guard process restores the router if this script dies or overruns.

BASE="${NIGHT_BASE:-/root/shpun-night}"
SRC="$BASE/src"
NEW="$SRC/package/shpun-router/files"
NEW_WIDGET_TAG="${NEW_WIDGET_TAG:-1_2_4_r1}"
DEADLINE_MIN="${NIGHT_DEADLINE_MIN:-90}"
S=/etc/shpun
STAMP="$(date +%Y%m%d-%H%M)"
OUT="$BASE/run-$STAMP"
REPORT="$OUT/report.txt"
LOG="$OUT/run.log"
BACKUP="$BASE/backup-$STAMP.tar.gz"
STATE_SAVE="$OUT/original.env"
TESTNFT=shpun_night_test
LOCK=/tmp/shpun-night.lock
PIDTRACE="$OUT/xray-pids"
MEMTRACE="$OUT/mem"
WIDGET_DIR=/www/luci-static/resources/view/status/include
WIDGET_JSON=/usr/share/luci/status/include/01_shpunvpn.json
FAILS=0
WARNS=0
INSTALLED=0

mkdir -p "$OUT" || exit 1
: > "$REPORT"

log() {
	printf '%s %s\n' "$(date +%T)" "$*" >> "$LOG"
	logger -t shpun-night "$*"
}

result() {
	printf '%-36s %-5s %s\n' "$1" "$2" "$3" >> "$REPORT"
	log "RESULT $1 $2 $3"
	case "$2" in
		FAIL) FAILS=$((FAILS + 1)) ;;
		WARN) WARNS=$((WARNS + 1)) ;;
	esac
}

note() { printf '    %s\n' "$*" >> "$REPORT"; log "  $*"; }

# --- health ---------------------------------------------------------------

xray_pid() {
	pgrep -f "xray run -config $S/xray.json" 2>/dev/null | head -n 1
}

# Real traffic through the live engine: HTTP exit IP plus an HTTPS check.
tunnel_ok() {
	local ip code
	ip="$(curl -s -m 8 -x http://127.0.0.1:10809 http://api.ipify.org 2>/dev/null)"
	case "$ip" in
		*.*.*.*) ;;
		*) ip="$(curl -s -m 8 -x http://127.0.0.1:10809 http://ifconfig.me/ip 2>/dev/null)" ;;
	esac
	case "$ip" in *.*.*.*) EXIT_IP="$ip" ;; *) return 1 ;; esac
	code="$(curl -s -m 10 -x http://127.0.0.1:10809 -o /dev/null -w '%{http_code}' https://www.google.com/generate_204 2>/dev/null)"
	[ "$code" = 204 ]
}

healthy() {
	[ -s "$S/vpn_ready" ] && [ -n "$(xray_pid)" ] && tunnel_ok
}

# wait_healthy SECONDS -> 0 when healthy; HEALTH_SECS holds the time it took
wait_healthy() {
	local limit="$1" start
	start="$(date +%s)"
	while :; do
		if healthy; then
			HEALTH_SECS=$(( $(date +%s) - start ))
			return 0
		fi
		[ $(( $(date +%s) - start )) -lt "$limit" ] || break
		sleep 5
	done
	HEALTH_SECS=$(( $(date +%s) - start ))
	return 1
}

# Background samplers: live engine PID changes (= VPN restarts) and memory.
start_samplers() {
	( while [ -e "$LOCK" ]; do
		printf '%s %s\n' "$(date +%s)" "$(xray_pid)" >> "$PIDTRACE"
		awk '/^MemAvailable:/ {print $2}' /proc/meminfo >> "$MEMTRACE"
		sleep 5
	done ) &
}

# restarts_between T0 T1: times the live engine went down or changed PID in
# the window. A restart is counted when it starts, so one that completes just
# after T1 is still seen.
restarts_between() {
	awk -v a="$1" -v b="$2" '
		$1 < a || $1 > b { next }
		NF < 2 { if (last != "" && !down) { n++; down = 1 } next }
		{ if (last != "" && $2 != last && !down) n++; down = 0; last = $2 }
		END { print n + 0 }' "$PIDTRACE"
}

# --- state ------------------------------------------------------------------

save_original() {
	{
		printf 'ORIG_MODE=%s\n' "$(cat "$S/routes/mode" 2>/dev/null || echo full)"
		printf 'ORIG_IDX=%s\n' "$(cat "$S/selected_link_index" 2>/dev/null || echo 0)"
		printf 'ORIG_AUTO=%s\n' "$(cat "$S/server_auto_select" 2>/dev/null || echo 1)"
		printf 'ORIG_EXCLUDE_RU=%s\n' "$(cat "$S/server_auto_exclude_ru" 2>/dev/null || echo 1)"
		printf 'ORIG_VERSION=%s\n' "$(cat "$S/fw_current" 2>/dev/null)"
	} > "$STATE_SAVE"
	. "$STATE_SAVE"
}

clear_selection_state() {
	rm -f "$S/auto_failover_last_attempt" "$S/auto_failover_fail_count" "$S/auto_failover_next_attempt" \
		"$S/auto_recovery_last_attempt" "$S/auto_recovery_fail_count" 2>/dev/null
}

set_mode() {
	[ "$(cat "$S/routes/mode" 2>/dev/null)" = "$1" ] && return 0
	"$S/set-routing-mode.sh" "$1" >> "$LOG" 2>&1
	[ "$(cat "$S/routes/mode" 2>/dev/null)" = "$1" ]
}

# Put the original server and auto flag back exactly as they were.
restore_selection() {
	local cur
	cur="$(cat "$S/selected_link_index" 2>/dev/null)"
	if [ "$cur" != "$ORIG_IDX" ]; then
		"$S/switch-server.sh" "$ORIG_IDX" >> "$LOG" 2>&1 || log "switch back to $ORIG_IDX failed"
	fi
	printf '%s\n' "$ORIG_AUTO" > "$S/server_auto_select"
	printf '%s\n' "$ORIG_EXCLUDE_RU" > "$S/server_auto_exclude_ru"
}

restore_original() {
	nft delete table inet "$TESTNFT" 2>/dev/null
	clear_selection_state
	set_mode "$ORIG_MODE" || log "restore mode $ORIG_MODE failed"
	restore_selection
	wait_healthy 240
}

# --- install / rollback -------------------------------------------------------

old_widget() {
	ls "$WIDGET_DIR"/01_shpunvpn_*.js 2>/dev/null | head -n 1
}

backup_release() {
	local files
	files="$S/agent.sh $S/auto-failover.sh $S/switch-server.sh $S/build-config.sh
		/usr/share/rpcd/ucode/shpun.uc /usr/share/rpcd/acl.d/shpun.json $WIDGET_JSON $(old_widget)"
	for f in $S/server-groups.uc $S/server-selection.uc; do [ -e "$f" ] && files="$files $f"; done
	# shellcheck disable=SC2086
	tar -czf "$BACKUP" $files 2>> "$LOG" || return 1
	tar -tzf "$BACKUP" > "$OUT/backup.list" || return 1
	OLD_WIDGET="$(old_widget)"
	printf 'OLD_WIDGET=%s\n' "$OLD_WIDGET" >> "$STATE_SAVE"
}

install_build() {
	local f
	for f in agent.sh auto-failover.sh switch-server.sh; do
		cp "$NEW/etc/shpun/$f" "$S/$f.night" && chmod 755 "$S/$f.night" && mv "$S/$f.night" "$S/$f" || return 1
	done
	for f in server-groups.uc server-selection.uc; do
		cp "$NEW/etc/shpun/$f" "$S/$f" && chmod 644 "$S/$f" || return 1
	done
	cp "$NEW/usr/share/rpcd/ucode/shpun.uc" /usr/share/rpcd/ucode/shpun.uc || return 1
	cp "$NEW/usr/share/rpcd/acl.d/shpun.json" /usr/share/rpcd/acl.d/shpun.json || return 1
	cp "$NEW/www/luci-static/resources/view/status/include/01_shpunvpn.js" \
		"$WIDGET_DIR/01_shpunvpn_$NEW_WIDGET_TAG.js" || return 1
	[ "$OLD_WIDGET" = "$WIDGET_DIR/01_shpunvpn_$NEW_WIDGET_TAG.js" ] || rm -f "$OLD_WIDGET"
	sed -i "s|status/include/01_shpunvpn[^\"]*|status/include/01_shpunvpn_$NEW_WIDGET_TAG|" "$WIDGET_JSON"
	sh -n "$S/agent.sh" && sh -n "$S/auto-failover.sh" && sh -n "$S/switch-server.sh" || return 1
	# Keep the background measurement from competing with the tests.
	date +%s > /tmp/shpun-selection-measured-at
	rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null
	/etc/init.d/rpcd restart
	/etc/init.d/shpun-agent restart
	INSTALLED=1
}

rollback_build() {
	log "ROLLBACK to the backed-up release"
	nft delete table inet "$TESTNFT" 2>/dev/null
	grep -q 'server-groups.uc' "$OUT/backup.list" 2>/dev/null || rm -f "$S/server-groups.uc" "$S/server-selection.uc"
	rm -f "$WIDGET_DIR/01_shpunvpn_$NEW_WIDGET_TAG.js"
	tar -xzf "$BACKUP" -C / >> "$LOG" 2>&1
	rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null
	/etc/init.d/rpcd restart
	/etc/init.d/shpun-agent restart
	INSTALLED=0
	restore_original && return 0
	/etc/init.d/shpun-vpn restart
	wait_healthy 300
}

# --- helpers for tests ----------------------------------------------------------

# ucode one-liners over JSON on stdin
jq() {
	ucode -e "import { stdin } from 'fs'; let d = json(stdin.read('all')); $1"
}

sel_wait() {
	local i=0 st
	while [ "$i" -lt 75 ]; do
		st="$(ubus call shpun server_auto_status 2>/dev/null)"
		[ "$(printf '%s' "$st" | jsonfilter -e '@.running' 2>/dev/null)" = true ] || break
		sleep 4
		i=$((i + 1))
	done
	printf '%s' "$st" | jsonfilter -e '@.status' 2>/dev/null
}

# Hosts of every transport of the server group containing index $1.
group_hosts() {
	ucode -e '
		import { readfile } from "fs";
		import { subscription_links, server_groups, link_value } from "/etc/shpun/server-groups.uc";
		let links = subscription_links(json(readfile("/etc/shpun/subscription.json")));
		let want = int(ARGV[0]), seen = {};
		for (let g in server_groups(links)) {
			if (index(g.indexes, want) < 0) continue;
			for (let i in g.indexes) {
				let a = split(substr(link_value(links[i]), index(link_value(links[i]), "://") + 3), /[\/?#]/)[0];
				a = split(a, "@"); a = split(a[length(a) - 1], ":")[0];
				if (!seen[a]) { seen[a] = true; print(a, "\n"); }
			}
		}' "$1"
}

link_host() {
	jsonfilter -i "$S/subscription.json" -e "@.subscription.links[$1]" 2>/dev/null |
		sed -E 's#^[a-z0-9]+://[^@]*@\[?([^]:/?]*).*#\1#'
}

resolve4() {
	nslookup "$1" 127.0.0.1 2>/dev/null | awk '/^Address/ && $NF !~ /#/ && $NF ~ /^[0-9.]+$/ {print $NF}'
}

block_hosts() {
	local ips="" h ip
	for h in "$@"; do
		for ip in $(resolve4 "$h"); do ips="$ips${ips:+, }$ip"; done
	done
	[ -n "$ips" ] || return 1
	nft add table inet "$TESTNFT" &&
	nft add chain inet "$TESTNFT" out "{ type filter hook output priority -10; policy accept; }" &&
	nft add rule inet "$TESTNFT" out ip daddr "{ $ips }" counter drop || return 1
	note "blocked: $* ($ips)"
	# Never leave the block behind, whatever happens to this script.
	( sleep 1200; nft delete table inet "$TESTNFT" 2>/dev/null ) &
}

unblock() { nft delete table inet "$TESTNFT" 2>/dev/null; }

# --- guard ------------------------------------------------------------------------

start_guard() {
	( deadline=$(( $(date +%s) + DEADLINE_MIN * 60 ))
	  while [ -e "$LOCK" ] && [ "$(date +%s)" -lt "$deadline" ]; do sleep 30; done
	  [ -e "$LOCK" ] || exit 0
	  logger -t shpun-night "GUARD: run exceeded ${DEADLINE_MIN} min, restoring router"
	  kill "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null
	  sleep 5
	  nft delete table inet "$TESTNFT" 2>/dev/null
	  . "$STATE_SAVE"
	  healthy && exit 0
	  [ -s "$BACKUP" ] && rollback_build
	  printf 'GUARD: run aborted after %s min; router restored\n' "$DEADLINE_MIN" >> "$REPORT"
	  rm -f "$LOCK" ) </dev/null >/dev/null 2>&1 &
}

finish() {
	local verdict
	unblock
	if [ "$FAILS" -gt 0 ] && [ "$INSTALLED" = 1 ]; then
		rollback_build && verdict="ROLLED BACK to $ORIG_VERSION" || verdict="ROLLBACK FAILED - check router"
		# Prove the restore: every backed-up file must match the archive again.
		if (cd / && tar -xzf "$BACKUP" -O 2>/dev/null | md5sum) > "$OUT/restored.sum" &&
			[ "$(cd / && tar -tzf "$BACKUP" | while read -r f; do cat "/$f"; done | md5sum)" = "$(cat "$OUT/restored.sum")" ]; then
			echo "Rollback check: restored files match the backup" >> "$REPORT"
		else
			echo "Rollback check: restored files DIFFER from the backup" >> "$REPORT"
			verdict="$verdict (file check failed)"
		fi
	elif [ "$INSTALLED" = 1 ]; then
		restore_original && verdict="NEW BUILD KEPT" || { rollback_build; verdict="ROLLED BACK (could not restore original state)"; }
	else
		restore_original; verdict="release unchanged"
	fi
	{
		echo
		echo "Memory: MemAvailable min $(sort -n "$MEMTRACE" 2>/dev/null | head -n 1) kB, max $(sort -n "$MEMTRACE" 2>/dev/null | tail -n 1) kB"
		echo "Kernel OOM events during run: $(dmesg | grep -ci 'out of memory')"
		echo "Final: mode=$(cat "$S/routes/mode") server=$(cat "$S/selected_link_index") auto=$(cat "$S/server_auto_select") healthy=$(healthy && echo yes || echo NO) exit_ip=$EXIT_IP"
		echo "SUMMARY: $FAILS failed, $WARNS warnings -> $verdict"
	} >> "$REPORT"
	log "SUMMARY: $FAILS failed, $WARNS warnings -> $verdict"
	rm -f "$LOCK"
}

# ==================================================================================

if [ -e "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
	logger -t shpun-night "another run is active"
	exit 1
fi
echo "$$" > "$LOCK"
# One-shot schedule: remove our cron line so it never repeats.
if grep -q 'night-validation.sh' /etc/crontabs/root 2>/dev/null; then
	sed -i '/night-validation.sh/d' /etc/crontabs/root
	/etc/init.d/cron restart >/dev/null 2>&1
fi
trap 'finish; exit' INT TERM

{
	echo "shpun-router night validation $STAMP on $(cat /tmp/sysinfo/model 2>/dev/null) / OpenWrt $(. /etc/openwrt_release; echo "$DISTRIB_RELEASE")"
	echo "Build under test: $(cat "$SRC/VERSION" 2>/dev/null)"
	echo
} >> "$REPORT"

save_original
start_samplers
start_guard
note "original: version=$ORIG_VERSION mode=$ORIG_MODE server=$ORIG_IDX auto=$ORIG_AUTO"

# 0. Preflight: never experiment on a router that is already broken.
if wait_healthy 120; then
	result "preflight: tunnel healthy" PASS "exit $EXIT_IP"
else
	result "preflight: tunnel healthy" FAIL "tunnel not working before tests; nothing changed"
	finish
	exit 1
fi
if [ "$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)" -lt 100000 ]; then
	result "preflight: free memory" FAIL "MemAvailable below 100 MB; nothing changed"
	finish
	exit 1
fi

# 1. Offline tests of the build (mocks only, nothing touches the live system).
for t in test-initial-server-selection.sh test-pinned-subscription-refresh.sh; do
	if (cd "$SRC" && sh "deploy/$t" > "$OUT/$t.log" 2>&1); then
		result "offline: $t" PASS ""
	else
		result "offline: $t" FAIL "$(tail -n 1 "$OUT/$t.log")"
	fi
done
if (cd "$SRC" && ucode deploy/test-server-groups.uc > "$OUT/groups.log" 2>&1); then
	result "offline: test-server-groups.uc" PASS ""
else
	result "offline: test-server-groups.uc" FAIL "$(tail -n 1 "$OUT/groups.log")"
fi
if [ "$FAILS" -gt 0 ]; then
	note "offline tests failed; not installing"
	finish
	exit 1
fi

# 2. Backup + install, with automatic rollback when the tunnel does not return.
if ! backup_release; then
	result "install: backup" FAIL "cannot create $BACKUP"
	finish
	exit 1
fi
result "install: backup" PASS "$BACKUP ($(wc -l < "$OUT/backup.list") files)"
T0="$(date +%s)"
if ! install_build; then
	result "install: copy files" FAIL "see run.log"
	finish
	exit 1
fi
if wait_healthy 300; then
	result "install: tunnel after install" PASS "${HEALTH_SECS}s, VPN restarts: $(restarts_between "$T0" "$(date +%s)")"
else
	result "install: tunnel after install" FAIL "no tunnel within 300s"
	finish
	exit 1
fi
# Rehearsal hook: prove that the automatic rollback restores the release.
if [ "${NIGHT_FORCE_FAIL:-0}" = 1 ]; then
	result "forced failure (rollback test)" FAIL "NIGHT_FORCE_FAIL=1"
	finish
	exit 1
fi

# 3. Backend API.
T0="$(date +%s)"
SG="$(ubus -t 20 call shpun servers_get 2>/dev/null)"
SG_SECS=$(( $(date +%s) - T0 ))
SG_COUNT="$(printf '%s' "$SG" | jsonfilter -e '@.count' 2>/dev/null)"
SG_PING="$(printf '%s' "$SG" | jq 'print(length(filter(d.servers, s => s.latency_ms != null)))')"
if [ "${SG_COUNT:-0}" -gt 0 ] && [ "$SG_SECS" -le 6 ]; then
	result "api: servers_get" PASS "$SG_COUNT servers, $SG_PING with ping, ${SG_SECS}s"
else
	result "api: servers_get" FAIL "count=${SG_COUNT:-none} time=${SG_SECS}s"
fi
if ubus call shpun state 2>/dev/null | jsonfilter -e '@.current_server.proto' >/dev/null; then
	result "api: state" PASS "current $(ubus call shpun state | jsonfilter -e '@.current_server.name')"
else
	result "api: state" FAIL "no current_server"
fi

# 4. Every published transport in a separate engine (live tunnel untouched).
D="$(mktemp -d /tmp/shpun-night-probe.XXXXXX)"
cp "$S/subscription.json" "$D/sub.json"
ln -s /tmp/xray "$D/shpun-probe"
N="$(jsonfilter -i "$D/sub.json" -e '@.subscription.links[*]' | wc -l)"
ok=0; bad=0; i=0
echo "    transport matrix (index proto/network host label -> result):" >> "$REPORT"
while [ "$i" -lt "$N" ]; do
	echo "$i" > "$D/index"; rm -f "$D/c.json"
	if SUB_FILE="$D/sub.json" OUT_CFG="$D/c.json" SELECTED_LINK_FILE="$D/index" "$S/build-config.sh" >/dev/null 2>&1 &&
		ucode -e 'import {readfile,writefile} from "fs"; let p=ARGV[0],c=json(readfile(p)); c.log={loglevel:"none"}; c.inbounds=[{tag:"night-http",listen:"127.0.0.1",port:18819,protocol:"http"}]; c.routing={rules:[{type:"field",inboundTag:["night-http"],outboundTag:"proxy"},{type:"field",inboundTag:["xhttp-bootstrap"],outboundTag:"direct"}]}; writefile(p,sprintf("%J",c));' "$D/c.json"; then
		"$D/shpun-probe" run -config "$D/c.json" >/dev/null 2>&1 &
		pid=$!
		w=0
		while ! grep -qE ": 0100007F:$(printf %04X 18819) 00000000:0000 0A " /proc/net/tcp && [ "$w" -lt 8 ]; do sleep 1; w=$((w + 1)); done
		r="$(curl -q -s --noproxy '' --connect-timeout 3 -m 10 -x http://127.0.0.1:18819 -o /dev/null -w '%{http_code} %{time_total}' https://www.google.com/generate_204)"
		kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
	else
		r="build-failed"
	fi
	proto="$(jsonfilter -i "$D/c.json" -e '@.outbounds[0].protocol' 2>/dev/null)/$(jsonfilter -i "$D/c.json" -e '@.outbounds[0].streamSettings.network' 2>/dev/null)"
	label="$(jsonfilter -i "$D/sub.json" -e "@.subscription.links[$i]" | sed 's/.*#//; s/%20/ /g; s/%2F/\//g; s/%[0-9A-Fa-f][0-9A-Fa-f]//g')"
	case "$r" in 204*) ok=$((ok + 1)); st=ok ;; *) bad=$((bad + 1)); st=FAIL ;; esac
	printf '      %2s %-20s %-22s %-32s %s %s\n' "$i" "$proto" "$(link_host "$i")" "$label" "$st" "$r" >> "$REPORT"
	i=$((i + 1))
done
rm -rf "$D"
if [ "$bad" -eq 0 ]; then
	result "transports: all published" PASS "$ok/$N work"
else
	result "transports: all published" WARN "$ok/$N work, $bad failed (server side; see matrix)"
fi

# 5. Measurement of all servers via RPC: no switch, no VPN restart.
clear_selection_state
T0="$(date +%s)"; before="$(cat "$S/selected_link_index")"
ubus call shpun servers_measure >/dev/null 2>&1
st="$(sel_wait)"
T1="$(date +%s)"
if [ "${st%%:*}" = measured ] && [ "$(cat "$S/selected_link_index")" = "$before" ] && [ "$(restarts_between "$T0" "$T1")" = 0 ]; then
	result "measure: all servers" PASS "$st in $((T1 - T0))s, no switch"
else
	result "measure: all servers" FAIL "status=$st selected=$(cat "$S/selected_link_index") restarts=$(restarts_between "$T0" "$T1")"
fi
REC="$(ubus call shpun servers_get 2>/dev/null | jq '
	let r = filter(d.servers, s => !s.selected && !s.ru_exit && !s.tunnel_failed && s.tunnel_ms != null);
	r = sort(r, (a, b) => a.tunnel_ms - b.tunnel_ms);
	if (length(r)) print(r[0].index, " ", r[0].id);')"

# 6. Manual choice of another country, then back to the original one.
if [ -n "$REC" ]; then
	idx="${REC%% *}"; gid="${REC#* }"
	T0="$(date +%s)"
	ubus call shpun server_set "{\"index\":$idx,\"group\":\"$gid\"}" >/dev/null 2>&1
	st="$(sel_wait)"
	if [ "${st%%:*}" = ok ] && wait_healthy 180; then
		result "manual: choose $gid" PASS "$st, exit $EXIT_IP, ${HEALTH_SECS}s, auto=$(cat "$S/server_auto_select")"
	else
		result "manual: choose $gid" FAIL "status=$st healthy=no"
	fi
else
	result "manual: choose another server" WARN "no measured alternative"
fi
clear_selection_state
restore_selection
if wait_healthy 180; then
	result "manual: back to original" PASS "server $(cat "$S/selected_link_index"), exit $EXIT_IP"
else
	result "manual: back to original" FAIL "tunnel not restored"
fi

# 7. Automatic selection: best non-RU server.
T0="$(date +%s)"
ubus call shpun server_auto_start '{"candidates":[]}' >/dev/null 2>&1
st="$(sel_wait)"
sel="$(cat "$S/selected_link_index")"
ru="$(ubus call shpun servers_get 2>/dev/null | jq "let s = filter(d.servers, s => s.selected); print(length(s) && s[0].ru_exit ? 1 : 0);")"
if [ "${st%%:*}" = ok ] && [ "$(cat "$S/server_auto_select")" = 1 ] && [ "$ru" = 0 ] && wait_healthy 180; then
	result "auto: choose best" PASS "index $sel, $(($(date +%s) - T0))s, exit $EXIT_IP"
else
	result "auto: choose best" FAIL "status=$st auto=$(cat "$S/server_auto_select") ru_exit=$ru"
fi

# 8. Auto mode failover: the current server becomes unreachable.
clear_selection_state
cur="$(cat "$S/selected_link_index")"
T0="$(date +%s)"
if block_hosts "$(link_host "$cur")"; then
	recovered=0
	while [ $(( $(date +%s) - T0 )) -lt 600 ]; do
		sleep 15
		if [ "$(cat "$S/selected_link_index")" != "$cur" ] && healthy; then recovered=1; break; fi
	done
	T1="$(date +%s)"
	unblock
	if [ "$recovered" = 1 ]; then
		result "auto: failover on dead server" PASS "$cur -> $(cat "$S/selected_link_index") in $((T1 - T0))s, restarts $(restarts_between "$T0" "$T1"), exit $EXIT_IP"
	else
		result "auto: failover on dead server" FAIL "no switch within 600s (server $(cat "$S/selected_link_index"))"
	fi
else
	result "auto: failover on dead server" WARN "could not block $(link_host "$cur")"
fi
clear_selection_state
wait_healthy 240 || { restore_selection; wait_healthy 240; }

# 9. Pinned server completely unreachable: no restart storm, recovery afterwards.
clear_selection_state
restore_selection
# Pinned mode for this check, whatever the original setting was.
echo 0 > "$S/server_auto_select"
wait_healthy 180
cur="$(cat "$S/selected_link_index")"
hosts="$(group_hosts "$cur" | tr '\n' ' ')"
T0="$(date +%s)"
# shellcheck disable=SC2086
if block_hosts $hosts; then
	sleep 480
	T1="$(date +%s)"
	n="$(restarts_between "$T0" "$T1")"
	unblock
	if [ "$(cat "$S/selected_link_index")" = "$cur" ] && [ "$n" -le 1 ]; then
		result "pinned: dead server, no storm" PASS "8 min blocked, VPN restarts $n, server kept"
	else
		result "pinned: dead server, no storm" FAIL "restarts=$n server=$(cat "$S/selected_link_index")"
	fi
	if wait_healthy 240; then
		result "pinned: recovery after outage" PASS "${HEALTH_SECS}s, exit $EXIT_IP"
	else
		clear_selection_state
		"$S/switch-server.sh" "$cur" >> "$LOG" 2>&1
		printf '%s\n' "$ORIG_AUTO" > "$S/server_auto_select"
		if wait_healthy 180; then
			result "pinned: recovery after outage" WARN "needed a manual restart"
		else
			result "pinned: recovery after outage" FAIL "tunnel did not return"
		fi
	fi
else
	result "pinned: dead server, no storm" WARN "could not block: $hosts"
fi
clear_selection_state

# 10. Routing modes (original mode is restored at the end).
for m in full smart_ru split_ru; do
	T0="$(date +%s)"
	if set_mode "$m" && wait_healthy 180; then
		case "$m" in
			split_ru) detail="ru_dst $(nft list set inet shpun ru_dst 2>/dev/null | grep -o ',' | wc -l) entries" ;;
			smart_ru) detail="direct domains in xray: $(grep -c 'domain:' "$S/xray.json")" ;;
			*) detail="" ;;
		esac
		result "mode: $m" PASS "$(( $(date +%s) - T0 ))s $detail, exit $EXIT_IP"
	else
		result "mode: $m" FAIL "mode=$(cat "$S/routes/mode") healthy=no"
	fi
done

finish
exit 0
