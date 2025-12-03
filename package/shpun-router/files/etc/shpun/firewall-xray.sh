#!/bin/sh

# /etc/shpun/firewall-xray.sh
#
# Настройка прозрачного REDIRECT для Xray dokodemo-door:
#   - с LAN-интерфейса весь TCP-трафик клиентов перенаправляем на REDIR_PORT
#   - не трогаем трафик к самому роутеру (LAN_IP)
#
# Работает и с iptables, и с nft (fw4).

CONF="/etc/shpun/agent.conf"
LOGTAG="shpun-firewall"

# значения по умолчанию, если не заданы в конфиге
REDIR_PORT_DEFAULT=12345

log() {
    logger -t "$LOGTAG" "$*"
}

# Подхватываем REDIR_PORT из agent.conf (если есть)
load_conf() {
    # shellcheck disable=SC1090,SC1091
    [ -f "$CONF" ] && . "$CONF"

    [ -z "$REDIR_PORT" ] && REDIR_PORT="$REDIR_PORT_DEFAULT"
}

iptables_start() {
    log "iptables backend: applying REDIRECT to $REDIR_PORT"

    # определяем LAN_IF / LAN_IP
    LAN_IF="$(uci get network.lan.device 2>/dev/null || uci get network.lan.ifname 2>/dev/null || echo br-lan)"
    LAN_IP="$(uci get network.lan.ipaddr 2>/dev/null || echo 192.168.1.1)"

    # создаём/очищаем свою цепочку
    iptables -t nat -N SHPUN_XRAY 2>/dev/null
    iptables -t nat -F SHPUN_XRAY 2>/dev/null

    # отвязываем на всякий случай и вешаем заново
    iptables -t nat -D PREROUTING -i "$LAN_IF" -j SHPUN_XRAY 2>/dev/null
    iptables -t nat -A PREROUTING -i "$LAN_IF" -j SHPUN_XRAY

    # Не проксируем трафик на IP роутера
    iptables -t nat -A SHPUN_XRAY -d "$LAN_IP" -j RETURN

    # Всё остальное TCP → REDIR_PORT
    iptables -t nat -A SHPUN_XRAY -p tcp -j REDIRECT --to-ports "$REDIR_PORT"
}

iptables_stop() {
    log "iptables backend: removing SHPUN_XRAY rules"

    LAN_IF="$(uci get network.lan.device 2>/dev/null || uci get network.lan.ifname 2>/dev/null || echo br-lan)"

    # Убираем переход из PREROUTING и удаляем цепочку
    iptables -t nat -D PREROUTING -i "$LAN_IF" -j SHPUN_XRAY 2>/dev/null
    iptables -t nat -F SHPUN_XRAY 2>/dev/null
    iptables -t nat -X SHPUN_XRAY 2>/dev/null
}

nft_start() {
    log "nft backend: applying REDIRECT to $REDIR_PORT"

    LAN_IF="$(uci get network.lan.device 2>/dev/null || uci get network.lan.ifname 2>/dev/null || echo br-lan)"
    LAN_IP="$(uci get network.lan.ipaddr 2>/dev/null || echo 192.168.1.1)"

    # На всякий случай удаляем старую таблицу
    nft delete table inet shpun 2>/dev/null

    # Создаём таблицу и цепочку
    nft add table inet shpun
    nft add chain inet shpun prerouting '{ type nat hook prerouting priority dstnat; policy accept; }'

    # Не проксируем трафик на IP роутера
    nft add rule inet shpun prerouting iif "$LAN_IF" ip daddr "$LAN_IP" return

    # Главное правило редиректа:
    # весь TCP с LAN_IF, кроме уже редиректированного порта, отправляем на REDIR_PORT
    nft add rule inet shpun prerouting iif "$LAN_IF" tcp dport != $REDIR_PORT redirect to $REDIR_PORT
}

nft_stop() {
    log "nft backend: removing table inet shpun"
    nft delete table inet shpun 2>/dev/null
}

case "$1" in
    start|"")
        load_conf

        if command -v iptables >/dev/null 2>&1; then
            iptables_start
            exit 0
        fi

        if command -v nft >/dev/null 2>&1; then
            nft_start
            exit 0
        fi

        log "no nft/iptables found"
        ;;

    stop)
        if command -v iptables >/dev/null 2>&1; then
            iptables_stop
        fi

        if command -v nft >/dev/null 2>&1; then
            nft_stop
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
