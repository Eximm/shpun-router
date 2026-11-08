#!/bin/sh

STATE_DIR="${STATE_DIR:-/etc/shpun}"
CONF="${CONF:-$STATE_DIR/agent.conf}"
SUB_FILE="${SUB_FILE:-$STATE_DIR/subscription.json}"
SELECTED_LINK_FILE="${SELECTED_LINK_FILE:-$STATE_DIR/selected_link_index}"
SWITCH_SCRIPT="${SWITCH_SCRIPT:-$STATE_DIR/switch-server.sh}"
BUILD_SCRIPT="${BUILD_SCRIPT:-$STATE_DIR/build-config.sh}"
ENGINE_BIN="${ENGINE_BIN:-/tmp/xray}"
VPN_READY_FILE="${VPN_READY_FILE:-$STATE_DIR/vpn_ready}"
LAST_ATTEMPT_FILE="$STATE_DIR/auto_failover_last_attempt"
# Grouped recovery backs off after every attempt that found nothing better:
# COOLDOWN, 2x, 4x ... capped at AUTO_FAILOVER_MAX_COOLDOWN. The agent reads
# NEXT_ATTEMPT_FILE and clears both files once the tunnel probe succeeds.
FAIL_COUNT_FILE="$STATE_DIR/auto_failover_fail_count"
NEXT_ATTEMPT_FILE="$STATE_DIR/auto_failover_next_attempt"
SELECTION_DIR_PREFIX="${SELECTION_DIR_PREFIX:-/tmp/shpun-selection.}"
PROBE_TCP_TABLE="${PROBE_TCP_TABLE:-/proc/net/tcp}"
SCORES_FILE="${SELECTION_SCORES_FILE:-/tmp/shpun-selection-scores}"
PROGRESS_FILE="${SELECTION_PROGRESS_FILE:-/tmp/shpun-selection-progress}"
MEASURED_AT_FILE="${SELECTION_MEASURED_AT_FILE:-/tmp/shpun-selection-measured-at}"
MEMINFO_FILE="${MEMINFO_FILE:-/proc/meminfo}"
LAST_SUCCESS_FILE="$STATE_DIR/auto_failover_last_success"
FROM_FILE="$STATE_DIR/auto_failover_from"
AUTO_SELECT_STATUS_FILE="$STATE_DIR/auto_select_status"
SERVER_AUTO_SELECT_FILE="$STATE_DIR/server_auto_select"
SERVER_AUTO_EXCLUDE_RU_FILE="$STATE_DIR/server_auto_exclude_ru"
VERROR_FILE="$STATE_DIR/vpn_error"
LOCKDIR="${AUTO_FAILOVER_LOCKDIR:-/tmp/shpun-auto-failover.lock}"
LOGTAG="shpun-failover"

AUTO_FAILOVER_COOLDOWN_DEFAULT=600
AUTO_FAILOVER_MAX_CANDIDATES_DEFAULT=16
AUTO_FAILOVER_READY_TIMEOUT_DEFAULT=30
AUTO_FAILOVER_MAX_COOLDOWN_DEFAULT=3600
# A probe Xray needs ~30 MB RSS next to the live one; never start it when the
# router could be pushed into OOM or a watchdog reset.
SELECTION_MIN_AVAILABLE_KB_DEFAULT=65536
SELECTION_PROBE_PORT_DEFAULT=18809
# Seconds to wait for the probe engine listener; slow MIPS CPUs need several.
SELECTION_START_TIMEOUT_DEFAULT=8
HTTP_PROXY_PORT_DEFAULT=10809
TUNNEL_PROBE_URL_DEFAULT="http://api.ipify.org"
TUNNEL_PROBE_FALLBACK_URL_DEFAULT="http://cp.cloudflare.com/generate_204"
TUNNEL_PROBE_SECONDARY_URL_DEFAULT="http://connectivitycheck.gstatic.com/generate_204"
TUNNEL_QUALITY_PROBE_URL_DEFAULT="https://speed.cloudflare.com/__down?bytes=8192"
TUNNEL_QUALITY_PROBE_MIN_BYTES_DEFAULT=8192
TUNNEL_QUALITY_CONFIRM_URLS_DEFAULT="https://telegram.org/ https://connectivitycheck.gstatic.com/generate_204 https://www.cloudflare.com/cdn-cgi/trace"
TUNNEL_QUALITY_CONFIRM_MIN_SUCCESS_DEFAULT=2

log() {
	logger -t "$LOGTAG" "$*"
}

lock_acquire() {
	i=0
	while ! mkdir "$LOCKDIR" 2>/dev/null; do
		lock_pid="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
		case "$lock_pid" in
			''|*[!0-9]*) ;;
			*) kill -0 "$lock_pid" 2>/dev/null && return 1 ;;
		esac
		rm -f "$LOCKDIR/pid" 2>/dev/null
		rmdir "$LOCKDIR" 2>/dev/null || true
		i=$((i + 1))
		[ "$i" -ge 2 ] && return 1
	done

	echo "$$" > "$LOCKDIR/pid"
	trap 'rm -f "$LOCKDIR/pid" 2>/dev/null; rmdir "$LOCKDIR" 2>/dev/null' EXIT INT TERM
	return 0
}

detect_http_client() {
	if command -v curl >/dev/null 2>&1; then
		HTTP_BIN="curl"
	elif command -v uclient-fetch >/dev/null 2>&1; then
		HTTP_BIN="uclient-fetch"
	elif command -v wget >/dev/null 2>&1; then
		HTTP_BIN="wget"
	else
		HTTP_BIN=""
	fi
}

