#!/bin/sh

LOGTAG="shpun-offload"
BACKUP="/etc/config/firewall.before-shpun-offload"
CHANGED=0
NEEDS_RESTART=0

log() {
	logger -t "$LOGTAG" "$*"
}

command -v uci >/dev/null 2>&1 || exit 0
uci -q get firewall.@defaults[0] >/dev/null 2>&1 || exit 0

for option in flow_offloading flow_offloading_hw; do
	current="$(uci -q get "firewall.@defaults[0].$option" 2>/dev/null || echo 0)"
	[ "$current" = "0" ] && continue

	if [ ! -e "$BACKUP" ]; then
		cp /etc/config/firewall "$BACKUP" 2>/dev/null || true
	fi

	uci -q set "firewall.@defaults[0].$option=0"
	CHANGED=1
	NEEDS_RESTART=1
done

if command -v nft >/dev/null 2>&1 &&
	nft list ruleset 2>/dev/null | grep -Eq 'flowtable|flow add'; then
	NEEDS_RESTART=1
fi

if [ "$CHANGED" -eq 1 ]; then
	uci -q commit firewall
	log "disabled software and hardware flow offloading; transparent VPN requires nftables visibility"
fi

if [ "${1:-}" = "apply" ] && [ "$NEEDS_RESTART" -eq 1 ]; then
	/etc/init.d/firewall restart >/dev/null 2>&1 || {
		log "firewall restart failed after disabling flow offloading"
		exit 1
	}
	log "firewall restarted after disabling flow offloading"
fi

exit 0
