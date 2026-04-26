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
CHUNK_SIZE_DEFAULT=250

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
    if [ -f "$MODE_FILE" ]; then
        tr -d '\r\n' < "$MODE_FILE"
    else
        echo "full"
    fi
}

check_tproxy() {
    if [ -d /sys/module/xt_TPROXY ] || \
       grep -q "xt_TPROXY" /proc/modules 2>/dev/null || \
       modprobe xt_TPROXY 2>/dev/null; then
        return 0
    fi
    cat /proc/net/ip_tables_targets 2>/dev/null | grep -qi tproxy && return 0
    return 1
}

tproxy_routes_add() {
    ip rule show | grep -q "fwmark 0x${TPROXY_MARK}" || \
        ip rule add fwmark "0x${TPROXY_MARK}" table "$TPROXY_TABLE" 2>/dev/null
    ip route show table "$TPROXY_TABLE" | grep -q "local default" || \
        ip route add local default dev lo table "$TPROXY_TABLE" 2>/dev/null
    log "tproxy: ip rule/route added (mark=0x${TPROXY_MARK}, table=${TPROXY_TABLE})"
}

tproxy_routes_del() {
    ip rule del fwmark "0x${TPROXY_MARK}" table "$TPROXY_TABLE" 2>/dev/null
    ip route del local default dev lo table "$TPROXY_TABLE" 2>/dev/null
    log "tproxy: ip rule/route removed"
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
    iptables -t mangle -D PREROUTING -i "$LAN_IF" -j SHPUN_XRAY_UDP 2>/dev/null
    iptables -t mangle -F SHPUN_XRAY_UDP 2>/dev/null
    iptables -t mangle -X SHPUN_XRAY_UDP 2>/dev/null
}

# ──────────────────────────────────────────────
# nftables: построение правил
#
# Порядок правил в prerouting (приоритет сверху вниз):
#   1. ip daddr $LAN_IP        → return         (сам роутер)
#   2. ip daddr @custom_direct → return         (юзер: напрямую)
#   3. ip daddr @custom_vpn    → redirect/tproxy (юзер: принудительно в VPN)
#   4. ip daddr @ru_dst        → return         (split_ru: РФ напрямую)
#   5. основное правило        → redirect/tproxy
# ──────────────────────────────────────────────
nft_build_rules() {
    LAN_IF="$1"
    LAN_IP="$2"
    MODE="$3"
    TMP_RULES="$4"
    CHUNK_SIZE_LOCAL="$5"
    WITH_TPROXY="$6"

    {
        echo "add table inet shpun"

        [ "$MODE" = "split_ru" ] && \
            echo "add set inet shpun ru_dst { type ipv4_addr; flags interval; }"

        # Пустые sets для кастомных маршрутов — всегда создаём
        echo "add set inet shpun custom_direct { type ipv4_addr; flags interval; }"
        echo "add set inet shpun custom_vpn { type ipv4_addr; flags interval; }"

        # ── TCP nat prerouting ──
        echo "add chain inet shpun prerouting { type nat hook prerouting priority dstnat; policy accept; }"
        echo "add rule inet shpun prerouting iifname \"$LAN_IF\" ip daddr $LAN_IP return"
        echo "add rule inet shpun prerouting iifname \"$LAN_IF\" ip daddr @custom_direct return"
        echo "add rule inet shpun prerouting iifname \"$LAN_IF\" meta l4proto tcp ip daddr @custom_vpn redirect to :$REDIR_PORT"
        [ "$MODE" = "split_ru" ] && \
            echo "add rule inet shpun prerouting iifname \"$LAN_IF\" ip daddr @ru_dst return"
        echo "add rule inet shpun prerouting iifname \"$LAN_IF\" meta l4proto tcp tcp dport != $REDIR_PORT redirect to :$REDIR_PORT"

        # ── UDP mangle tproxy ──
        if [ "$WITH_TPROXY" = "yes" ]; then
            echo "add chain inet shpun prerouting_mangle { type filter hook prerouting priority mangle; policy accept; }"
            echo "add rule inet shpun prerouting_mangle iifname \"$LAN_IF\" ip daddr $LAN_IP return"
            echo "add rule inet shpun prerouting_mangle iifname \"$LAN_IF\" ip daddr @custom_direct return"
            echo "add rule inet shpun prerouting_mangle iifname \"$LAN_IF\" ip daddr { 224.0.0.0/4, 255.255.255.255 } return"
            [ "$MODE" = "split_ru" ] && \
                echo "add rule inet shpun prerouting_mangle iifname \"$LAN_IF\" ip daddr @ru_dst return"
            echo "add rule inet shpun prerouting_mangle iifname \"$LAN_IF\" meta l4proto udp ip daddr @custom_vpn tproxy to :$TPROXY_PORT meta mark set 0x${TPROXY_MARK}"
            echo "add rule inet shpun prerouting_mangle iifname \"$LAN_IF\" meta l4proto udp tproxy to :$TPROXY_PORT meta mark set 0x${TPROXY_MARK}"
        fi

        # ── Наполняем ru_dst ──
        if [ "$MODE" = "split_ru" ]; then
            chunk=""
            count=0
            while IFS= read -r cidr; do
                [ -z "$cidr" ] && continue
                cidr="$(printf '%s' "$cidr" | tr -d '\r')"
                [ -z "$cidr" ] && continue
                chunk="${chunk:+$chunk, }$cidr"
                count=$((count + 1))
                if [ "$count" -ge "$CHUNK_SIZE_LOCAL" ]; then
                    echo "add element inet shpun ru_dst { $chunk }"
                    chunk=""
                    count=0
                fi
            done < "$CIDRS_FILE"
            [ -n "$chunk" ] && echo "add element inet shpun ru_dst { $chunk }"
        fi

    } > "$TMP_RULES"
}

