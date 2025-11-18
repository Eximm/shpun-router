#!/bin/sh
# shellcheck disable=SC1090

SUB_FILE="/etc/shpun/subscription.json"
OUT_CFG="/etc/shpun/sing-box.json"
CONF="/etc/shpun/agent.conf"

# Подхватываем опции, если есть
[ -f "$CONF" ] && . "$CONF"

# Можно переопределить в /etc/shpun/agent.conf:
#   DNS_ADDR1="77.88.8.8"
#   DNS_ADDR2="1.1.1.1"
#   TUN_MTU="1450"
DNS_ADDR1="${DNS_ADDR1:-9.9.9.9}"
DNS_ADDR2="${DNS_ADDR2:-8.8.8.8}"
TUN_MTU="${TUN_MTU:-1450}"

[ -f "$SUB_FILE" ] || {
    logger -t shpun-build "No subscription file: $SUB_FILE"
    exit 1
}

# первый линк из массива links[0] (для RouterVPN он всегда Reality)
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
    # простой парсер параметров вида key=value в QUERY
    echo "$QUERY" | tr '&' '\n' | awk -F= -v k="$1" '$1==k {print $2}'
}

SECURITY="$(get_param security)"
PBK_ENC="$(get_param pbk)"
SID_ENC="$(get_param sid)"
SPX_ENC="$(get_param spx)"
SNI="$(get_param sni)"

# Базовая валидация Reality
if [ "$SECURITY" != "reality" ] && [ -z "$PBK_ENC" ] && [ -z "$SID_ENC" ]; then
    logger -t shpun-build "Non-Reality link, router expects Reality only (security='$SECURITY')"
    exit 1
fi

# pbk / sid / spx
PBK="$PBK_ENC"
SID="$SID_ENC"
[ -z "$PBK" ] && PBK="dummy_pbk"
[ -z "$SID" ] && SID=""

# spx → только для логов (в конфиг не пишем, т.к. spider_x не поддерживается этой версией)
if [ -n "$SPX_ENC" ]; then
    SPX_DEC="$(printf '%s' "$SPX_ENC" | sed -e 's/%2[Ff]/\//g')"
else
    SPX_DEC="/"
fi
case "$SPX_DEC" in
    /*) ;;
    *) SPX_DEC="/$SPX_DEC" ;;
esac

# SNI по умолчанию = SERVER
[ -n "$SNI" ] || SNI="$SERVER"

# Базовая валидация UUID/SERVER/PORT
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

# Генерируем ОДИН лёгкий конфиг sing-box под VLESS Reality (без transport, со встроенным uTLS)
cat >"$OUT_CFG" <<EOF
{
  "log": {
    "disabled": false,
    "level": "error",
    "timestamp": true
  },

  "dns": {
    "servers": [
      {
        "tag": "dns-1",
        "address": "$DNS_ADDR1",
        "detour": "direct"
      },
      {
        "tag": "dns-2",
        "address": "$DNS_ADDR2",
        "detour": "direct"
      }
    ],
    "strategy": "ipv4_only"
  },

  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "tun0",
      "inet4_address": "172.19.0.1/30",
      "mtu": $TUN_MTU,
      "auto_route": true,
      "strict_route": true
    }
  ],

  "outbounds": [
    {
      "type": "vless",
      "tag": "vpn-out",
      "server": "$SERVER",
      "server_port": $PORT,
      "uuid": "$UUID",
      "flow": "",
      "packet_encoding": "",
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "$PBK",
          "short_id": "$SID"
        }
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],

  "route": {
    "default_domain_resolver": "dns-1",
    "geoip": {
      "download_url": "",
      "download_detour": "direct"
    },
    "geosite": {
      "download_url": "",
      "download_detour": "direct"
    },
    "rules": [
      {
        "ip_cidr": [
          "127.0.0.0/8",
          "10.0.0.0/8",
          "172.16.0.0/12",
          "192.168.0.0/16"
        ],
        "outbound": "direct"
      }
    ],
    "final": "vpn-out"
  }
}
EOF

logger -t shpun-build "Config built (Reality) for $SERVER:$PORT (uuid=$UUID, sni=$SNI, path=$SPX_DEC, dns1=$DNS_ADDR1, dns2=$DNS_ADDR2, mtu=$TUN_MTU)"
exit 0
