#!/bin/sh

CONF="/etc/shpun/agent.conf"
LOGTAG="shpun-firewall"
ROUTES_DIR="/etc/shpun/routes"
MODE_FILE="$ROUTES_DIR/mode"
CIDRS_FILE="$ROUTES_DIR/ru.cidrs"

REDIR_PORT_DEFAULT=12345

log() {
    logger -t "$LOGTAG" "$*"
}

load_conf() {
    # shellcheck disable=SC1090,SC1091
    [ -f "$CONF" ] && . "$CONF"
    [ -z "$REDIR_PORT" ] && REDIR_PORT="$REDIR_PORT_DEFAULT"
}

get_mode() {
    if [ -f "$MODE_FILE" ]; then
        tr -d '\r\n' < "$MODE_FILE"
    else
        echo "full"
    fi
}

iptables_start() {
    log "iptables backend is not supported for routing modes on this build"
    return 1
}

iptables_stop() {
    LAN_IF="$(uci get network.lan.device 2>/dev/null || uci get network.lan.ifname 2>/dev/null || echo br-lan)"
    iptables -t nat -D PREROUTING -i "$LAN_IF" -j SHPUN_XRAY 2>/dev/null
    iptables -t nat -F SHPUN_XRAY 2>/dev/null
    iptables -t nat -X SHPUN_XRAY 2>/dev/null
}

nft_build_rules() {
    LAN_IF="$1"
    LAN_IP="$2"
    MODE="$3"
    TMP_RULES="$4"

    {
        echo "add table inet shpun"
        if [ "$MODE" = "split_ru" ]; then
            echo "add set inet shpun ru_dst { type ipv4_addr; flags interval; }"
            echo "add element inet shpun ru_dst {"
            first=1
            while IFS= read -r cidr; do
                [ -z "$cidr" ] && continue
                if [ "$first" -eq 1 ]; then
                    printf "    %s" "$cidr"
                    first=0
                else
                    printf ",\n    %s" "$cidr"
                fi
            done < "$CIDRS_FILE"
            echo
            echo "}"
        fi

        echo "add chain inet shpun prerouting { type nat hook prerouting priority dstnat; policy accept; }"
        echo "add rule inet shpun prerouting iifname \"$LAN_IF\" ip daddr $LAN_IP return"

        if [ "$MODE" = "split_ru" ]; then
            echo "add rule inet shpun prerouting iifname \"$LAN_IF\" ip daddr @ru_dst return"
        fi

        echo "add rule inet shpun prerouting iifname \"$LAN_IF\" tcp dport != $REDIR_PORT redirect to :$REDIR_PORT"
    } > "$TMP_RULES"
}

nft_start() {
    LAN_IF="$(uci get network.lan.device 2>/dev/null || uci get network.lan.ifname 2>/dev/null || echo br-lan)"
    LAN_IP="$(uci get network.lan.ipaddr 2>/dev/null || echo 192.168.1.1)"
    MODE="$(get_mode)"
    TMP_RULES="/tmp/shpun_firewall.nft"

    log "nft backend: applying mode=$MODE redirect=$REDIR_PORT lan_if=$LAN_IF lan_ip=$LAN_IP"

    nft delete table inet shpun 2>/dev/null

    if [ "$MODE" = "split_ru" ]; then
        if [ ! -s "$CIDRS_FILE" ]; then
            log "nft backend: split_ru requested but $CIDRS_FILE missing or empty"
            return 1
        fi
    fi

    nft_build_rules "$LAN_IF" "$LAN_IP" "$MODE" "$TMP_RULES"

    if ! nft -f "$TMP_RULES" >/dev/null 2>&1; then
        log "nft backend: failed to apply generated rules"
        rm -f "$TMP_RULES"
        return 1
    fi

    rm -f "$TMP_RULES"
    return 0
}

nft_stop() {
    log "nft backend: removing table inet shpun"
    nft delete table inet shpun 2>/dev/null
}

case "$1" in
    start|"")
        load_conf

        if command -v nft >/dev/null 2>&1; then
            nft_start && exit 0
            log "nft backend failed, trying iptables fallback"
        fi

        if command -v iptables >/dev/null 2>&1; then
            iptables_start && exit 0
        fi

        log "no nft/iptables found"
        exit 1
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