#!/bin/sh

CONF="/etc/shpun/agent.conf"
LOGTAG="shpun-firewall"

ROUTES_DIR="/etc/shpun/routes"
MODE_FILE="$ROUTES_DIR/mode"
CIDRS_FILE="$ROUTES_DIR/ru.cidrs"
CUSTOM_SCRIPT="/etc/shpun/apply-custom-routes.sh"

REDIR_PORT_DEFAULT=12345
TPROXY_PORT_DEFAULT=12346
TPROXY_MARK_DEFAULT=233
TPROXY_TABLE_DEFAULT=233
CHUNK_SIZE_DEFAULT=25

log() {
    logger -t "$LOGTAG" "$*"
}

load_conf() {
    [ -f "$CONF" ] && . "$CONF"

    [ -z "$REDIR_PORT" ]   && REDIR_PORT="$REDIR_PORT_DEFAULT"
    [ -z "$TPROXY_PORT" ]  && TPROXY_PORT="$TPROXY_PORT_DEFAULT"
    [ -z "$TPROXY_MARK" ]  && TPROXY_MARK="$TPROXY_MARK_DEFAULT"
    [ -z "$TPROXY_TABLE" ] && TPROXY_TABLE="$TPROXY_TABLE_DEFAULT"
    [ -z "$CHUNK_SIZE" ]   && CHUNK_SIZE="$CHUNK_SIZE_DEFAULT"
}

get_mode() {
    mode="full"
    [ -f "$MODE_FILE" ] && mode="$(tr -d '\r\n' < "$MODE_FILE")"
    [ -z "$mode" ] && mode="full"

    case "$mode" in
        full|split_ru)
            echo "$mode"
            ;;
        *)
            log "unknown mode '$mode' — using full"
            echo "full"
            ;;
    esac
}

get_lan_if() {
    uci get network.lan.device 2>/dev/null || \
    uci get network.lan.ifname 2>/dev/null || \
    echo br-lan
}

get_lan_ip() {
    uci get network.lan.ipaddr 2>/dev/null || echo 192.168.1.1
}

check_tproxy() {
    command -v nft >/dev/null 2>&1 || return 1

    modprobe nft_tproxy 2>/dev/null || true
    modprobe nf_tproxy_ipv4 2>/dev/null || true

    nft delete table inet shpun_tproxy_test >/dev/null 2>&1 || true
    nft add table inet shpun_tproxy_test >/dev/null 2>&1 || return 1

    nft 'add chain inet shpun_tproxy_test c { type filter hook prerouting priority mangle; policy accept; }' >/dev/null 2>&1 || {
        nft delete table inet shpun_tproxy_test >/dev/null 2>&1
        return 1
    }

    nft 'add rule inet shpun_tproxy_test c meta l4proto udp tproxy ip to :12346 meta mark set 0xe9' >/dev/null 2>&1
    rc=$?

    nft delete table inet shpun_tproxy_test >/dev/null 2>&1
    return "$rc"
}

tproxy_routes_add() {
    ip rule show | grep -q "fwmark 0x${TPROXY_MARK}" || \
        ip rule add fwmark "0x${TPROXY_MARK}" table "$TPROXY_TABLE" 2>/dev/null

    ip route show table "$TPROXY_TABLE" | grep -q "local default" || \
        ip route add local default dev lo table "$TPROXY_TABLE" 2>/dev/null

    log "tproxy: ip rule/route added (mark=0x${TPROXY_MARK}, table=${TPROXY_TABLE})"
}

tproxy_routes_del() {
    while ip rule show | grep -q "fwmark 0x${TPROXY_MARK}"; do
        ip rule del fwmark "0x${TPROXY_MARK}" table "$TPROXY_TABLE" 2>/dev/null || break
    done

    ip route del local default dev lo table "$TPROXY_TABLE" 2>/dev/null
    log "tproxy: ip rule/route removed"
}

nft_add_base_objects() {
    MODE="$1"

    nft add table inet shpun || return 1

    if [ "$MODE" = "split_ru" ]; then
        nft 'add set inet shpun ru_dst { type ipv4_addr; flags interval; }' || return 1
    fi

    nft 'add set inet shpun custom_direct { type ipv4_addr; flags interval; }' || return 1
    nft 'add set inet shpun custom_vpn { type ipv4_addr; flags interval; }' || return 1
    nft 'add chain inet shpun prerouting { type nat hook prerouting priority dstnat; policy accept; }' || return 1

    return 0
}

nft_add_mangle_chain() {
    nft 'add chain inet shpun prerouting_mangle { type filter hook prerouting priority mangle; policy accept; }'
}

nft_fill_ru_dst() {
    [ -s "$CIDRS_FILE" ] || return 0

    chunk=""
    count=0
    total=0

    while IFS= read -r cidr; do
        cidr="$(printf '%s' "$cidr" | tr -d ' \t\r')"
        [ -z "$cidr" ] && continue
        case "$cidr" in \#*) continue ;; esac

        chunk="${chunk:+$chunk, }$cidr"
        count=$((count + 1))
        total=$((total + 1))

        if [ "$count" -ge "$CHUNK_SIZE" ]; then
            nft add element inet shpun ru_dst "{ $chunk }" >/dev/null 2>&1 || {
                log "ru_dst: failed to add chunk near total=$total"
                return 1
            }
            chunk=""
            count=0
        fi
    done < "$CIDRS_FILE"

    if [ -n "$chunk" ]; then
        nft add element inet shpun ru_dst "{ $chunk }" >/dev/null 2>&1 || {
            log "ru_dst: failed to add final chunk near total=$total"
            return 1
        }
    fi

    log "ru_dst: loaded $total CIDR entries"
    return 0
}