nft_apply_mode() {
    LAN_IF="$(uci get network.lan.device 2>/dev/null || uci get network.lan.ifname 2>/dev/null || echo br-lan)"
    LAN_IP="$(uci get network.lan.ipaddr 2>/dev/null || echo 192.168.1.1)"
    MODE="$(get_mode)"

    nft list table inet shpun >/dev/null 2>&1 || {
        log "apply-mode: table not found, running init"
        nft_init; return $?
    }

    WITH_TPROXY="no"
    nft list chain inet shpun prerouting_mangle >/dev/null 2>&1 && WITH_TPROXY="yes"

    if [ "$MODE" = "split_ru" ]; then
        nft list set inet shpun ru_dst >/dev/null 2>&1 || {
            log "apply-mode: ru_dst not found, running init"
            nft_init; return $?
        }
    fi

    log "apply-mode: mode=$MODE tproxy=$WITH_TPROXY"

    nft flush chain inet shpun prerouting || return 1

    nft add rule inet shpun prerouting iifname "$LAN_IF" ip daddr "$LAN_IP" return
    nft add rule inet shpun prerouting iifname "$LAN_IF" ip daddr @custom_direct return
    nft add rule inet shpun prerouting iifname "$LAN_IF" meta l4proto tcp \
        ip daddr @custom_vpn redirect to :"$REDIR_PORT"

    if [ "$MODE" = "split_ru" ]; then
        nft flush set inet shpun ru_dst
        if [ -s "$CIDRS_FILE" ]; then
            chunk=""; count=0
            while IFS= read -r cidr; do
                [ -z "$cidr" ] && continue
                cidr="$(printf '%s' "$cidr" | tr -d '\r')"
                [ -z "$cidr" ] && continue
                chunk="${chunk:+$chunk, }$cidr"
                count=$((count + 1))
                if [ "$count" -ge "$CHUNK_SIZE" ]; then
                    nft add element inet shpun ru_dst "{ $chunk }"
                    chunk=""; count=0
                fi
            done < "$CIDRS_FILE"
            [ -n "$chunk" ] && nft add element inet shpun ru_dst "{ $chunk }"
        fi
        nft add rule inet shpun prerouting iifname "$LAN_IF" ip daddr @ru_dst return
    fi

    nft add rule inet shpun prerouting iifname "$LAN_IF" meta l4proto tcp \
        tcp dport != "$REDIR_PORT" redirect to :"$REDIR_PORT"

    if [ "$WITH_TPROXY" = "yes" ]; then
        nft flush chain inet shpun prerouting_mangle
        nft add rule inet shpun prerouting_mangle iifname "$LAN_IF" ip daddr "$LAN_IP" return
        nft add rule inet shpun prerouting_mangle iifname "$LAN_IF" ip daddr @custom_direct return
        nft add rule inet shpun prerouting_mangle iifname "$LAN_IF" \
            ip daddr "{ 224.0.0.0/4, 255.255.255.255 }" return
        [ "$MODE" = "split_ru" ] && \
            nft add rule inet shpun prerouting_mangle iifname "$LAN_IF" ip daddr @ru_dst return
        nft add rule inet shpun prerouting_mangle iifname "$LAN_IF" meta l4proto udp \
            ip daddr @custom_vpn tproxy to :"$TPROXY_PORT" meta mark set "0x${TPROXY_MARK}"
        nft add rule inet shpun prerouting_mangle iifname "$LAN_IF" meta l4proto udp \
            tproxy to :"$TPROXY_PORT" meta mark set "0x${TPROXY_MARK}"
    fi

    [ -x "$CUSTOM_SCRIPT" ] && \
        "$CUSTOM_SCRIPT" apply 2>/dev/null || true

    return 0
}