# Read both string and object link forms accepted by the config builder.
subscription_link() {
	local idx="$1" base suffix value
	for base in "@.subscription.links[$idx]" "@.links[$idx]"; do
		for suffix in "" ".url" ".link" ".uri" ".vless" ".hysteria2" ".hy2"; do
			value="$(jsonfilter -i "$SUB_FILE" -e "${base}${suffix}" 2>/dev/null | head -n 1 | tr -d '\r\n')"
			case "$value" in
				vless://*|hysteria2://*|hy2://*) printf '%s\n' "$value"; return 0 ;;
			esac
		done
	done
	return 1
}

# Classify a subscription link into the same "Через РФ" / "Напрямую"
# groups the LuCI widget uses (see getServerConnectionGroup in 01_shpunvpn.js).
# Keep this classification aligned with server_group() in shpun.uc and
# getServerConnectionGroup() in LuCI. Returns gateway|direct.
link_group() {
	link="$1"
	rest="${link#*://}"
	rest="${rest#*@}"
	host="${rest%%:*}"
	host="${host%%\?*}"
	host="${host%%#*}"
	host="$(printf '%s' "$host" | tr 'A-Z' 'a-z' 2>/dev/null || printf '%s' "$host")"
	frag="${link#*#}"
	frag="${frag%%\?*}"
	name="$(printf '%s' "$frag" | sed 's/%20/ /g; s/+/ /g' 2>/dev/null || printf '%s' "$frag")"
	name_l="$(printf '%s' "$name" | tr 'A-Z' 'a-z' 2>/dev/null || printf '%s' "$name")"
	case "$name_l" in
		*"напрямую"*|*"Напрямую"*|*"НАПРЯМУЮ"*|*"%d0%bd%d0%b0%d0%bf%d1%80%d1%8f%d0%bc%d1%83%d1%8e"*) echo direct; return ;;
	esac
	case "$name_l" in
		*"через рф"*|*"Через РФ"*|*"ЧЕРЕЗ РФ"*|*"%d1%87%d0%b5%d1%80%d0%b5%d0%b7"*"%d1%80%d1%84"*|*"%d0%a7%d0%b5%d1%80%d0%b5%d0%b7"*"%d0%a0%d0%a4"*) echo gateway; return ;;
	esac
	case "$host" in
		rush*.lenivo.site)
			mid="${host#rush}"
			mid="${mid%.lenivo.site}"
			case "$mid" in
				*[!0-9]*) ;;
				*) echo gateway; return ;;
			esac
			;;
	esac
	echo direct
}

# Watchdog cancellation: re-read the persistent toggle before each candidate.
# Only applies to the background watchdog (MANUAL_SELECT=0). The explicit
# "Найти лучший сервер" operation (MANUAL_SELECT=1) is never cancelled by the
# toggle because it was started manually by the user. Returns 0 = still
# enabled, 1 = disabled (abort watchdog).
auto_select_still_enabled() {
	[ "$MANUAL_SELECT" -eq 1 ] && return 0
	val="$(cat "$SERVER_AUTO_SELECT_FILE" 2>/dev/null | tr -d '\r\n ' || true)"
	case "$val" in
		0|no|false|off) return 1 ;;
		*) return 0 ;;
	esac
}

probe_time_limit() {
	local limit="$1" remaining
	if [ -n "$INITIAL_DEADLINE" ]; then
		remaining=$((INITIAL_DEADLINE - $(date +%s)))
		[ "$remaining" -gt 0 ] || return 1
		[ "$remaining" -ge "$limit" ] || limit="$remaining"
	fi
	printf '%s\n' "$limit"
}

probe_url_through_tunnel() {
	local limit
	limit="$(probe_time_limit 6)" || return 1
	url="$1"
	proxy="http://127.0.0.1:${HTTP_PROXY_PORT}"

	case "$HTTP_BIN" in
		curl)
			curl -fsS -A ShpunRouter -m "$limit" -x "$proxy" -o /dev/null "$url" >/dev/null 2>&1
			;;
		uclient-fetch)
			env http_proxy="$proxy" HTTP_PROXY="$proxy" \
				uclient-fetch -q -U ShpunRouter -T "$limit" -Y on -O /dev/null "$url" >/dev/null 2>&1
			;;
		wget)
			env http_proxy="$proxy" HTTP_PROXY="$proxy" \
				wget -q -U ShpunRouter -T "$limit" -Y on -O /dev/null "$url" >/dev/null 2>&1
			;;
		*) return 1 ;;
	esac
}

probe_tunnel_quality_transfer() {
	local limit
	limit="$(probe_time_limit 8)" || return 1
	proxy="http://127.0.0.1:${HTTP_PROXY_PORT}"
	tmp="/tmp/shpun-failover-quality.$$"
	[ "$HTTP_BIN" = "curl" ] || return 0
	rm -f "$tmp"

	if ! curl -fsSL -A ShpunRouter -m "$limit" -x "$proxy" -o "$tmp" "$TUNNEL_QUALITY_PROBE_URL" >/dev/null 2>&1; then
		rm -f "$tmp"
		return 1
	fi

	bytes="$(wc -c < "$tmp" 2>/dev/null | tr -d ' ')"
	rm -f "$tmp"
	case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
	[ "$bytes" -ge "$TUNNEL_QUALITY_PROBE_MIN_BYTES" ]
}

probe_tunnel_quality() {
	probe_tunnel_quality_transfer && return 0

	success=0
	total=0
	for quality_url in $TUNNEL_QUALITY_CONFIRM_URLS; do
		[ -n "$quality_url" ] || continue
		total=$((total + 1))
		if probe_url_through_tunnel "$quality_url"; then
			success=$((success + 1))
			[ "$success" -ge "$TUNNEL_QUALITY_CONFIRM_MIN_SUCCESS" ] && return 0
		fi
	done

	log "candidate quality confirmation failed (${success}/${total} HTTPS probes succeeded)"
	return 1
}

