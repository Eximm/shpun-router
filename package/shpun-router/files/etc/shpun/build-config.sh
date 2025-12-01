#!/bin/sh
# shellcheck disable=SC1090

SUB_FILE="/etc/shpun/subscription.json"
OUT_CFG="/etc/shpun/xray.json"
CONF="/etc/shpun/agent.conf"

# Подхватываем опции, если есть (REDIR_PORT и т.п.)
[ -f "$CONF" ] && . "$CONF"

[ -f "$SUB_FILE" ] || {
    logger -t shpun-build "No subscription file: $SUB_FILE"
    exit 1
}

# Проверяем, что есть base64/JSONFILTER
command -v jsonfilter >/dev/null 2>&1 || {
    logger -t shpun-build "jsonfilter not found"
    exit 1
}

command -v base64 >/dev/null 2>&1 || {
    logger -t shpun-build "base64 not found"
    exit 1
}

# первый линк из массива links[0] (теперь это ss://)
LINK="$(jsonfilter -i "$SUB_FILE" -e '@.subscription.links[0]' 2>/dev/null)"

[ -n "$LINK" ] || {
    logger -t shpun-build "No links[0] in subscription"
    exit 1
}

# убираем кавычки, если jsonfilter вернул с ними
LINK="${LINK%\"}"
LINK="${LINK#\"}"

case "$LINK" in
    ss://*) ;;
    *)
        logger -t shpun-build "Invalid link scheme (expected ss://): $LINK"
        exit 1
        ;;
esac

# --- Вспомогательная функция для правки URL-safe base64 ---
fix_b64() {
    # Заменяем URL-safe символы и добиваем padding до кратности 4
    local s="$1"
    s="${s//-/+}"
    s="${s//_/\/}"
    case $((${#s} % 4)) in
        2) s="${s}==";;
        3) s="${s}=";;
    esac
    printf '%s' "$s"
}

# --- Парсинг SS-линка ---
# Возможные варианты:
# 1) ss://BASE64(method:password@host:port)#NAME
# 2) ss://method:password@host:port#NAME
# 3) ss://BASE64(method:password@host:port)?plugin=...#NAME

LINK_NO_PROTO="${LINK#ss://}"

METHOD=""
PASSWORD=""
SERVER=""
PORT=""

# Отделяем часть до ?/# — это или base64, или метод:пароль@хост:порт
BASE_PART="${LINK_NO_PROTO%%[\?#]*}"

if echo "$BASE_PART" | grep -q '@'; then
    # Вариант 2: уже в открытом виде method:password@host:port
    CRED_HOSTPORT="$BASE_PART"
else
    # Вариант 1/3: base64(method:password@host:port)
    B64_FIXED="$(fix_b64 "$BASE_PART")"
    DECODED="$(printf '%s' "$B64_FIXED" | base64 -d 2>/dev/null)"

    [ -n "$DECODED" ] || {
        logger -t shpun-build "Failed to base64-decode ss link payload"
        exit 1
    }

    CRED_HOSTPORT="$DECODED"
fi

# Теперь CRED_HOSTPORT в формате method:password@host:port
CRED="${CRED_HOSTPORT%%@*}"
HOSTPORT="${CRED_HOSTPORT#*@}"

METHOD="${CRED%%:*}"
PASSWORD="${CRED#*:}"
SERVER="${HOSTPORT%%:*}"
PORT="${HOSTPORT##*:}"

# Валидация
if [ -z "$METHOD" ] || [ -z "$PASSWORD" ] || [ -z "$SERVER" ] || [ -z "$PORT" ]; then
    logger -t shpun-build "Invalid SS link: method='$METHOD' password='$PASSWORD' server='$SERVER' port='$PORT'"
    exit 1
fi

case "$PORT" in
    *[!0-9]*)
        logger -t shpun-build "Invalid port in SS link: '$PORT'"
        exit 1
        ;;
esac

# Порт для прозрачного dokodemo-door inbound.
# Должен совпадать с тем, что будет использоваться в firewall-xray.sh (REDIRECT).
REDIR_PORT="${REDIR_PORT:-12345}"

# Собираем конфиг Xray:
#  - inbound-1: SOCKS на 127.0.0.1:10808 (для отладки, curl --socks5)
#  - inbound-2: dokodemo-door 0.0.0.0:$REDIR_PORT (followRedirect=true для прозрачного TCP)
#  - outbound: shadowsocks (наш ROUTER SS 2095 через RUinn → ядро)
#  - outbound direct: свобода
#  - routing:
#       * LAN / loopback / сам сервер → direct
#       * всё остальное TCP → proxy (shadowsocks)

cat >"$OUT_CFG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },

  "inbounds": [
    {
      "tag": "socks-in",
      "listen": "127.0.0.1",
      "port": 10808,
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    },
    {
      "tag": "redir-in",
      "listen": "0.0.0.0",
      "port": $REDIR_PORT,
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp",
        "followRedirect": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],

  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "shadowsocks",
      "settings": {
        "servers": [
          {
            "address": "$SERVER",
            "port": $PORT,
            "method": "$METHOD",
            "password": "$PASSWORD"
          }
        ]
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {}
    }
  ],

  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "outboundTag": "direct",
        "ip": [
          "127.0.0.0/8",
          "10.0.0.0/8",
          "172.16.0.0/12",
          "192.168.0.0/16"
        ],
        "domain": [
          "$SERVER"
        ]
      },
      {
        "type": "field",
        "network": "tcp",
        "outboundTag": "proxy"
      }
    ]
  }
}
EOF

logger -t shpun-build "xray config built (Shadowsocks, SOCKS+REDIR, server=$SERVER:$PORT, method=$METHOD, redir_port=$REDIR_PORT)"
exit 0
