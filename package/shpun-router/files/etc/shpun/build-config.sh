#!/bin/sh

SUB_FILE="/etc/shpun/subscription.json"
OUT_CFG="/etc/shpun/sing-box.json"

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

# убираем кавычки, если есть
LINK="${LINK%\"}"
LINK="${LINK#\"}"

# убираем префикс vless://
LINK_NO_PROTO="${LINK#vless://}"

# uuid до @
UUID="${LINK_NO_PROTO%%@*}"

REST="${LINK_NO_PROTO#*@}"

# host:port до ?
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

# тип транспорта (ws/tcp) – по умолчанию ws
TYPE="$(get_param type)"
[ -n "$TYPE" ] || TYPE="ws"

# Декодируем хотя бы %2F -> / (остальное нам сейчас не критично)
if [ -n "$PATH_ENC" ]; then
    PATH_DEC="$(printf '%s' "$PATH_ENC" | sed -e 's/%2[Ff]/\//g')"
else
    PATH_DEC="/vless"
fi

[ -n "$HOST_HDR" ] || HOST_HDR="$SERVER"
[ -n "$SNI" ]      || SNI="$HOST_HDR"

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
        "address": "1.1.1.1",
        "detour": "direct"
      },
      {
        "tag": "dns-2",
        "address": "8.8.8.8",
        "detour": "direct"
      },
      {
        "tag": "dns-3",
        "address": "9.9.9.9",
        "detour": "direct"
      }
    ],
    "strategy": "ipv4_only"
  },

  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "inet4_address": "172.19.0.1/30",
      "auto_route": true,
      "strict_route": true
    }
  ],

  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
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
        "protocol": "dns",
        "outbound": "direct"
      },
      {
        "ip_cidr": [
          "127.0.0.0/8",
          "10.0.0.0/8",
          "172.16.0.0/12",
          "192.168.0.0/16"
        ],
        "outbound": "direct"
      },
      {
        "outbound": "proxy"
      }
    ]
  }
}
EOF

logger -t shpun-build "Config built for $SERVER:$PORT (uuid=$UUID)"
exit 0
