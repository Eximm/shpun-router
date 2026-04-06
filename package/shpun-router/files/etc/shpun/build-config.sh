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

# ==========================
# 0. Универсальный base64-декодер (URL-safe, только awk)
# ==========================
# b64_url_decode "STRING" -> печатает декодированную строку в stdout.
# Не требует внешнего base64, использует только awk.
b64_url_decode() {
    local in="$1"
    local mod out

    # Заменяем URL-safe символы на обычные
    in="${in//-/+}"
    in="${in//_/\/}"

    # Добавляем паддинг до кратности 4
    mod=$(( ${#in} % 4 ))
    case "$mod" in
        0) ;;
        2) in="${in}==";;
        3) in="${in}=";;
        1)
            logger -t shpun-build "Invalid base64 length %4==1: len=${#in}, data='$1'"
            return 1
            ;;
    esac

    out="$(printf '%s' "$in" | awk '
        BEGIN {
            b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        }

        # Возвращает индекс символа в таблице b64 (0..63), или -1 для "="
        function b64val(c,  p) {
            if (c == "=") return -1
            p = index(b64, c)
            if (p == 0) return -2
            return p - 1
        }

        function decode_quad(q,    c1,c2,c3,c4,v1,v2,v3,v4,b1,b2,b3,out) {
            c1 = substr(q,1,1)
            c2 = substr(q,2,1)
            c3 = substr(q,3,1)
            c4 = substr(q,4,1)

            v1 = b64val(c1)
            v2 = b64val(c2)
            v3 = b64val(c3)
            v4 = b64val(c4)

            if (v1 < 0 || v2 < 0 || v3 < -1 || v4 < -1)
                return ""

            # Пересчитываем без битовых сдвигов, только через * / %
            b1 = v1 * 4 + int(v2 / 16)
            b2 = (v2 % 16) * 16 + int((v3 < 0 ? 0 : v3) / 4)
            b3 = (v3 < 0 ? 0 : (v3 % 4) * 64) + (v4 < 0 ? 0 : v4)

            out = sprintf("%c", b1)
            if (v3 >= 0)
                out = out sprintf("%c", b2)
            if (v4 >= 0)
                out = out sprintf("%c", b3)

            return out
        }

        {
            # чистим мусор
            gsub(/[^A-Za-z0-9+\/=]/, "", $0)
            line = $0
            out  = ""

            for (i = 1; i <= length(line); i += 4) {
                quad = substr(line, i, 4)
                if (length(quad) < 4)
                    break

                chunk = decode_quad(quad)
                if (chunk == "") {
                    # некорректные данные
                    out = ""
                    break
                }
                out = out chunk
            }

            printf "%s", out
        }
    ' 2>/dev/null)"

    if [ -z "$out" ]; then
        logger -t shpun-build "Failed to base64-decode (awk): '$1'"
        return 1
    fi

    printf '%s' "$out"
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
                CRED="$(b64_url_decode "$USERINFO")" || {
                    logger -t shpun-build "Failed to base64-decode ss userinfo"
                    exit 1
                }
            fi
        else
            # Вариант 2: старый стиль BASE64(method:password@host:port)
            DECODED_LINK="$(b64_url_decode "$BASE_PART")" || {
                logger -t shpun-build "Failed to base64-decode ss link payload (old style)"
                exit 1
            }

            USERINFO_HOSTPORT="$DECODED_LINK"
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
    # -------- VLESS / Reality --------

    LINK_NO_PROTO="${LINK#vless://}"

    # user@host:port?params
    USER_HOST="${LINK_NO_PROTO%%\?*}"
    PARAMS="${LINK_NO_PROTO#*\?}"

    UUID="${USER_HOST%%@*}"
    HOSTPORT="${USER_HOST#*@}"

    SERVER="${HOSTPORT%%:*}"
    PORT="${HOSTPORT##*:}"

    # --- parse query params ---
    get_param() {
        echo "$PARAMS" | tr '&' '\n' | grep "^$1=" | head -n1 | cut -d= -f2-
    }

    SECURITY="$(get_param security)"
    TYPE="$(get_param type)"
    HOST="$(get_param host)"
    PATH="$(get_param path)"
    PBK="$(get_param pbk)"
    SID="$(get_param sid)"
    FP="$(get_param fp)"

    # defaults
    [ -z "$TYPE" ] && TYPE="tcp"
    [ -z "$FP" ] && FP="chrome"

    # validation
    if [ -z "$UUID" ] || [ -z "$SERVER" ] || [ -z "$PORT" ]; then
        logger -t shpun-build "Invalid VLESS link (uuid/server/port missing)"
        exit 1
    fi

    case "$PORT" in
        *[!0-9]*)
            logger -t shpun-build "Invalid port in VLESS link: '$PORT'"
            exit 1
            ;;
    esac

    # --- streamSettings ---
    STREAM_SETTINGS=""

    if [ "$SECURITY" = "reality" ]; then
        STREAM_SETTINGS=$(cat <<EOF
      "streamSettings": {
        "network": "$TYPE",
        "security": "reality",
        "realitySettings": {
          "serverName": "$HOST",
          "publicKey": "$PBK",
          "shortId": "$SID",
          "fingerprint": "$FP"
        }
      }
EOF
)
    else
        # fallback (например если вдруг появится не reality)
        STREAM_SETTINGS=$(cat <<EOF
      "streamSettings": {
        "network": "$TYPE"
      }
EOF
)
    fi

    # --- build config ---
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
                "encryption": "none"
              }
            ]
          }
        ]
      },
$STREAM_SETTINGS
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

    logger -t shpun-build "xray config built (VLESS, server=$SERVER:$PORT, reality=$SECURITY, redir_port=$REDIR_PORT)"
    exit 0
    ;;

    *)
        # -------- Неизвестный протокол --------
        logger -t shpun-build "Unknown router profile proto='$ROUTER_PROTO', cannot build config"
        exit 1
        ;;
esac
