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
SCORES_FILE="${SELECTION_SCORES_FILE:-/tmp/shpun-selection-delay}"
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
# Same host as TUNNEL_QUALITY_PROBE_URL: a check is one connection, like a page load.
SELECTION_RTT_URL_DEFAULT="https://speed.cloudflare.com/cdn-cgi/trace"
# All relays "через РФ" reach one gateway address. Many new connections to it in
# a short time can get the subscriber's path to that address dropped for a while,
# so relays are a reserve: probed only when no direct connection works, never in
# background measurement, few per gateway and pass, with pauses between probes,
# and a gateway is left alone for a while once it stops answering.
GATEWAY_COOLDOWN_FILE="${GATEWAY_COOLDOWN_FILE:-/tmp/shpun-gateway-cooldown}"
GATEWAY_COOLDOWN_DEFAULT=900
# Some providers drop the whole gateway address for minutes after a few Reality
# connections to it (also with ordinary browsing), taking XHTTP down as well.
# When a TCP relay (Reality, or VLESS over TLS) fails and the gateway then
# stops answering, TCP relays through that gateway are left out for a day;
# XHTTP stays available.
REALITY_BLOCK_FILE="${REALITY_BLOCK_FILE:-/tmp/shpun-gateway-reality-blocked}"
REALITY_BLOCK_COOLDOWN_DEFAULT=86400
RELAY_PROBES_PER_GATEWAY_DEFAULT=2
SELECTION_PROBE_GAP_DEFAULT=3
# What the selector is doing right now, for the LuCI widget: "<phase> <index>"
# with phase probing|connecting|verifying|reverting|done|failed (RAM only).
PHASE_FILE="${SELECTION_PHASE_FILE:-/tmp/shpun-selection-phase}"
# Measurements newer than this order candidates best-first (background
# measuring runs every 4 h).
SCORE_FRESH_TTL=16200
# Automatic choice re-checks the best measured servers first and stops once
# this many direct connections passed, instead of testing every server.
SELECTION_GOOD_ENOUGH_DEFAULT=3

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

set_phase() {
	printf '%s %s\n' "$1" "${2:--}" > "$PHASE_FILE" 2>/dev/null || true
}

# One check of the live tunnel after a switch: wait until the new engine
# listens (the agent marks the tunnel ready a few seconds later), then a small
# download through it on one connection (twice at most).
live_tunnel_ok() {
	local waited=0 n=0 tmp="/tmp/shpun-failover-live.$$" bytes
	while [ "$waited" -lt "$AUTO_FAILOVER_READY_TIMEOUT" ]; do
		[ -s "$VPN_READY_FILE" ] && break
		probe_port_listening "$LIVE_PROXY_PORT" && break
		usleep 500000 2>/dev/null || sleep 1
		waited=$((waited + 1))
	done
	[ -s "$VPN_READY_FILE" ] || probe_port_listening "$LIVE_PROXY_PORT" || return 1
	while [ "$n" -lt 2 ]; do
		[ "$n" -eq 0 ] || sleep 2
		n=$((n + 1))
		rm -f "$tmp"
		curl -q -fsSL --noproxy '' --connect-timeout 4 -m 8 -A ShpunRouter \
			-x "http://127.0.0.1:$LIVE_PROXY_PORT" -o "$tmp" "$TUNNEL_QUALITY_PROBE_URL" >/dev/null 2>&1 || continue
		bytes="$(wc -c < "$tmp" 2>/dev/null | tr -d ' ')"
		rm -f "$tmp"
		case "$bytes" in ''|*[!0-9]*) continue ;; esac
		[ "$bytes" -ge "$TUNNEL_QUALITY_PROBE_MIN_BYTES" ] && return 0
	done
	rm -f "$tmp"
	return 1
}

# order_by_scores INDEX...: best first. Direct connections before relays; within
# each, recently passed ones by measured delay, then unmeasured ones in the given
# order (the transport priority), then recently failed ones.
order_by_scores() {
	cat "$SCORES_FILE" 2>/dev/null | awk -v list="$*" -v relays="$relays" -v now="$(date +%s)" -v ttl="$SCORE_FRESH_TTL" '
		NF == 3 && now - $3 <= ttl && $3 - now <= 300 { s[$1] = $2 }
		END {
			n = split(list, a, " ")
			for (i = 1; i <= n; i++) {
				id = a[i]; st = 1; v = 0
				if (id in s) { if (s[id] == "fail") st = 2; else { st = 0; v = s[id] + 0 } }
				k[i] = (index(relays, " " id " ") ? 3 : 0) + st; d[i] = v
			}
			for (i = 2; i <= n; i++)
				for (j = i; j > 1 && (k[j] < k[j-1] || (k[j] == k[j-1] && d[j] < d[j-1])); j--) {
					t = a[j]; a[j] = a[j-1]; a[j-1] = t
					t = k[j]; k[j] = k[j-1]; k[j-1] = t
					t = d[j]; d[j] = d[j-1]; d[j-1] = t
				}
			for (i = 1; i <= n; i++) printf "%s%s", a[i], (i < n ? " " : "\n")
		}'
}

