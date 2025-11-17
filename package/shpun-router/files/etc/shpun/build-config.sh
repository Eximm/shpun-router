#!/bin/sh
# shellcheck disable=SC1090

SUB_FILE="/etc/shpun/subscription.json"
OUT_CFG="/etc/shpun/sing-box.json"
CONF="/etc/shpun/agent.conf"

# Подхватываем опции, если есть
[ -f "$CONF" ] && . "$CONF"

# Флаг: включать ли DNS inbound (127.0.0.1:5353) в конфиге sing-box
# По умолчанию ВЫКЛЮЧЕНО (0), чтобы не словить FATAL/зависон.
DNS_INBOUND_ENABLED="${DNS_INBOUND_ENABLED:-0}"

[ -f "$SUB_FILE" ] || {
    logger -t shpun-build "No subscription file"
    exit 1
}

# первый линк из массива links[]
LINK="$(jsonfilter -i "$SUB_FILE" -e '@.subscription.links[0]' 2>/dev/null)"

[ -n "$LINK" ] || {
    logger -t shpun-build "No links[0] in subscription"
    exit 1
}

# убираем кавычки, если jsonfilter вернул с ними
LINK="${LINK%\"}"
LINK="${LINK#\"}"

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

PATH_ENC="$(get_param path)"
HOST_HDR="$(get_param host)"
SNI="$(get_param sni)"
TYPE="$(get_param type)"

[ -n "$TYPE" ] || TYPE="ws"

# Декодируем хотя бы %2F -> / и гарантируем, что путь начинается с "/"
if [ -n "$PATH_ENC" ]; then
    PATH_DEC="$(printf '%s' "$PATH_ENC" | sed -e 's/%2[Ff]/\//g')"
else
    PATH_DEC="/vless"
fi

case "$PATH_DEC" in
    /*) ;;
    *) PATH_DEC="/$PATH_DEC" ;;
esac

[ -n "$HOST_HDR" ] || HOST_HDR="$SERVER"
[ -n "$SNI" ]      || SNI="$HOST_HDR"

# Базовая валидация
if [ -z "$UUID" ] || [ -z "$SERVER" ] || [ -z "$PORT" ]; then
    logger -t shpun-build "Invalid VLESS link: uuid='$UUID' server='$SERVER' port='$PORT'"
    exit 1
fi

# PORT должен быть числом
case "$PORT" in
    *[!0-9]*)
        logger -t shpun-build "Invalid port in VLESS link: '$PORT'"
        exit 1
        ;;
esac

cat >"$OUT_CFG" <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },

  "dns": {
    "servers": [
      {
        "tag": "dns-1",
        "type": "udp",
        "server": "1.1.1.1"
      },
      {
        "tag": "dns-2",
        "type": "udp",
        "server": "8.8.8.8"
      },
      {
        "tag": "dns-3",
        "type": "udp",
        "server": "9.9.9.9"
      }
    ],
    "strategy": "ipv4_only"
  },

  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "address": [
        "172.19.0.1/30"
      ],
      "auto_route": true,
      "strict_route": true
    }$( [ "$DNS_INBOUND_ENABLED" = "1" ] && printf ',\n    {\n      "type": "dns",\n      "tag": "dns-in",\n      "address": "127.0.0.1",\n      "port": 5353\n    }' )
  ],

  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "vless",
      "tag": "proxy",
      "server": "$SERVER",
      "server_port": $PORT,
      "uuid": "$UUID",
      "flow": "",
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        }
      },
      "transport": {
        "type": "$TYPE",
        "path": "$PATH_DEC",
        "headers": {
          "Host": "$HOST_HDR"
        }
      }
    }
  ],

  "route": {
    "auto_detect_interface": true,
    "rules": [
      {
        "ip_cidr": [
          "127.0.0.0/8",
          "10.0.0.0/8",
          "172.16.0.0/12",
          "192.168.0.0/16"
        ],
        "outbound": "direct"
      }$( [ "$DNS_INBOUND_ENABLED" = "1" ] && printf ',\n      {\n        "inbound": "dns-in",\n        "outbound": "direct"\n      }' ),
      {
        "outbound": "proxy"
      }
    ]
  }
}
EOF

logger -t shpun-build "Config built for $SERVER:$PORT (uuid=$UUID, path=$PATH_DEC, type=$TYPE, dns_inbound=$DNS_INBOUND_ENABLED)"
exit 0
