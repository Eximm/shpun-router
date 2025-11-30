#!/bin/sh

# Порт, на котором Xray слушает dokodemo-door.
# Должен совпадать с REDIR_PORT в build-config.sh (по умолчанию 12345).
REDIR_PORT="${REDIR_PORT:-12345}"

# LAN-интерфейс. На DSA это обычно br-lan, если что — можно переопределить в UCI.
LAN_IF="$(uci get network.lan.ifname 2>/dev/null || echo br-lan)"

# IP роутера в LAN, чтобы не проксировать доступ к LuCI и самому роутеру.
LAN_IP="$(uci get network.lan.ipaddr 2>/dev/null || echo 192.168.1.1)"

# Создаём/чистим нашу цепочку
iptables -t nat -N SHPUN_XRAY 2>/dev/null
iptables -t nat -F SHPUN_XRAY

# Убираем старый переход из PREROUTING, если был
iptables -t nat -D PREROUTING -i "$LAN_IF" -j SHPUN_XRAY 2>/dev/null

# Добавляем переход из PREROUTING в нашу цепочку
iptables -t nat -A PREROUTING -i "$LAN_IF" -j SHPUN_XRAY

# 1) Не трогаем трафик на сам роутер (чтобы LuCI, DNS и т.п. работали нормально)
iptables -t nat -A SHPUN_XRAY -d "$LAN_IP" -j RETURN

# 2) Всё остальное TCP с LAN — редиректим во Xray
iptables -t nat -A SHPUN_XRAY -p tcp -j REDIRECT --to-ports "$REDIR_PORT"