probe_tunnel() {
	if ! probe_url_through_tunnel "$TUNNEL_PROBE_URL" &&
		! probe_url_through_tunnel "$TUNNEL_PROBE_FALLBACK_URL" &&
		! probe_url_through_tunnel "$TUNNEL_PROBE_SECONDARY_URL"; then
		return 1
	fi
	probe_tunnel_quality
}

wait_for_candidate() {
	waited=0
	while [ "$waited" -lt "$AUTO_FAILOVER_READY_TIMEOUT" ]; do
		[ -s "$VPN_READY_FILE" ] && break
		sleep 2
		waited=$((waited + 2))
	done
	[ -s "$VPN_READY_FILE" ] || return 1
	probe_tunnel
}

switch_to() {
	index="$1"
	if [ "$MANUAL_SELECT" -eq 1 ] || [ "${2:-}" = pin ]; then
		result="$(SHPUN_AUTO_FAILOVER=1 SHPUN_AUTO_ONE_SHOT=1 "$SWITCH_SCRIPT" "$index" 2>/dev/null)"
	else
		result="$(SHPUN_AUTO_FAILOVER=1 "$SWITCH_SCRIPT" "$index" 2>/dev/null)"
	fi
	switch_rc="$?"
	[ "$switch_rc" -eq 0 ] || {
		log "server index $index rejected during automatic failover: ${result:-switch_failed}"
		return 1
	}
	[ "$result" = "ok" ] || {
		log "server index $index rejected during automatic failover: ${result:-unknown_error}"
		return 1
	}
	return 0
}

# Probe generated outbounds privately before changing the active tunnel.
stop_selection_probe() {
	if [ -n "$probe_pid" ]; then
		kill "$probe_pid" 2>/dev/null || true
		wait "$probe_pid" 2>/dev/null || true
		probe_pid=
	fi
}

cleanup_group_selection() {
	stop_selection_probe
	[ -z "$selection_tmp" ] || rm -f "$selection_tmp"
	if [ -n "$probe_dir" ]; then
		rm -f "$probe_dir/index" "$probe_dir/config.json" "$probe_dir/subscription.json" \
			"$probe_dir/shpun-probe" "$probe_dir/sample"
		rmdir "$probe_dir" 2>/dev/null || true
	fi
	if [ "$interactive" = 1 ] && [ "$(cat "$AUTO_SELECT_STATUS_FILE" 2>/dev/null)" = running ]; then
		printf 'failed:%s\n' "$current" > "$AUTO_SELECT_STATUS_FILE"
	fi
	rm -f "$PROGRESS_FILE"
	rm -f "$LOCKDIR/pid"
	rmdir "$LOCKDIR" 2>/dev/null || true
}

write_selection_value() {
	local path="$1" value="$2"
	selection_tmp="$(mktemp "${path}.candidate.XXXXXX")" || return 1
	printf '%s\n' "$value" > "$selection_tmp" && mv "$selection_tmp" "$path" || return 1
	selection_tmp=
}

selection_is_current() {
	[ ! -s /tmp/shpun-subscription-portal/blocked ] || return 1
	cmp -s "$SUB_FILE" "$probe_dir/subscription.json" || return 1
	[ "$(cat "$SELECTED_LINK_FILE" 2>/dev/null || true)" = "$old_selection" ] || return 1
	[ "$(cat "$SERVER_AUTO_SELECT_FILE" 2>/dev/null || true)" = "$old_mode" ]
}

selection_curl() {
	local limit
	limit="$(probe_time_limit "$1")" || return 1
	shift
	curl -q -fsS --noproxy '' --connect-timeout 2 -m "$limit" \
		-x "http://127.0.0.1:$HTTP_PROXY_PORT" "$@" 2>/dev/null
}

short_pause() {
	usleep 200000 2>/dev/null || sleep 1
}

# Kill probe engines and remove probe directories left by a killed selector.
# Only called while holding the selection lock, so nothing here is live.
cleanup_stale_probes() {
	local cmd pid dir line killed=0
	for cmd in /proc/[0-9]*/cmdline; do
		pid="${cmd#/proc/}"
		pid="${pid%/cmdline}"
		[ "$pid" != "$$" ] || continue
		line="$(tr '\000' ' ' < "$cmd" 2>/dev/null)" || continue
		case "$line" in
			*"${SELECTION_DIR_PREFIX}"*"/shpun-probe run "*) ;;
			*) continue ;;
		esac
		kill "$pid" 2>/dev/null && { killed=1; log "stopped stale selection probe pid $pid"; }
	done
	# Give the killed engine a moment to release the probe port.
	[ "$killed" = 0 ] || sleep 1
	for dir in "${SELECTION_DIR_PREFIX}"*; do
		[ -d "$dir" ] && [ ! -L "$dir" ] || continue
		rm -f "$dir/index" "$dir/config.json" "$dir/subscription.json" "$dir/shpun-probe" "$dir/sample"
		rmdir "$dir" 2>/dev/null || true
	done
}

# 0 when something listens on 127.0.0.1:PORT (TCP LISTEN state 0A).
probe_port_listening() {
	local hex
	hex="$(printf '%04X' "$1")"
	grep -qE "^ *[0-9]+: 0100007F:${hex} 00000000:0000 0A " "$PROBE_TCP_TABLE" 2>/dev/null
}

wait_probe_port() {
	local stop_at
	stop_at=$(( $(date +%s) + SELECTION_START_TIMEOUT ))
	while [ "$(date +%s)" -le "$stop_at" ]; do
		kill -0 "$probe_pid" 2>/dev/null || return 1
		probe_port_listening "$HTTP_PROXY_PORT" && return 0
		[ "$(probe_time_limit 1)" ] || return 1
		short_pause
	done
	return 1
}

