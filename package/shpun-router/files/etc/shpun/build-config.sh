#!/bin/sh
# shellcheck disable=SC1090

SUB_FILE="/etc/shpun/subscription.json"
OUT_CFG="/etc/shpun/xray.json"
CONF="/etc/shpun/agent.conf"

# Подхватываем опции (в т.ч. REDIR_PORT)
[ -f "$CONF" ] && . "$CONF"

[ -f "$SUB_FILE" ] || {
    logger -t shpun-build "No subscription file: $SUB_FILE"
    exit 1
}

command -v jsonfilter >/dev/null 2>&1 || {
    logger -t shpun-build "jsonfilter not found"
    exit 1
}

command -v base64 >/dev/null 2>&1 || {
    logger -t shpun-build "base64 not found"
    exit 1
}

# ==========================
# 1. Определяем тип профиля (ROUTER_PROTO)
# ==========================

# 1.1. Явный тип из JSON, если есть:
# "router_profile": { "proto": "ss" | "vless" | ... }
ROUTER_PROTO="$(jsonfilter -i "$SUB_FILE" -e '@.router_profile.proto' 2>/dev/null)"

# 1.2. Первый линк из массива links[0]
LINK="$(jsonfilter -i "$SUB_FILE" -e '@.subscription.links[0]' 2>/dev/null)"

[ -n "$LINK" ] || {
    logger -t shpun-build "No links[0] in subscription"
    exit 1
}

# убираем кавычки, если jsonfilter вернул с ними
LINK="${LINK%\"}"
LINK="${LINK#\"}"

# 1.3. Если ROUTER_PROTO пустой — определяем по схеме
if [ -z "$ROUTER_PROTO" ]; then
    case "$LINK" in
        ss://*)
            ROUTER_PROTO="ss"
            ;;
        vless://*)
            ROUTER_PROTO="vless"
            ;;
        *)
            ROUTER_PROTO="unknown"
            ;;
    esac
fi

logger -t shpun-build "router profile proto=$ROUTER_PROTO, link_scheme=$(printf '%s' "$LINK" | cut -d: -f1)"

# Порт для прозрачного dokodemo-door inbound
REDIR_PORT="${REDIR_PORT:-12345}"

# ==========================
# 2. Вспомогательная функция для правки URL-safe base64
# ==========================
fix_b64() {
    local s="$1"
    s="${s//-/+}"
    s="${s//_/\/}"
    case $((${#s} % 4)) in
        2) s="${s}==";;
        3) s="${s}=";;
    esac
    printf '%s' "$s"
}

# ==========================
# 3. Ветвление по типу профиля
# ==========================

case "$ROUTER_PROTO" in
    ss)
        # -------- Shadowsocks-профиль (ТЕКУЩИЙ РАБОЧИЙ ВАРИАНТ) --------
        #
        # Поддерживаем оба формата:
        # 1) ss://BASE64(method:password)@host:port#NAME
        # 2) ss://BASE64(method:password@host:port)#NAME
        #

        LINK_NO_PROTO="${LINK#ss://}"

        METHOD=""
        PASSWORD=""
        SERVER=""
        PORT=""

        # Часть до ?/# — userinfo@host:port или BASE64(...)
        BASE_PART="${LINK_NO_PROTO%%[\?#]*}"

        if echo "$BASE_PART" | grep -q '@'; then
            # Вариант 1: userinfo@host:port
            USERINFO="${BASE_PART%%@*}"
            HOSTPORT="${BASE_PART#*@}"

            # USERINFO: либо method:password, либо base64(method:password)
            if echo "$USERINFO" | grep -q ':'; then
                CRED="$USERINFO"
            else
                B64_FIXED="$(fix_b64 "$USERINFO")"
                DECODED="$(printf '%s' "$B64_FIXED" | base64 -d 2>/dev/null)"

                [ -n "$DECODED" ] || {
                    logger -t shpun-build "Failed to base64-decode ss userinfo"
                    exit 1
                }

                CRED="$DECODED"
            fi
        else
            # Вариант 2: старый стиль BASE64(method:password@host:port)
            B64_FIXED="$(fix_b64 "$BASE_PART")"
            DECODED="$(printf '%s' "$B64_FIXED" | base64 -d 2>/dev/null)"

            [ -n "$DECODED" ] || {
                logger -t shpun-build "Failed to base64-decode ss link payload (old style)"
                exit 1
            }

            USERINFO_HOSTPORT="$DECODED"
            CRED="${USERINFO_HOSTPORT%%@*}"
            HOSTPORT="${USERINFO_HOSTPORT#*@}"
        fi

        METHOD="${CRED%%:*}"
        PASSWORD="${CRED#*:}"
        SERVER="${HOSTPORT%%:*}"
        PORT="${HOSTPORT##*:}"

        # Валидация
        if [ -z "$METHOD" ] || [ -z "$PASSWORD" ] || [ -z "$SERVER" ] || [ -z "$PORT" ]; then
            logger -t shpun-build "Invalid SS link: method='$METHOD' password_len=${#PASSWORD} server='$SERVER' port='$PORT'"
            exit 1
        fi

        case "$PORT" in
            *[!0-9]*)
                logger -t shpun-build "Invalid port in SS link: '$PORT'"
                exit 1
                ;;
        esac

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
        "enabled": false
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
            "password": "$PASSWORD",
            "udp": false
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
        ;;

    vless)
        # -------- VLESS / Reality (РЕЗЕРВ НА БУДУЩЕЕ) --------
        #
        # Текущая прошивка не собирает VLESS-конфиг на роутере.
        # Но наличие ROUTER_PROTO=vless зафиксировано, так что
        # при выпуске новой версии пакета достаточно дописать
        # сюда генерацию конфига, без перепрошивки устройства.
        #
        logger -t shpun-build "VLESS router profile is not supported in this firmware version (proto=vless)"
        exit 1
        ;;

    *)
        # -------- Неизвестный протокол --------
        logger -t shpun-build "Unknown router profile proto='$ROUTER_PROTO', cannot build config"
        exit 1
        ;;
esac
