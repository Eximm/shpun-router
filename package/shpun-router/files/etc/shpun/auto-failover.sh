#!/bin/sh

STATE_DIR="${STATE_DIR:-/etc/shpun}"
CONF="${CONF:-$STATE_DIR/agent.conf}"
SUB_FILE="${SUB_FILE:-$STATE_DIR/subscription.json}"
SELECTED_LINK_FILE="${SELECTED_LINK_FILE:-$STATE_DIR/selected_link_index}"
SWITCH_SCRIPT="${SWITCH_SCRIPT:-$STATE_DIR/switch-server.sh}"
VPN_READY_FILE="${VPN_READY_FILE:-$STATE_DIR/vpn_ready}"
LAST_ATTEMPT_FILE="$STATE_DIR/auto_failover_last_attempt"
LAST_SUCCESS_FILE="$STATE_DIR/auto_failover_last_success"
FROM_FILE="$STATE_DIR/auto_failover_from"
LOCKDIR="/tmp/shpun-auto-failover.lock"
LOGTAG="shpun-failover"

AUTO_FAILOVER_COOLDOWN_DEFAULT=600
AUTO_FAILOVER_MAX_CANDIDATES_DEFAULT=16
AUTO_FAILOVER_READY_TIMEOUT_DEFAULT=30
HTTP_PROXY_PORT_DEFAULT=10809
TUNNEL_PROBE_URL_DEFAULT="http://api.ipify.org"
TUNNEL_PROBE_FALLBACK_URL_DEFAULT="http://cp.cloudflare.com/generate_204"
TUNNEL_PROBE_SECONDARY_URL_DEFAULT="http://connectivitycheck.gstatic.com/generate_204"
TUNNEL_QUALITY_PROBE_URL_DEFAULT="https://speed.cloudflare.com/__down?bytes=8192"
TUNNEL_QUALITY_PROBE_MIN_BYTES_DEFAULT=8192

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

probe_url_through_tunnel() {
	url="$1"
	proxy="http://127.0.0.1:${HTTP_PROXY_PORT}"

	case "$HTTP_BIN" in
		curl)
			curl -fsS -A ShpunRouter -m 6 -x "$proxy" -o /dev/null "$url" >/dev/null 2>&1
			;;
		uclient-fetch)
			env http_proxy="$proxy" HTTP_PROXY="$proxy" \
				uclient-fetch -q -U ShpunRouter -T 6 -Y on -O /dev/null "$url" >/dev/null 2>&1
			;;
		wget)
			env http_proxy="$proxy" HTTP_PROXY="$proxy" \
				wget -q -U ShpunRouter -T 6 -Y on -O /dev/null "$url" >/dev/null 2>&1
			;;
		*) return 1 ;;
	esac
}

probe_tunnel_quality() {
	proxy="http://127.0.0.1:${HTTP_PROXY_PORT}"
	tmp="/tmp/shpun-failover-quality.$$"
	[ "$HTTP_BIN" = "curl" ] || return 0
	rm -f "$tmp"

	if ! curl -fsSL -A ShpunRouter -m 8 -x "$proxy" -o "$tmp" "$TUNNEL_QUALITY_PROBE_URL" >/dev/null 2>&1; then
		rm -f "$tmp"
		return 1
	fi

	bytes="$(wc -c < "$tmp" 2>/dev/null | tr -d ' ')"
	rm -f "$tmp"
	case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
	[ "$bytes" -ge "$TUNNEL_QUALITY_PROBE_MIN_BYTES" ]
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
	result="$(SHPUN_AUTO_FAILOVER=1 "$SWITCH_SCRIPT" "$index" 2>/dev/null)" || {
		log "server index $index rejected during automatic failover: ${result:-switch_failed}"
		return 1
	}
	[ "$result" = "ok" ] || {
		log "server index $index rejected during automatic failover: ${result:-unknown_error}"
		return 1
	}
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

case "$AUTO_FAILOVER_COOLDOWN" in ''|*[!0-9]*) AUTO_FAILOVER_COOLDOWN="$AUTO_FAILOVER_COOLDOWN_DEFAULT" ;; esac
case "$AUTO_FAILOVER_MAX_CANDIDATES" in ''|*[!0-9]*) AUTO_FAILOVER_MAX_CANDIDATES="$AUTO_FAILOVER_MAX_CANDIDATES_DEFAULT" ;; esac
case "$AUTO_FAILOVER_READY_TIMEOUT" in ''|*[!0-9]*) AUTO_FAILOVER_READY_TIMEOUT="$AUTO_FAILOVER_READY_TIMEOUT_DEFAULT" ;; esac
case "$TUNNEL_QUALITY_PROBE_MIN_BYTES" in ''|*[!0-9]*) TUNNEL_QUALITY_PROBE_MIN_BYTES="$TUNNEL_QUALITY_PROBE_MIN_BYTES_DEFAULT" ;; esac

lock_acquire || exit 0

[ -s "$SUB_FILE" ] && [ -x "$SWITCH_SCRIPT" ] || {
	log "automatic failover is not ready: subscription or switch script is missing"
	exit 1
}

detect_http_client
[ -n "$HTTP_BIN" ] || {
	log "automatic failover is not ready: no HTTP client"
	exit 1
}

now="$(date +%s 2>/dev/null || echo 0)"
last="$(cat "$LAST_ATTEMPT_FILE" 2>/dev/null | tr -d '\r\n ' || echo 0)"
case "$now" in ''|*[!0-9]*) now=0 ;; esac
case "$last" in ''|*[!0-9]*) last=0 ;; esac
age=$((now - last))
if [ "$last" -gt 0 ] && [ "$age" -ge 0 ] && [ "$age" -lt "$AUTO_FAILOVER_COOLDOWN" ]; then
	log "automatic failover cooldown is active (${age}s/${AUTO_FAILOVER_COOLDOWN}s)"
	exit 0
fi
printf '%s\n' "$now" > "$LAST_ATTEMPT_FILE"

current="$(cat "$SELECTED_LINK_FILE" 2>/dev/null | tr -d '\r\n ' || echo 0)"
case "$current" in ''|*[!0-9]*) current=0 ;; esac
count="$(jsonfilter -i "$SUB_FILE" -e '@.subscription.links[*]' 2>/dev/null | wc -l | tr -d ' ')"
case "$count" in ''|*[!0-9]*) count=0 ;; esac
[ "$count" -gt 1 ] || {
	log "automatic failover cannot run: subscription has $count server(s)"
	exit 1
}
[ "$current" -lt "$count" ] || current=0

limit="$AUTO_FAILOVER_MAX_CANDIDATES"
[ "$limit" -gt 0 ] 2>/dev/null || limit="$AUTO_FAILOVER_MAX_CANDIDATES_DEFAULT"
[ "$limit" -lt "$count" ] || limit=$((count - 1))

log "tunnel failure confirmed; trying up to $limit alternative servers from current index $current"
offset=1
tried=0
while [ "$offset" -lt "$count" ] && [ "$tried" -lt "$limit" ]; do
	candidate=$(((current + offset) % count))
	offset=$((offset + 1))
	tried=$((tried + 1))

	log "trying server index $candidate ($tried/$limit)"
	if switch_to "$candidate" && wait_for_candidate; then
		printf '%s\n' "$current" > "$FROM_FILE"
		date +%s > "$LAST_SUCCESS_FILE" 2>/dev/null || true
		log "automatic failover succeeded: server index $current -> $candidate"
		exit 0
	fi
	log "server index $candidate did not restore the tunnel"
done

log "no tested server restored the tunnel; returning to original index $current"
switch_to "$current" || true
exit 1