mem_available_kb() {
	awk '/^MemAvailable:/ {print $2; found=1} END {if (!found) print 0}' "$MEMINFO_FILE" 2>/dev/null
}

selection_memory_ok() {
	local avail
	avail="$(mem_available_kb)"
	case "$avail" in ''|*[!0-9]*) avail=0 ;; esac
	[ "$avail" -ge "$SELECTION_MIN_AVAILABLE_KB" ] && return 0
	log "selection probe skipped: MemAvailable ${avail}kB < ${SELECTION_MIN_AVAILABLE_KB}kB"
	return 1
}

# Escalating pause between grouped recovery attempts that changed nothing.
schedule_next_attempt() {
	local now="$1" fails delay shift_n
	fails="$(cat "$FAIL_COUNT_FILE" 2>/dev/null | tr -d '\r\n ' || true)"
	case "$fails" in ''|*[!0-9]*) fails=0 ;; esac
	shift_n="$fails"
	[ "$shift_n" -le 6 ] || shift_n=6
	delay=$((AUTO_FAILOVER_COOLDOWN << shift_n))
	[ "$delay" -le "$AUTO_FAILOVER_MAX_COOLDOWN" ] || delay="$AUTO_FAILOVER_MAX_COOLDOWN"
	printf '%s\n' "$((fails + 1))" > "$FAIL_COUNT_FILE" 2>/dev/null || true
	printf '%s\n' "$((now + delay))" > "$NEXT_ATTEMPT_FILE" 2>/dev/null || true
	log "next grouped recovery attempt in ${delay}s (attempt $((fails + 1)))"
}

# Remember per-connection results for the LuCI server list (RAM only).
record_score() {
	local file="$SCORES_FILE" tmp
	tmp="$(mktemp "${file}.XXXXXX")" || return 0
	{ grep -v "^$1 " "$file" 2>/dev/null | tail -n 199; printf '%s %s %s\n' "$1" "$2" "$(date +%s)"; } > "$tmp"
	mv "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
}

clear_recovery_backoff() {
	rm -f "$FAIL_COUNT_FILE" "$NEXT_ATTEMPT_FILE" 2>/dev/null || true
}

recovery_due() {
	local now="$1" next last
	next="$(cat "$NEXT_ATTEMPT_FILE" 2>/dev/null | tr -d '\r\n ' || true)"
	case "$next" in
		''|*[!0-9]*) ;;
		*)
			# A clock jump backwards must not freeze recovery for hours.
			[ "$((next - now))" -le "$AUTO_FAILOVER_MAX_COOLDOWN" ] || return 0
			[ "$now" -ge "$next" ]
			return
			;;
	esac
	last="$(cat "$LAST_ATTEMPT_FILE" 2>/dev/null || true)"
	case "$last" in ''|*[!0-9]*) last=0 ;; esac
	[ "$last" -eq 0 ] || [ "$now" -lt "$last" ] || [ "$((now-last))" -ge "$AUTO_FAILOVER_COOLDOWN" ]
}

candidate_score() {
	local elapsed url successes=0 sum=0
	elapsed="$(selection_curl 4 -L -o "$probe_dir/sample" -w '%{time_total}' "$TUNNEL_QUALITY_PROBE_URL")" &&
		[ "$(wc -c < "$probe_dir/sample")" -ge "$TUNNEL_QUALITY_PROBE_MIN_BYTES" ] &&
		{ printf '%s\n' "$elapsed"; return 0; }

	# Confirm connectivity independently if the download endpoint is unavailable.
	for url in $TUNNEL_QUALITY_CONFIRM_URLS; do
		elapsed="$(selection_curl 2 -o /dev/null -w '%{time_total}' "$url")" || continue
		sum="$(awk -v a="$sum" -v b="$elapsed" 'BEGIN {print a+b}')"
		successes=$((successes + 1))
		if [ "$successes" -ge "$TUNNEL_QUALITY_CONFIRM_MIN_SUCCESS" ]; then
			awk -v sum="$sum" -v count="$successes" 'BEGIN {print 10+sum/count}'
			return 0
		fi
	done
	return 1
}

probe_candidate() {
	local candidate="$1" score
	printf '%s\n' "$candidate" > "$probe_dir/index" || return 1
	rm -f "$probe_dir/config.json"
	SUB_FILE="$probe_dir/subscription.json" OUT_CFG="$probe_dir/config.json" \
		SELECTED_LINK_FILE="$probe_dir/index" "$BUILD_SCRIPT" || return 1
	[ "$(cat "$probe_dir/index")" = "$candidate" ] || return 1
	# Preserve the actual outbound and XHTTP endpoint DNS. Force HTTPS
	# probes through the candidate regardless of the user's LAN presets.
	ucode -e '
		import { readfile, writefile } from "fs";
		let p = ARGV[0], c = json(readfile(p));
		c.inbounds = [{ tag: "selection-http", listen: "127.0.0.1", port: int(ARGV[1]), protocol: "http" }];
		c.routing = { rules: [
			{ type: "field", inboundTag: ["selection-http"], outboundTag: "proxy" },
			{ type: "field", inboundTag: ["xhttp-bootstrap"], outboundTag: "direct" }
		] };
		exit(writefile(p, sprintf("%J", c)) ? 0 : 1);
	' "$probe_dir/config.json" "$HTTP_PROXY_PORT" >/dev/null 2>&1 || return 1
	selection_memory_ok || return 2
	if probe_port_listening "$HTTP_PROXY_PORT"; then
		log "selection probe port $HTTP_PROXY_PORT is busy"
		return 2
	fi
	"$probe_dir/shpun-probe" run -config "$probe_dir/config.json" >/dev/null 2>&1 &
	probe_pid=$!
	# Wait for the real listener instead of a fixed delay: slow CPUs need
	# several seconds to start Xray and would otherwise fail every candidate.
	if ! wait_probe_port; then
		stop_selection_probe
		return 1
	fi
	# Two transfers: a single sample is too noisy to call a transport stable.
	local first second
	if first="$(candidate_score)" && kill -0 "$probe_pid" 2>/dev/null &&
		second="$(candidate_score)" && kill -0 "$probe_pid" 2>/dev/null; then
		stop_selection_probe
		SCORE="$(awk -v a="$first" -v b="$second" 'BEGIN {printf "%.3f", (a+b)/2}')"
		return 0
	fi
	stop_selection_probe
	return 1
}

