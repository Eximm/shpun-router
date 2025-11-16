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
  ]
}
EOF

logger -t shpun-build "Config built for $SERVER:$PORT (uuid=$UUID)"
exit 0