# fresh_passes INDEX...: how many of them passed a check recently.
fresh_passes() {
	cat "$SCORES_FILE" 2>/dev/null | awk -v list=" $* " -v now="$(date +%s)" -v ttl="$SCORE_FRESH_TTL" '
		NF == 3 && $2 != "fail" && now - $3 <= ttl && $3 - now <= 300 && index(list, " " $1 " ") { s[$1] = 1 }
		END { n = 0; for (i in s) n++; print n }'
}

# relay_allowed INDEX: 0 when a relay may be used now (gateway not paused, TCP
# relays not blocked on this network, per-pass budget left). Sets gateway and
# relay_kind; both stay empty for a direct connection.
relay_allowed() {
	gateway= relay_kind=
	case "$relays" in *" $1 "*) ;; *) return 0 ;; esac
	gateway="$(gateway_key "$(printf '%s\n' "$endpoints" | awk -v i="$1" '$1 == i { print $2; exit }')")"
	relay_kind="$(printf '%s\n' "$endpoints" | awk -v i="$1" '$1 == i { print $4; exit }')"
	if gateway_paused "$gateway"; then
		log "grouped candidate index $1 skipped: gateway $gateway is paused"
		return 1
	fi
	if [ "$relay_kind" != xhttp ] && reality_blocked "$gateway"; then
		log "grouped candidate index $1 skipped: TCP relays through gateway $gateway are blocked on this network"
		return 1
	fi
	if [ "$(printf '%s\n' $relay_probes | grep -cx "$gateway")" -ge "$RELAY_PROBES_PER_GATEWAY" ]; then
		log "grouped candidate index $1 skipped: relay limit for gateway $gateway in this pass"
		return 1
	fi
	relay_probes="$relay_probes $gateway"
	return 0
}

relay_failed() {
	if [ -n "$gateway" ] && ! gateway_answers "$gateway"; then
		gateway_pause "$gateway"
		[ "$relay_kind" = xhttp ] || reality_block "$gateway"
	fi
}

# connect_and_verify MODE INDEX...: switch the live tunnel to each connection in
# turn and keep the first one that carries traffic right after the switch.
# MODE pin keeps the server pinned, auto keeps automatic selection. Sets connected.
connect_and_verify() {
	local mode="$1" idx
	shift
	connected=
	for idx in "$@"; do
		relay_allowed "$idx" || continue
		set_phase connecting "$idx"
		if [ "$mode" = pin ]; then
			SHPUN_SELECTION_SOURCE="$probe_dir/subscription.json" switch_to "$idx" pin || continue
		else
			SHPUN_SELECTION_SOURCE="$probe_dir/subscription.json" switch_to "$idx" || continue
		fi
		set_phase verifying "$idx"
		if live_tunnel_ok; then
			connected="$idx"
			return 0
		fi
		log "connection index $idx carries no traffic after the switch"
		record_score "$idx" fail
		relay_failed
	done
	return 1
}

# Return to the connection that was active before (and its mode).
revert_connection() {
	case "$old_selection" in ''|*[!0-9]*) return 1 ;; esac
	set_phase reverting "$old_selection"
	SHPUN_SELECTION_SOURCE="$probe_dir/subscription.json" switch_to "$old_selection" || return 1
	[ -z "$old_mode" ] || write_selection_value "$SERVER_AUTO_SELECT_FILE" "$old_mode" || true
	live_tunnel_ok || log "previous connection index $old_selection does not answer either"
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
		case "$(cat "$PHASE_FILE" 2>/dev/null)" in done*|failed*) ;; *) set_phase failed ;; esac
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

# Request round trip through the tunnel: time to the first response byte
# after the TLS session is up. This is the delay the user feels (comparable
# to ping), unlike the full time that also counts connection setup.
request_rtt() {
	awk 'NF >= 2 && $2 > $1 { printf "%.3f\n", $2 - $1; ok = 1 } END { exit !ok }'
}

