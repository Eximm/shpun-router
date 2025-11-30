#!/bin/sh
# shellcheck disable=SC1090

SUB_FILE="/etc/shpun/subscription.json"
OUT_CFG="/etc/shpun/xray.json"
CONF="/etc/shpun/agent.conf"

# Подхватываем опции, если есть (DNS_ADDR1/2, TUN_MTU и т.п. — пока не используем)
[ -f "$CONF" ] && . "$CONF"

[ -f "$SUB_FILE" ] || {
    logger -t shpun-build "No subscription file: $SUB_FILE"
    exit 1
}

# первый линк из массива links[0] (RouterVPN → Reality)
LINK="$(jsonfilter -i "$SUB_FILE" -e '@.subscription.links[0]' 2>/dev/null)"

[ -n "$LINK" ] || {
    logger -t shpun-build "No links[0] in subscription"
    exit 1
}

# убираем кавычки, если jsonfilter вернул с ними
LINK="${LINK%\"}"
LINK="${LINK#\"}"

# ожидаем vless://UUID@server:port?security=reality&pbk=...&sid=...&spx=/...
case "$LINK" in
    vless://*) ;;
    *)
        logger -t shpun-build "Invalid link scheme (expected vless://): $LINK"
        exit 1
        ;;
esac

# убираем префикс vless://
LINK_NO_PROTO="${LINK#vless://}"

# uuid до @
UUID="${LINK_NO_PROTO%%@*}"
REST="${LINK_NO_PROTO#*@}"

# host:port до ? (example.com:443)
HOSTPORT="${REST%%\?*}"
SERVER="${HOSTPORT%%:*}"
PORT="${HOSTPORT##*:}"

# query без #...
QUERY="${REST#*\?}"
QUERY="${QUERY%%#*}"

get_param() {
    echo "$QUERY" | tr '&' '\n' | awk -F= -v k="$1" '$1==k {print $2}'
}

SECURITY="$(get_param security)"
PBK_ENC="$(get_param pbk)"
SID_ENC="$(get_param sid)"
SPX_ENC="$(get_param spx)"
SNI="$(get_param sni)"
TYPE="$(get_param type)"
HOST_HDR="$(get_param host)"
PATH_RAW="$(get_param path)"
FLOW="$(get_param flow)"

# --- Жёсткая проверка Reality ---
if [ "$SECURITY" != "reality" ]; then
    logger -t shpun-build "Non-Reality link, router expects Reality only (security='$SECURITY')"
    exit 1
fi

if [ -z "$PBK_ENC" ] || [ -z "$SID_ENC" ]; then
    logger -t shpun-build "Reality link missing pbk/sid (pbk='$PBK_ENC', sid='$SID_ENC')"
    exit 1
fi

PBK="$PBK_ENC"
SID="$SID_ENC"

# spx → путь для spiderX, если нет — считаем '/'
if [ -n "$SPX_ENC" ]; then
    SPX_DEC="$(printf '%s' "$SPX_ENC" | sed -e 's/%2[Ff]/\//g')"
else
    SPX_DEC="/"
fi

case "$SPX_DEC" in
    /*) ;;
    *) SPX_DEC="/$SPX_DEC" ;;
esac

# path из query, если spx отсутствует
if [ -n "$PATH_RAW" ] && [ "$SPX_DEC" = "/" ]; then
    PATH_DEC="$(printf '%s' "$PATH_RAW" | sed -e 's/%2[Ff]/\//g')"
    [ -z "$PATH_DEC" ] && PATH_DEC="/"
    case "$PATH_DEC" in
        /*) ;;
        *) PATH_DEC="/$PATH_DEC" ;;
    esac
    SPX_DEC="$PATH_DEC"
fi

# если host пустой — используем sni
[ -z "$HOST_HDR" ] && HOST_HDR="$SNI"
[ -n "$SNI" ] || SNI="$SERVER"

# Валидация UUID/SERVER/PORT
if [ -z "$UUID" ] || [ -z "$SERVER" ] || [ -z "$PORT" ]; then
    logger -t shpun-build "Invalid VLESS link: uuid='$UUID' server='$SERVER' port='$PORT'"
    exit 1
fi

case "$PORT" in
    *[!0-9]*)
        logger -t shpun-build "Invalid port in VLESS link: '$PORT'"
        exit 1
        ;;
esac

# Подготовка flow (для Xray VLESS Reality)
FLOW_JSON=""
if [ -n "$FLOW" ]; then
    FLOW_JSON=", \"flow\": \"$FLOW\""
fi

# Порт для прозрачного dokodemo-door inbound.
# Должен совпадать с тем, что будет использоваться в firewall-xray.sh (REDIRECT).
REDIR_PORT="${REDIR_PORT:-12345}"

# Конфиг Xray:
#  - inbound-1: SOCKS на 127.0.0.1:10808 (debug)
#  - inbound-2: dokodemo-door 0.0.0.0:$REDIR_PORT с followRedirect (прозрачный VPN для TCP)
#  - outbound: VLESS Reality (наш SERVER:PORT / rush.lenivo.site:2083 и т.п.)
#  - второй outbound: direct
#  - routing: локальные сети + сам SERVER → direct, весь остальной TCP → proxy

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
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "$SERVER",
            "port": $PORT,
            "users": [
              {
                "id": "$UUID",
                "encryption": "none"$FLOW_JSON
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "$SNI",
          "publicKey": "$PBK",
          "shortId": "$SID",
          "fingerprint": "chrome",
          "show": false,
          "spiderX": "$SPX_DEC"
        }
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

logger -t shpun-build "xray config built (Reality, SOCKS+REDIR, server=$SERVER:$PORT, sni=$SNI, spx=$SPX_DEC, redir_port=$REDIR_PORT)"
exit 0
