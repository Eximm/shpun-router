#!/bin/sh

# /etc/shpun/firewall-xray.sh
#
# Transparent REDIRECT для Xray dokodemo-door.
#
# Режимы:
#   full     - весь TCP с LAN -> REDIR_PORT
#   split_ru - RU dst -> напрямую, остальной TCP -> REDIR_PORT
#
# Основной backend: nft
# Fallback backend: iptables

CONF="/etc/shpun/agent.conf"
ROUTES_DIR="/etc/shpun/routes"
ROUTES_MODE_FILE="$ROUTES_DIR/mode"
ROUTES_CIDRS_FILE="$ROUTES_DIR/ru.cidrs"

LOGTAG="shpun-firewall"
REDIR_PORT_DEFAULT=12345

log() {
	logger -t "$LOGTAG" "$*"
}

load_conf() {
	# shellcheck disable=SC1090,SC1091
	[ -f "$CONF" ] && . "$CONF"
	[ -z "$REDIR_PORT" ] && REDIR_PORT="$REDIR_PORT_DEFAULT"
}

load_mode() {
	MODE="full"

	if [ -f "$ROUTES_MODE_FILE" ]; then
		MODE="$(tr -d '\r\n ' < "$ROUTES_MODE_FILE" 2>/dev/null)"
	fi

	[ -z "$MODE" ] && MODE="full"
}

detect_lan() {
	LAN_IF="$(uci get network.lan.device 2>/dev/null || uci get network.lan.ifname 2>/dev/null || echo br-lan)"
	LAN_IP="$(uci get network.lan.ipaddr 2>/dev/null || echo 192.168.1.1)"
}

iptables_start() {
	log "iptables backend: applying mode=$MODE redirect=$REDIR_PORT"

	detect_lan

	iptables -t nat -N SHPUN_XRAY 2>/dev/null
	iptables -t nat -F SHPUN_XRAY 2>/dev/null

	iptables -t nat -D PREROUTING -i "$LAN_IF" -j SHPUN_XRAY 2>/dev/null
	iptables -t nat -A PREROUTING -i "$LAN_IF" -j SHPUN_XRAY

	iptables -t nat -A SHPUN_XRAY -d "$LAN_IP" -j RETURN

	# split_ru в iptables fallback пока не реализуем,
	# чтобы не тащить ipset в минимальную реализацию пакета.
	if [ "$MODE" = "split_ru" ]; then
		log "iptables backend: split_ru requested, but fallback backend supports full only"
	fi

	iptables -t nat -A SHPUN_XRAY -p tcp -j REDIRECT --to-ports "$REDIR_PORT"
}

iptables_stop() {
	log "iptables backend: removing SHPUN_XRAY rules"

	detect_lan

	iptables -t nat -D PREROUTING -i "$LAN_IF" -j SHPUN_XRAY 2>/dev/null
	iptables -t nat -F SHPUN_XRAY 2>/dev/null
	iptables -t nat -X SHPUN_XRAY 2>/dev/null
}

nft_build_batch() {
	TMP_NFT="/tmp/shpun_firewall.nft"

	{
		echo "add table inet shpun"

		if [ "$MODE" = "split_ru" ] && [ -s "$ROUTES_CIDRS_FILE" ]; then
			echo "add set inet shpun ru_dst { type ipv4_addr; flags interval; }"
			printf "add element inet shpun ru_dst { "

			first=1
			while IFS= read -r cidr; do
				[ -n "$cidr" ] || continue

				if [ "$first" -eq 1 ]; then
					printf "%s" "$cidr"
					first=0
				else
					printf ", %s" "$cidr"
				fi
			done < "$ROUTES_CIDRS_FILE"

			echo " }"
		elif [ "$MODE" = "split_ru" ]; then
			log "nft backend: split_ru requested but routes file missing, fallback to full behavior"
		fi

		echo "add chain inet shpun prerouting { type nat hook prerouting priority dstnat; policy accept; }"
		echo "add rule inet shpun prerouting iifname \"$LAN_IF\" ip daddr $LAN_IP return"

		if [ "$MODE" = "split_ru" ] && [ -s "$ROUTES_CIDRS_FILE" ]; then
			echo "add rule inet shpun prerouting iifname \"$LAN_IF\" ip daddr @ru_dst return"
		fi

		echo "add rule inet shpun prerouting iifname \"$LAN_IF\" tcp dport != $REDIR_PORT redirect to :$REDIR_PORT"
	} > "$TMP_NFT"
}

nft_start() {
	detect_lan
	log "nft backend: applying mode=$MODE redirect=$REDIR_PORT lan_if=$LAN_IF lan_ip=$LAN_IP"

	nft delete table inet shpun 2>/dev/null

	nft_build_batch

	if ! nft -f /tmp/shpun_firewall.nft 2>/dev/null; then
		log "nft backend: failed to apply generated rules"
		return 1
	fi

	return 0
}

nft_stop() {
	log "nft backend: removing table inet shpun"
	nft delete table inet shpun 2>/dev/null
}

case "$1" in
	start|"")
		load_conf
		load_mode

		if command -v nft >/dev/null 2>&1; then
			nft_start && exit 0
			log "nft backend failed, trying iptables fallback"
		fi

		if command -v iptables >/dev/null 2>&1; then
			iptables_start
			exit 0
		fi

		log "no nft/iptables found"
		;;

	stop)
		if command -v nft >/dev/null 2>&1; then
			nft_stop
		fi

		if command -v iptables >/dev/null 2>&1; then
			iptables_stop
		fi
		;;

	restart)
		"$0" stop
		"$0" start
		;;

	*)
		echo "Usage: $0 [start|stop|restart]" >&2
		exit 1
		;;
esac

exit 0