# Mean of request_rtt over several "appconnect starttransfer" lines. A request
# on a reused connection reports appconnect 0, so its delay is starttransfer.
request_rtt_mean() {
	awk 'NF >= 2 && $2 > $1 { s += $2 - $1; n++ } END { if (!n) exit 1; printf "%.3f\n", s / n }'
}

# Score = request delay through the candidate (lower is better). The candidate
# must first prove it carries real traffic: the download check, or enough
# independent HTTPS sites when the download endpoint itself is unavailable.
# The download and two short requests share one connection, like a page load:
# one upstream connection per check instead of a burst of short ones.
candidate_score() {
	local timing url successes=0 sum=0 rtt
	rm -f "$probe_dir/sample"
	if timing="$(selection_curl 6 -L -w '%{time_appconnect} %{time_starttransfer}\n' \
			-o "$probe_dir/sample" "$TUNNEL_QUALITY_PROBE_URL" \
			-o /dev/null "$SELECTION_RTT_URL" -o /dev/null "$SELECTION_RTT_URL")" &&
		[ "$(wc -c < "$probe_dir/sample" 2>/dev/null || echo 0)" -ge "$TUNNEL_QUALITY_PROBE_MIN_BYTES" ]; then
		printf '%s\n' "$timing" | sed 1d | request_rtt_mean && return 0
		return 1
	fi

	for url in $TUNNEL_QUALITY_CONFIRM_URLS; do
		timing="$(selection_curl 2 -o /dev/null -w '%{time_appconnect} %{time_starttransfer}' "$url")" || continue
		rtt="$(printf '%s\n' "$timing" | request_rtt)" || continue
		sum="$(awk -v a="$sum" -v b="$rtt" 'BEGIN {print a+b}')"
		successes=$((successes + 1))
		if [ "$successes" -ge "$TUNNEL_QUALITY_CONFIRM_MIN_SUCCESS" ]; then
			awk -v sum="$sum" -v count="$successes" 'BEGIN {printf "%.3f\n", sum/count}'
			return 0
		fi
	done
	return 1
}

# gateway_key HOST: the address relays reach (several names share one gateway).
gateway_key() {
	local addr
	case " $gateway_addrs " in *" $1="*)
		addr="${gateway_addrs#* $1=}"; echo "${addr%% *}"; return 0 ;;
	esac
	addr="$(nslookup "$1" 2>/dev/null | awk '/^Address/ && $NF !~ /^127\./ && $NF ~ /^[0-9.]+$/ { a = $NF } END { print a }')"
	[ -n "$addr" ] || addr="$1"
	gateway_addrs="$gateway_addrs $1=$addr"
	echo "$addr"
}

# until_active FILE KEY: 0 while FILE has "KEY UNTIL" with UNTIL in the future.
until_active() {
	local now until
	now="$(date +%s)"
	until="$(awk -v g="$2" '$1 == g { u = $2 } END { print u + 0 }' "$1" 2>/dev/null)"
	[ "${until:-0}" -gt "$now" ]
}

# until_set FILE KEY SECONDS
until_set() {
	local tmp until
	until=$(( $(date +%s) + $3 ))
	tmp="$(mktemp "${1}.XXXXXX")" || return 0
	{ grep -v "^$2 " "$1" 2>/dev/null; printf '%s %s\n' "$2" "$until"; } > "$tmp"
	mv "$tmp" "$1" 2>/dev/null || rm -f "$tmp"
}

gateway_paused() { until_active "$GATEWAY_COOLDOWN_FILE" "$1"; }

gateway_pause() {
	until_set "$GATEWAY_COOLDOWN_FILE" "$1" "$GATEWAY_COOLDOWN"
	log "gateway $1 does not answer; relays through it paused for ${GATEWAY_COOLDOWN}s"
}

reality_blocked() { until_active "$REALITY_BLOCK_FILE" "$1"; }

reality_block() {
	until_set "$REALITY_BLOCK_FILE" "$1" "$REALITY_BLOCK_COOLDOWN"
	log "gateway $1 went silent after a TCP relay; TCP relays through it left out for ${REALITY_BLOCK_COOLDOWN}s"
}