nft_init() {
    LAN_IF="$(uci get network.lan.device 2>/dev/null || uci get network.lan.ifname 2>/dev/null || echo br-lan)"
    LAN_IP="$(uci get network.lan.ipaddr 2>/dev/null || echo 192.168.1.1)"
    MODE="$(get_mode)"
    TMP_RULES="/tmp/shpun_firewall.nft"

    [ "$MODE" = "split_ru" ] && [ ! -s "$CIDRS_FILE" ] && {
        log "nft init: split_ru but $CIDRS_FILE missing"
        return 1
    }

    WITH_TPROXY="no"
    if check_tproxy; then
        WITH_TPROXY="yes"
        tproxy_routes_add
        log "nft init: tproxy OK (port=$TPROXY_PORT mark=0x${TPROXY_MARK})"
    else
        log "nft init: tproxy unavailable — TCP-only"
    fi

    log "nft init: mode=$MODE tproxy=$WITH_TPROXY redirect=$REDIR_PORT lan=$LAN_IF"

    nft delete table inet shpun 2>/dev/null
    nft_build_rules "$LAN_IF" "$LAN_IP" "$MODE" "$TMP_RULES" "$CHUNK_SIZE" "$WITH_TPROXY"

    if ! nft -f "$TMP_RULES" >/dev/null 2>&1; then
        log "nft init: failed to apply rules"
        if [ "$WITH_TPROXY" = "yes" ]; then
            log "nft init: retry without tproxy"
            tproxy_routes_del
            nft_build_rules "$LAN_IF" "$LAN_IP" "$MODE" "$TMP_RULES" "$CHUNK_SIZE" "no"
            if ! nft -f "$TMP_RULES" >/dev/null 2>&1; then
                log "nft init: fallback failed"
                rm -f "$TMP_RULES"
                return 1
            fi
            log "nft init: TCP-only fallback active"
        else
            rm -f "$TMP_RULES"
            return 1
        fi
    fi

    rm -f "$TMP_RULES"

    # Наполняем custom sets
    [ -x "$CUSTOM_SCRIPT" ] && \
        "$CUSTOM_SCRIPT" apply 2>/dev/null || true

    return 0
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
        command -v iptables >/dev/null 2>&1 && { iptables_start && exit 0; }
        log "no nft/iptables found"; exit 1
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
        command -v iptables >/dev/null 2>&1 && iptables_stop
        exit 0
        ;;
    restart)
        "$0" apply-mode; exit $?
        ;;
    *)
        echo "Usage: $0 [start|init|apply-mode|stop|restart]" >&2
        exit 1
        ;;
esac