nft_apply_tcp_rules() {
    LAN_IF="$1"
    LAN_IP="$2"
    MODE="$3"

    nft flush chain inet shpun prerouting || return 1

    nft add rule inet shpun prerouting iifname "$LAN_IF" ip daddr "$LAN_IP" return || return 1
    nft add rule inet shpun prerouting iifname "$LAN_IF" ip daddr @custom_direct return || return 1
    nft add rule inet shpun prerouting iifname "$LAN_IF" ip daddr @custom_vpn ip protocol tcp redirect to :"$REDIR_PORT" || return 1

    if [ "$MODE" = "split_ru" ]; then
        nft add rule inet shpun prerouting iifname "$LAN_IF" ip daddr @ru_dst return || return 1
    fi

    nft add rule inet shpun prerouting iifname "$LAN_IF" ip protocol tcp tcp dport != "$REDIR_PORT" redirect to :"$REDIR_PORT" || return 1

    return 0
}

nft_apply_udp_rules() {
    LAN_IF="$1"
    LAN_IP="$2"
    MODE="$3"

    nft list chain inet shpun prerouting_mangle >/dev/null 2>&1 || nft_add_mangle_chain || return 1
    nft flush chain inet shpun prerouting_mangle || return 1

    nft add rule inet shpun prerouting_mangle iifname "$LAN_IF" ip daddr "$LAN_IP" return || return 1
    nft add rule inet shpun prerouting_mangle iifname "$LAN_IF" ip daddr @custom_direct return || return 1
    nft add rule inet shpun prerouting_mangle iifname "$LAN_IF" ip daddr 224.0.0.0/4 return || return 1
    nft add rule inet shpun prerouting_mangle iifname "$LAN_IF" ip daddr 255.255.255.255 return || return 1

    nft add rule inet shpun prerouting_mangle iifname "$LAN_IF" meta l4proto udp ip daddr @custom_vpn tproxy ip to :"$TPROXY_PORT" meta mark set "0x${TPROXY_MARK}" || return 1

    if [ "$MODE" = "split_ru" ]; then
        nft add rule inet shpun prerouting_mangle iifname "$LAN_IF" ip daddr @ru_dst return || return 1
    fi

    nft add rule inet shpun prerouting_mangle iifname "$LAN_IF" meta l4proto udp tproxy ip to :"$TPROXY_PORT" meta mark set "0x${TPROXY_MARK}" || return 1

    return 0
}

nft_apply_custom() {
    [ -x "$CUSTOM_SCRIPT" ] && "$CUSTOM_SCRIPT" apply || true
}

nft_init() {
    LAN_IF="$(get_lan_if)"
    LAN_IP="$(get_lan_ip)"
    MODE="$(get_mode)"

    if [ "$MODE" = "split_ru" ] && [ ! -s "$CIDRS_FILE" ]; then
        log "nft init: split_ru requested but $CIDRS_FILE missing — using full mode"
        MODE="full"
    fi

    WITH_TPROXY="no"
    if check_tproxy; then
        WITH_TPROXY="yes"
        tproxy_routes_add
        log "nft init: tproxy OK (port=$TPROXY_PORT mark=0x${TPROXY_MARK})"
    else
        log "nft init: tproxy unavailable — TCP-only"
        tproxy_routes_del
    fi

    log "nft init: mode=$MODE tproxy=$WITH_TPROXY redirect=$REDIR_PORT lan=$LAN_IF chunk=$CHUNK_SIZE"

    nft delete table inet shpun 2>/dev/null

    if ! nft_add_base_objects "$MODE"; then
        log "nft init: failed to create base nft objects"
        nft delete table inet shpun 2>/dev/null
        tproxy_routes_del
        return 1
    fi

    if [ "$MODE" = "split_ru" ]; then
        if ! nft_fill_ru_dst; then
            log "nft init: failed to load ru_dst"
            nft delete table inet shpun 2>/dev/null
            tproxy_routes_del
            return 1
        fi
    fi

    nft_apply_tcp_rules "$LAN_IF" "$LAN_IP" "$MODE" || {
        log "nft init: failed to apply tcp rules"
        nft delete table inet shpun 2>/dev/null
        tproxy_routes_del
        return 1
    }

    if [ "$WITH_TPROXY" = "yes" ]; then
        nft_apply_udp_rules "$LAN_IF" "$LAN_IP" "$MODE" || {
            log "nft init: failed to apply tproxy rules, falling back to TCP-only"
            nft delete chain inet shpun prerouting_mangle 2>/dev/null
            tproxy_routes_del
            WITH_TPROXY="no"
        }
    fi

    nft_apply_custom

    log "nft init: complete mode=$MODE tproxy=$WITH_TPROXY"
    return 0
}

nft_apply_mode() {
    nft_init
}

nft_stop() {
    log "removing table inet shpun"
    nft delete table inet shpun 2>/dev/null
    tproxy_routes_del
}

case "$1" in
    start|"")
        load_conf
        command -v nft >/dev/null 2>&1 && { nft_apply_mode && exit 0; }
        log "nft not found"
        exit 1
        ;;
    init)
        load_conf
        command -v nft >/dev/null 2>&1 && { nft_init && exit 0; }
        exit 1
        ;;
    apply-mode)
        load_conf
        command -v nft >/dev/null 2>&1 && { nft_apply_mode && exit 0; }
        exit 1
        ;;
    stop)
        load_conf
        command -v nft >/dev/null 2>&1 && nft_stop
        exit 0
        ;;
    restart)
        "$0" init
        exit $?
        ;;
    *)
        echo "Usage: $0 [start|init|apply-mode|stop|restart]" >&2
        exit 1
        ;;
esac