# gateway_answers ADDR: one plain TLS handshake to the gateway address (no
# SNI), to tell a dead path to the gateway from a dead server behind it.
gateway_answers() {
	curl -q -s -k -o /dev/null --noproxy '*' --connect-timeout 4 -m 6 \
		-w '%{time_appconnect}' "https://$1/" 2>/dev/null | awk '{ exit !($1 > 0) }'
}

probe_candidate() {
	local candidate="$1" score
	printf '%s\n' "$candidate" > "$probe_dir/index" || return 1
	rm -f "$probe_dir/config.json"
	# The probe replaces inbounds and routing below, so the domain lists that make
	# a full build take seconds on small routers are left out; the outbound itself
	# is built exactly as for the live tunnel.
	SUB_FILE="$probe_dir/subscription.json" OUT_CFG="$probe_dir/config.json" \
		SELECTED_LINK_FILE="$probe_dir/index" ROUTES_MODE_FILE="$probe_dir/absent" \
		SMART_RU_DOMAINS_FILE="$probe_dir/absent" SMART_RU_BUILTIN_DOMAINS_FILE="$probe_dir/absent" \
		ALWAYS_VPN_DOMAINS_FILE="$probe_dir/absent" ALWAYS_VPN_CIDRS_FILE="$probe_dir/absent" \
		CUSTOM_ROUTES_FILE="$probe_dir/absent" "$BUILD_SCRIPT" || return 1
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
	# One check: a download plus two delay samples on a single connection.
	local score
	if score="$(candidate_score)" && kill -0 "$probe_pid" 2>/dev/null; then
		# Let the engine close its upstream connection normally before it stops.
		sleep 1
		stop_selection_probe
		SCORE="$score"
		return 0
	fi
	sleep 1
	stop_selection_probe
	return 1
}