select_grouped_server() {
	local only=- skip=- first=- exclude_ru=0 candidates candidate tried=0 best= best_score= score
	local old_selection old_mode expected_hash limit now recovering=0 deadline=75 probe_rc low_memory=0 measuring=0 total
	old_selection="$(cat "$SELECTED_LINK_FILE" 2>/dev/null || true)"
	old_mode="$(cat "$SERVER_AUTO_SELECT_FILE" 2>/dev/null || true)"
	current="$old_selection"
	case "$current" in ''|*[!0-9]*) current=0 ;; esac
	probe_pid= probe_dir= selection_tmp=
	trap cleanup_group_selection EXIT
	trap 'exit 1' INT TERM
	[ "$HTTP_BIN" = curl ] && [ -x "$ENGINE_BIN" ] && [ -x "$BUILD_SCRIPT" ] || return 1
	[ ! -s /tmp/shpun-subscription-portal/blocked ] || return 1

	case "$GROUP_ACTION" in
		--initial)
			[ ! -s "$VPN_READY_FILE" ] && [ ! -e "$SELECTED_LINK_FILE" ] && auto_select_still_enabled || return 1
			exclude_ru=1
			deadline=40
			;;
		--choose-all)
			exclude_ru=1
			;;
		--measure)
			# Refresh the VPN time of every server for the LuCI list; never switches.
			measuring=1
			deadline=150
			;;
		--choose-server)
			only="$1"
			case "$only" in ''|*[!0-9]*) return 1 ;; esac
			expected_hash="$2"
			;;
		--recover-quality|--recover-failed)
			now="$(date +%s)"
			recovery_due "$now" || return 0
			printf '%s\n' "$now" > "$LAST_ATTEMPT_FILE"
			recovering=1
			# Re-check the active connection first in a separate engine: when it
			# still works there, only the live engine is stuck and a restart helps;
			# when it fails there too, restarting it would only drop sessions.
			first="$current"
			if auto_select_still_enabled; then
				exclude_ru=1
			else
				only="$current"
			fi
			;;
	esac

	cleanup_stale_probes
	umask 077
	probe_dir="$(mktemp -d "${SELECTION_DIR_PREFIX}XXXXXX")" || return 1
	cp "$SUB_FILE" "$probe_dir/subscription.json" || return 1
	if [ -n "$expected_hash" ]; then
		[ "$(sha256sum "$probe_dir/subscription.json" | awk '{print $1}')" = "$expected_hash" ] || return 1
	fi
	ln -s "$ENGINE_BIN" "$probe_dir/shpun-probe" || return 1
	HTTP_PROXY_PORT="$SELECTION_PROBE_PORT"
	INITIAL_DEADLINE=$(( $(date +%s) + deadline ))
	if [ "$measuring" = 1 ]; then
		# One transport per server: the fastest one seen before, else the first.
		candidates="$(ucode "$STATE_DIR/server-selection.uc" representatives "$probe_dir/subscription.json" "$SCORES_FILE" 2>/dev/null)" || candidates=
		limit=9999
	else
		candidates="$(ucode "$STATE_DIR/server-selection.uc" candidates "$probe_dir/subscription.json" "$only" "$skip" "$first" "$exclude_ru" 2>/dev/null)" || candidates=
		limit="$AUTO_FAILOVER_MAX_CANDIDATES"
		# A pinned server tests every published transport, subject to the overall deadline.
		[ "$only" = - ] || limit=9999
	fi
	total=0
	for candidate in $candidates; do total=$((total + 1)); done
	[ "$total" -le "$limit" ] || total="$limit"
	for candidate in $candidates; do
		case "$candidate" in ''|*[!0-9]*) continue ;; esac
		selection_is_current || return 1
		[ "$tried" -lt "$limit" ] && [ "$(date +%s)" -lt "$INITIAL_DEADLINE" ] || break
		# Progress for the LuCI dialog: "<tested> <total> <action>".
		printf '%s %s %s\n' "$tried" "$total" "$GROUP_ACTION" > "$PROGRESS_FILE" 2>/dev/null || true
		tried=$((tried + 1))
		probe_candidate "$candidate"
		probe_rc=$?
		if [ "$probe_rc" -eq 0 ]; then
			score="$SCORE"
			log "grouped candidate index $candidate passed (HTTPS score $score)"
			record_score "$candidate" "$score"
			if [ -z "$best" ] || awk -v a="$score" -v b="$best_score" 'BEGIN {exit !(a<b)}'; then
				best="$candidate"
				best_score="$score"
			fi
		elif [ "$probe_rc" -eq 2 ]; then
			# Not enough memory or a foreign listener: stop probing, change nothing.
			low_memory=1
			tried=$((tried - 1))
			break
		else
			log "grouped candidate index $candidate failed tunnel checks"
			record_score "$candidate" fail
		fi
	done

	selection_is_current || return 1
	if [ "$measuring" = 1 ]; then
		date +%s > "$MEASURED_AT_FILE" 2>/dev/null || true
		if [ "$low_memory" = 1 ]; then
			printf '%s\n' "error:low_memory" > "$AUTO_SELECT_STATUS_FILE"
			return 1
		fi
		printf 'measured:%s\n' "$tried" > "$AUTO_SELECT_STATUS_FILE"
		log "server measurement refreshed ($tried servers tested)"
		return 0
	fi
	if [ -z "$best" ]; then
		log "no working server in grouped search ($tried tested); keeping the current connection untouched"
		[ "$recovering" = 0 ] || schedule_next_attempt "$now"
		[ "$low_memory" = 0 ] || [ "$interactive" = 0 ] || printf '%s\n' "error:low_memory" > "$AUTO_SELECT_STATUS_FILE"
		return 1
	fi

	if [ "$GROUP_ACTION" = --initial ]; then
		write_selection_value "$SELECTED_LINK_FILE" "$best" || return 1
	elif [ "$best" = "$current" ] && [ "$recovering" = 1 ]; then
		if [ "$GROUP_ACTION" = --recover-quality ]; then
			# The active connection is still the best one: nothing to fix here.
			log "grouped recovery: current index $current is still the best connection"
			schedule_next_attempt "$now"
			return 0
		fi
		log "grouped recovery: current index $current works in a fresh engine; restarting the live tunnel"
		schedule_next_attempt "$now"
		SHPUN_SELECTION_SOURCE="$probe_dir/subscription.json" switch_to "$current" || return 1
		return 0
	elif [ "$best" = "$current" ] && [ -s "$VPN_READY_FILE" ]; then
		[ "$GROUP_ACTION" != --choose-server ] || write_selection_value "$SERVER_AUTO_SELECT_FILE" 0 || return 1
	elif [ "$GROUP_ACTION" = --choose-server ]; then
		SHPUN_SELECTION_SOURCE="$probe_dir/subscription.json" switch_to "$best" pin || return 1
	else
		SHPUN_SELECTION_SOURCE="$probe_dir/subscription.json" switch_to "$best" || return 1
	fi
	if [ "$GROUP_ACTION" = --choose-all ]; then
		write_selection_value "$SERVER_AUTO_SELECT_FILE" 1 || return 1
	fi
	clear_recovery_backoff
	if [ "$interactive" = 1 ]; then
		rm -f "$LAST_ATTEMPT_FILE"
		printf 'ok:%s\n' "$best" > "$AUTO_SELECT_STATUS_FILE"
	fi
	log "grouped selection $GROUP_ACTION chose index $best (tested $tried, HTTPS score $best_score)"
	return 0
}


