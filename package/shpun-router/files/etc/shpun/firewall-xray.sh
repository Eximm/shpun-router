#!/bin/sh

REDIR_PORT="${REDIR_PORT:-12345}"

LAN_IF="$(uci get network.lan.device 2>/dev/null || uci get network.lan.ifname 2>/dev/null || echo br-lan)"
LAN_IP="$(uci get network.lan.ipaddr 2>/dev/null || echo 192.168.1.1)"

LOGTAG="shpun-firewall"

log() {
    logger -t "$LOGTAG" "$*"
}

# если есть iptables — старый путь
if command -v iptables >/dev/null 2>&1; then
    log "iptables backend"

    iptables -t nat -N SHPUN_XRAY 2>/dev/null
    iptables -t nat -F SHPUN_XRAY

    iptables -t nat -D PREROUTING -i "$LAN_IF" -j SHPUN_XRAY 2>/dev/null
    iptables -t nat -A PREROUTING -i "$LAN_IF" -j SHPUN_XRAY

    iptables -t nat -A SHPUN_XRAY -d "$LAN_IP" -j RETURN
    iptables -t nat -A SHPUN_XRAY -p tcp -j REDIRECT --to-ports "$REDIR_PORT"
    exit 0
fi

# nft backend
if command -v nft >/dev/null 2>&1; then
    log "nft backend"

    # Удаляем старую таблицу
    nft delete table inet shpun 2>/dev/null

    # Создаём таблицу и цепочку
    nft add table inet shpun
    nft add chain inet shpun prerouting "{ type nat hook prerouting priority dstnat; policy accept; }"

    # Не проксируем трафик на IP роутера
    nft add rule inet shpun prerouting iif "$LAN_IF" ip daddr "$LAN_IP" return

    # Главное правило редиректа:
    nft add rule inet shpun prerouting iif "$LAN_IF" tcp dport != $REDIR_PORT redirect to $REDIR_PORT

    exit 0
fi

log "no nft/iptables found"
exit 0