select_grouped_server() {
	local only=- skip=- first=- exclude_ru=0 candidates candidate tried=0 best= best_score= best_compare= score compare relays
	local endpoints gateway gateway_addrs relay_probes relay_kind
	local old_selection old_mode expected_hash limit now recovering=0 deadline=75 probe_rc low_memory=0 measuring=0 total
	local connecting=0 passed= direct_passes=0 good_enough=0 connected
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
		--connect-server)
			# Manual choice: connect at once with the best transport of the server,
			# verify the live tunnel, fall back to its other transports, else revert.
			only="$1"
			case "$only" in ''|*[!0-9]*) return 1 ;; esac
			expected_hash="$2"
			connecting=1
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

	[ "$interactive" = 0 ] || rm -f "$PHASE_FILE"
	cleanup_stale_probes
	umask 077
	probe_dir="$(mktemp -d "${SELECTION_DIR_PREFIX}XXXXXX")" || return 1
	cp "$SUB_FILE" "$probe_dir/subscription.json" || return 1
	if [ -n "$expected_hash" ]; then
		[ "$(sha256sum "$probe_dir/subscription.json" | awk '{print $1}')" = "$expected_hash" ] || return 1
	fi
	ln -s "$ENGINE_BIN" "$probe_dir/shpun-probe" || return 1
	LIVE_PROXY_PORT="$HTTP_PROXY_PORT"
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
	# Relays through the RU gateway win only when clearly faster (compare_delay).
	endpoints="$(ucode "$STATE_DIR/server-selection.uc" endpoints "$probe_dir/subscription.json" 2>/dev/null)"
	relays=" $(printf '%s\n' "$endpoints" | awk '$3 == 1 { printf "%s ", $1 }') "
	gateway_addrs= relay_probes=

	if [ "$connecting" = 1 ]; then
		candidates="$(order_by_scores $candidates)"
		[ -n "$candidates" ] || return 1
		# Already on this server and it works: only pin it.
		if [ -s "$VPN_READY_FILE" ] && case " $candidates " in *" $current "*) true ;; *) false ;; esac &&
			set_phase verifying "$current" && live_tunnel_ok; then
			write_selection_value "$SERVER_AUTO_SELECT_FILE" 0 || return 1
			connected="$current"
		elif ! connect_and_verify pin $candidates; then
			log "manual connection to server index $only failed with every transport; returning to index $old_selection"
			revert_connection || true
			set_phase failed "$only"
			printf 'failed:%s\n' "$old_selection" > "$AUTO_SELECT_STATUS_FILE"
			return 1
		fi
		set_phase done "$connected"
		clear_recovery_backoff
		rm -f "$LAST_ATTEMPT_FILE"
		printf 'ok:%s\n' "$connected" > "$AUTO_SELECT_STATUS_FILE"
		log "manual connection to server index $only uses index $connected"
		return 0
	fi

	if [ "$GROUP_ACTION" = --choose-all ]; then
		# Best measured servers first. With enough fresh results that order is
		# meaningful, so the search stops after a few passes instead of testing all.
		candidates="$(order_by_scores $candidates)"
		[ "$(fresh_passes $candidates)" -lt "$SELECTION_GOOD_ENOUGH" ] || good_enough="$SELECTION_GOOD_ENOUGH"
	fi
	[ "$interactive" = 0 ] || set_phase probing
	total=0
	for candidate in $candidates; do total=$((total + 1)); done
	[ "$total" -le "$limit" ] || total="$limit"
	for candidate in $candidates; do
		case "$candidate" in ''|*[!0-9]*) continue ;; esac
		selection_is_current || return 1
		[ "$tried" -lt "$limit" ] && [ "$(date +%s)" -lt "$INITIAL_DEADLINE" ] || break
		if [ "$good_enough" -gt 0 ] && [ "$direct_passes" -ge "$good_enough" ]; then
			log "grouped search: $direct_passes of the best measured connections passed; not testing the rest"
			break
		fi
		gateway= relay_kind=
		case "$relays" in
			*" $candidate "*)
				if [ "$measuring" = 1 ]; then
					log "grouped candidate index $candidate skipped: relays are not measured in background"
					continue
				fi
				if [ -n "$best" ]; then
					log "grouped candidate index $candidate skipped: a working connection was found, relays are a reserve"
					continue
				fi
				relay_allowed "$candidate" || continue
				;;
		esac
		# Pacing matters only for connections through the shared gateway.
		[ "$tried" -eq 0 ] || [ -z "$gateway" ] || sleep "$SELECTION_PROBE_GAP"
		# Progress for the LuCI dialog: "<tested> <total> <action>".
		printf '%s %s %s\n' "$tried" "$total" "$GROUP_ACTION" > "$PROGRESS_FILE" 2>/dev/null || true
		tried=$((tried + 1))
		probe_candidate "$candidate"
		probe_rc=$?
		# One check is a single connection, so a lost packet can fail it. A direct
		# connection gets one more chance before it is called unavailable; relays
		# do not, to keep connections to the shared gateway few.
		if [ "$probe_rc" -eq 1 ] && [ -z "$gateway" ] && [ "$SELECTION_RETRY" = 1 ] &&
			[ "$(date +%s)" -lt "$INITIAL_DEADLINE" ]; then
			log "grouped candidate index $candidate failed once; checking it again"
			sleep 2
			probe_candidate "$candidate"
			probe_rc=$?
		fi
		if [ "$probe_rc" -eq 0 ]; then
			score="$SCORE"
			log "grouped candidate index $candidate passed (delay ${score}s)"
			record_score "$candidate" "$score"
			compare="$score"
			case "$relays" in
				# Same reserve penalty as compare_delay in server-groups.uc.
				*" $candidate "*) compare="$(awk -v s="$score" 'BEGIN { printf "%.4f\n", s + 30 }')" ;;
				*) direct_passes=$((direct_passes + 1)) ;;
			esac
			passed="$passed$compare $candidate
"
			if [ -z "$best" ] || awk -v a="$compare" -v b="$best_compare" 'BEGIN {exit !(a<b)}'; then
				best="$candidate"
				best_score="$score"
				best_compare="$compare"
			fi
		elif [ "$probe_rc" -eq 2 ]; then
			# Not enough memory or a foreign listener: stop probing, change nothing.
			low_memory=1
			tried=$((tried - 1))
			break
		else
			log "grouped candidate index $candidate failed tunnel checks"
			record_score "$candidate" fail
			relay_failed
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
	elif [ "$GROUP_ACTION" = --choose-all ]; then
		# Connect to the best one and make sure the live tunnel carries traffic;
		# otherwise the next best that passed, and the previous one as last resort.
		relay_probes=
		if ! connect_and_verify auto $(printf '%s' "$passed" | sort -n | awk '{ printf "%s ", $2 }'); then
			log "no passed connection works as the live tunnel; returning to index $old_selection"
			revert_connection || true
			set_phase failed
			return 1
		fi
		best="$connected"
	else
		SHPUN_SELECTION_SOURCE="$probe_dir/subscription.json" switch_to "$best" || return 1
	fi
	if [ "$GROUP_ACTION" = --choose-all ]; then
		write_selection_value "$SERVER_AUTO_SELECT_FILE" 1 || return 1
	fi
	clear_recovery_backoff
	if [ "$interactive" = 1 ]; then
		rm -f "$LAST_ATTEMPT_FILE"
		set_phase done "$best"
		printf 'ok:%s\n' "$best" > "$AUTO_SELECT_STATUS_FILE"
	fi
	log "grouped selection $GROUP_ACTION chose index $best (tested $tried, delay ${best_score}s)"
	return 0
}