[ -f "$CONF" ] && . "$CONF"
[ -z "$AUTO_FAILOVER_COOLDOWN" ] && AUTO_FAILOVER_COOLDOWN="$AUTO_FAILOVER_COOLDOWN_DEFAULT"
[ -z "$AUTO_FAILOVER_MAX_CANDIDATES" ] && AUTO_FAILOVER_MAX_CANDIDATES="$AUTO_FAILOVER_MAX_CANDIDATES_DEFAULT"
[ -z "$AUTO_FAILOVER_READY_TIMEOUT" ] && AUTO_FAILOVER_READY_TIMEOUT="$AUTO_FAILOVER_READY_TIMEOUT_DEFAULT"
[ -z "$HTTP_PROXY_PORT" ] && HTTP_PROXY_PORT="$HTTP_PROXY_PORT_DEFAULT"
[ -z "$TUNNEL_PROBE_URL" ] && TUNNEL_PROBE_URL="$TUNNEL_PROBE_URL_DEFAULT"
[ -z "$TUNNEL_PROBE_FALLBACK_URL" ] && TUNNEL_PROBE_FALLBACK_URL="$TUNNEL_PROBE_FALLBACK_URL_DEFAULT"
[ -z "$TUNNEL_PROBE_SECONDARY_URL" ] && TUNNEL_PROBE_SECONDARY_URL="$TUNNEL_PROBE_SECONDARY_URL_DEFAULT"
[ -z "$TUNNEL_QUALITY_PROBE_URL" ] && TUNNEL_QUALITY_PROBE_URL="$TUNNEL_QUALITY_PROBE_URL_DEFAULT"
[ -z "$TUNNEL_QUALITY_PROBE_MIN_BYTES" ] && TUNNEL_QUALITY_PROBE_MIN_BYTES="$TUNNEL_QUALITY_PROBE_MIN_BYTES_DEFAULT"
[ -z "$TUNNEL_QUALITY_CONFIRM_URLS" ] && TUNNEL_QUALITY_CONFIRM_URLS="$TUNNEL_QUALITY_CONFIRM_URLS_DEFAULT"
[ -z "$TUNNEL_QUALITY_CONFIRM_MIN_SUCCESS" ] && TUNNEL_QUALITY_CONFIRM_MIN_SUCCESS="$TUNNEL_QUALITY_CONFIRM_MIN_SUCCESS_DEFAULT"