[ -f "$CONF" ] && . "$CONF"
[ -z "$AUTO_FAILOVER_COOLDOWN" ] && AUTO_FAILOVER_COOLDOWN="$AUTO_FAILOVER_COOLDOWN_DEFAULT"
[ -z "$AUTO_FAILOVER_MAX_CANDIDATES" ] && AUTO_FAILOVER_MAX_CANDIDATES="$AUTO_FAILOVER_MAX_CANDIDATES_DEFAULT"
[ -z "$GATEWAY_COOLDOWN" ] && GATEWAY_COOLDOWN="$GATEWAY_COOLDOWN_DEFAULT"
[ -z "$REALITY_BLOCK_COOLDOWN" ] && REALITY_BLOCK_COOLDOWN="$REALITY_BLOCK_COOLDOWN_DEFAULT"
[ -z "$SELECTION_RETRY" ] && SELECTION_RETRY=1
[ -z "$SELECTION_GOOD_ENOUGH" ] && SELECTION_GOOD_ENOUGH="$SELECTION_GOOD_ENOUGH_DEFAULT"
case "$SELECTION_GOOD_ENOUGH" in ""|*[!0-9]*) SELECTION_GOOD_ENOUGH="$SELECTION_GOOD_ENOUGH_DEFAULT" ;; esac
[ -z "$RELAY_PROBES_PER_GATEWAY" ] && RELAY_PROBES_PER_GATEWAY="$RELAY_PROBES_PER_GATEWAY_DEFAULT"
[ -z "$SELECTION_PROBE_GAP" ] && SELECTION_PROBE_GAP="$SELECTION_PROBE_GAP_DEFAULT"
[ -z "$AUTO_FAILOVER_READY_TIMEOUT" ] && AUTO_FAILOVER_READY_TIMEOUT="$AUTO_FAILOVER_READY_TIMEOUT_DEFAULT"
[ -z "$HTTP_PROXY_PORT" ] && HTTP_PROXY_PORT="$HTTP_PROXY_PORT_DEFAULT"
[ -z "$TUNNEL_PROBE_URL" ] && TUNNEL_PROBE_URL="$TUNNEL_PROBE_URL_DEFAULT"
[ -z "$TUNNEL_PROBE_FALLBACK_URL" ] && TUNNEL_PROBE_FALLBACK_URL="$TUNNEL_PROBE_FALLBACK_URL_DEFAULT"
[ -z "$TUNNEL_PROBE_SECONDARY_URL" ] && TUNNEL_PROBE_SECONDARY_URL="$TUNNEL_PROBE_SECONDARY_URL_DEFAULT"
[ -z "$TUNNEL_QUALITY_PROBE_URL" ] && TUNNEL_QUALITY_PROBE_URL="$TUNNEL_QUALITY_PROBE_URL_DEFAULT"
[ -z "$TUNNEL_QUALITY_PROBE_MIN_BYTES" ] && TUNNEL_QUALITY_PROBE_MIN_BYTES="$TUNNEL_QUALITY_PROBE_MIN_BYTES_DEFAULT"
[ -z "$TUNNEL_QUALITY_CONFIRM_URLS" ] && TUNNEL_QUALITY_CONFIRM_URLS="$TUNNEL_QUALITY_CONFIRM_URLS_DEFAULT"
[ -z "$TUNNEL_QUALITY_CONFIRM_MIN_SUCCESS" ] && TUNNEL_QUALITY_CONFIRM_MIN_SUCCESS="$TUNNEL_QUALITY_CONFIRM_MIN_SUCCESS_DEFAULT"
[ -z "$SELECTION_RTT_URL" ] && SELECTION_RTT_URL="$SELECTION_RTT_URL_DEFAULT"

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
case "$GROUP_ACTION" in --choose-all|--choose-server|--connect-server|--measure) interactive=1 ;; esac
case "$GROUP_ACTION" in --initial|--choose-all|--choose-server|--connect-server|--measure|--recover-quality|--recover-failed) shift ;; *) GROUP_ACTION= ;; esac
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