case "$AUTO_FAILOVER_COOLDOWN" in ''|*[!0-9]*) AUTO_FAILOVER_COOLDOWN="$AUTO_FAILOVER_COOLDOWN_DEFAULT" ;; esac
case "$AUTO_FAILOVER_MAX_CANDIDATES" in ''|*[!0-9]*) AUTO_FAILOVER_MAX_CANDIDATES="$AUTO_FAILOVER_MAX_CANDIDATES_DEFAULT" ;; esac
case "$AUTO_FAILOVER_READY_TIMEOUT" in ''|*[!0-9]*) AUTO_FAILOVER_READY_TIMEOUT="$AUTO_FAILOVER_READY_TIMEOUT_DEFAULT" ;; esac
case "$TUNNEL_QUALITY_PROBE_MIN_BYTES" in ''|*[!0-9]*) TUNNEL_QUALITY_PROBE_MIN_BYTES="$TUNNEL_QUALITY_PROBE_MIN_BYTES_DEFAULT" ;; esac
case "$AUTO_FAILOVER_MAX_COOLDOWN" in ''|*[!0-9]*) AUTO_FAILOVER_MAX_COOLDOWN="$AUTO_FAILOVER_MAX_COOLDOWN_DEFAULT" ;; esac
[ "$AUTO_FAILOVER_MAX_COOLDOWN" -ge "$AUTO_FAILOVER_COOLDOWN" ] || AUTO_FAILOVER_MAX_COOLDOWN="$AUTO_FAILOVER_COOLDOWN"
case "$SELECTION_MIN_AVAILABLE_KB" in ''|*[!0-9]*) SELECTION_MIN_AVAILABLE_KB="$SELECTION_MIN_AVAILABLE_KB_DEFAULT" ;; esac
case "$SELECTION_PROBE_PORT" in ''|*[!0-9]*) SELECTION_PROBE_PORT="$SELECTION_PROBE_PORT_DEFAULT" ;; esac
case "$SELECTION_START_TIMEOUT" in ''|*[!0-9]*) SELECTION_START_TIMEOUT="$SELECTION_START_TIMEOUT_DEFAULT" ;; esac
case "$TUNNEL_QUALITY_CONFIRM_MIN_SUCCESS" in ''|*[!0-9]*) TUNNEL_QUALITY_CONFIRM_MIN_SUCCESS="$TUNNEL_QUALITY_CONFIRM_MIN_SUCCESS_DEFAULT" ;; esac
[ "$TUNNEL_QUALITY_CONFIRM_MIN_SUCCESS" -gt 0 ] 2>/dev/null || TUNNEL_QUALITY_CONFIRM_MIN_SUCCESS="$TUNNEL_QUALITY_CONFIRM_MIN_SUCCESS_DEFAULT"

# Persistent user toggles (default to enabled when missing/empty).
SERVER_AUTO_EXCLUDE_RU="$(cat "$SERVER_AUTO_EXCLUDE_RU_FILE" 2>/dev/null | tr -d '\r\n ' || true)"
case "$SERVER_AUTO_EXCLUDE_RU" in 1|yes|true|on) SERVER_AUTO_EXCLUDE_RU=1 ;; *) SERVER_AUTO_EXCLUDE_RU=0 ;; esac

INITIAL_DEADLINE=
GROUP_ACTION="${1:-}"
interactive=0
case "$GROUP_ACTION" in --choose-all|--choose-server|--measure) interactive=1 ;; esac
case "$GROUP_ACTION" in --initial|--choose-all|--choose-server|--measure|--recover-quality|--recover-failed) shift ;; *) GROUP_ACTION= ;; esac
MANUAL_SELECT=0
if [ -n "${AUTO_FAILOVER_CANDIDATES:-}" ]; then
	MANUAL_SELECT=1
fi

if [ -z "$GROUP_ACTION" ] && [ "$MANUAL_SELECT" -eq 0 ] && ! auto_select_still_enabled; then
	log "automatic failover skipped: server_auto_select is disabled"
	printf '%s\n' "cancelled:user_disabled" > "$AUTO_SELECT_STATUS_FILE" 2>/dev/null || true
	exit 0
fi

if ! lock_acquire; then
	{ [ "$MANUAL_SELECT" -eq 1 ] || [ "$interactive" = 1 ]; } && printf '%s\n' "error:busy" > "$AUTO_SELECT_STATUS_FILE"
	exit 0
fi

if [ "$MANUAL_SELECT" -eq 1 ] || [ "$interactive" = 1 ]; then
	printf '%s\n' "running" > "$AUTO_SELECT_STATUS_FILE"
fi

[ -s "$SUB_FILE" ] && [ -x "$SWITCH_SCRIPT" ] || {
	log "automatic failover is not ready: subscription or switch script is missing"
	{ [ "$MANUAL_SELECT" -eq 1 ] || [ "$interactive" = 1 ]; } && printf '%s\n' "error:not_ready" > "$AUTO_SELECT_STATUS_FILE"
	exit 1
}

detect_http_client
[ -n "$HTTP_BIN" ] || {
	log "automatic failover is not ready: no HTTP client"
	{ [ "$MANUAL_SELECT" -eq 1 ] || [ "$interactive" = 1 ]; } && printf '%s\n' "error:no_http_client" > "$AUTO_SELECT_STATUS_FILE"
	exit 1
}

if [ -n "$GROUP_ACTION" ]; then
	select_grouped_server "$@"
	exit $?
fi

now="$(date +%s 2>/dev/null || echo 0)"
last="$(cat "$LAST_ATTEMPT_FILE" 2>/dev/null | tr -d '\r\n ' || echo 0)"
case "$now" in ''|*[!0-9]*) now=0 ;; esac
case "$last" in ''|*[!0-9]*) last=0 ;; esac
age=$((now - last))
if [ "${AUTO_FAILOVER_IGNORE_COOLDOWN:-0}" != "1" ] &&
	[ "$last" -gt 0 ] && [ "$age" -ge 0 ] && [ "$age" -lt "$AUTO_FAILOVER_COOLDOWN" ]; then
	log "automatic failover cooldown is active (${age}s/${AUTO_FAILOVER_COOLDOWN}s)"
	exit 0
fi
printf '%s\n' "$now" > "$LAST_ATTEMPT_FILE"

current="$(cat "$SELECTED_LINK_FILE" 2>/dev/null | tr -d '\r\n ' || echo 0)"
case "$current" in ''|*[!0-9]*) current=0 ;; esac
count="$(jsonfilter -i "$SUB_FILE" -e '@.subscription.links[*]' 2>/dev/null | wc -l | tr -d ' ')"
case "$count" in ''|*[!0-9]*) count=0 ;; esac
[ "$count" -gt 0 ] || {
	log "automatic failover cannot run: subscription has $count server(s)"
	[ "$MANUAL_SELECT" -eq 1 ] && printf '%s\n' "error:no_servers" > "$AUTO_SELECT_STATUS_FILE"
	exit 1
}
[ "$MANUAL_SELECT" -eq 1 ] || [ "$count" -gt 1 ] || {
	log "automatic failover cannot run: subscription has no alternative servers"
	exit 1
}
[ "$current" -lt "$count" ] || current=0

limit="$AUTO_FAILOVER_MAX_CANDIDATES"
[ "$limit" -gt 0 ] 2>/dev/null || limit="$AUTO_FAILOVER_MAX_CANDIDATES_DEFAULT"
if [ "$MANUAL_SELECT" -eq 1 ]; then
	[ "$limit" -le "$count" ] || limit="$count"
else
	[ "$limit" -lt "$count" ] || limit=$((count - 1))
fi

if [ "$MANUAL_SELECT" -eq 1 ]; then
	log "manual automatic selection started; testing up to $limit servers from current index $current"
else
	log "tunnel failure confirmed; trying up to $limit alternative servers from current index $current"
fi
tried=0

if [ "$MANUAL_SELECT" -eq 1 ]; then
	candidate_list="$AUTO_FAILOVER_CANDIDATES"
else
	offset=1
	candidate_list=""
	preferred_list=""
	reserve_list=""
	current_link="$(subscription_link "$current" || true)"
	while [ "$offset" -lt "$count" ]; do
		idx=$(( (current + offset) % count ))
		link="$(subscription_link "$idx" || true)"
		if [ "$SERVER_AUTO_EXCLUDE_RU" = "1" ]; then
			if [ "$(link_group "$link")" = "gateway" ]; then
				offset=$((offset + 1))
				continue
			fi
		fi
		# When Hysteria is active, try other Hysteria nodes before Reality.
		# Leave a working Reality selection alone; this is failure recovery only.
		case "$current_link" in
			hysteria2://*|hy2://*)
				case "$link" in
					hysteria2://*|hy2://*) preferred_list="$preferred_list $idx" ;;
					*) reserve_list="$reserve_list $idx" ;;
				esac ;;
			*) preferred_list="$preferred_list $idx" ;;
		esac
		offset=$((offset + 1))
	done
	candidate_list="$preferred_list$reserve_list"
fi

# Strict RU exclusion for the background watchdog: if every alternative is a
# RU/gateway server and exclude_ru is on, do NOT relax the policy and do NOT
# pick a RU server automatically. Keep the current server and surface a clear
# error. The user may still select a RU server manually from the server list.
if [ "$MANUAL_SELECT" -eq 0 ] && [ -z "$candidate_list" ] && [ "$SERVER_AUTO_EXCLUDE_RU" = "1" ]; then
	log "automatic failover aborted: no non-RU alternative servers available (server_auto_exclude_ru=1, strict); keeping current server index $current"
	printf '%s\n' "auto_failover_no_candidates" > "$VERROR_FILE" 2>/dev/null || true
	exit 1
fi

for candidate in $candidate_list; do
	case "$candidate" in ''|*[!0-9]*) continue ;; esac
	[ "$candidate" -lt "$count" ] || continue
	[ "$tried" -lt "$limit" ] || break
	if [ "$SERVER_AUTO_EXCLUDE_RU" = "1" ]; then
		link="$(subscription_link "$candidate" || true)"
		if [ "$(link_group "$link")" = "gateway" ]; then
			log "skipping RU/gateway server index $candidate (server_auto_exclude_ru=1)"
			continue
		fi
	fi

	# Watchdog cancellation: if the user turned AUTO OFF while this background
	# failover was running, finish safely without starting a new switch_to and
	# without rolling back. The currently in-flight candidate check (if any)
	# already completed above this guard on the previous iteration. Do not kill
	# the process; just stop iterating and leave a clear status. The explicit
	# "Найти лучший сервер" operation (MANUAL_SELECT=1) is never cancelled here.
	if ! auto_select_still_enabled; then
		log "server_auto_select disabled during watchdog failover; aborting remaining candidates (tried=$tried, current index=$current)"
		printf '%s\n' "cancelled:user_disabled" > "$AUTO_SELECT_STATUS_FILE" 2>/dev/null || true
		exit 0
	fi

	tried=$((tried + 1))

	log "trying server index $candidate ($tried/$limit)"
	if [ "$candidate" -eq "$current" ] && probe_tunnel; then
		[ "$MANUAL_SELECT" -eq 1 ] && printf 'ok:%s\n' "$candidate" > "$AUTO_SELECT_STATUS_FILE"
		log "automatic selection kept working server index $candidate"
		exit 0
	fi
	if switch_to "$candidate" && wait_for_candidate; then
		printf '%s\n' "$current" > "$FROM_FILE"
		date +%s > "$LAST_SUCCESS_FILE" 2>/dev/null || true
		[ "$MANUAL_SELECT" -eq 1 ] && printf 'ok:%s\n' "$candidate" > "$AUTO_SELECT_STATUS_FILE"
		log "automatic failover succeeded: server index $current -> $candidate"
		exit 0
	fi
	log "server index $candidate did not restore the tunnel"
done

log "no tested server restored the tunnel; returning to original index $current"
switch_to "$current" || true
[ "$MANUAL_SELECT" -eq 1 ] && printf 'failed:%s\n' "$current" > "$AUTO_SELECT_STATUS_FILE"
exit 1
