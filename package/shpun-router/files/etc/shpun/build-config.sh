#!/bin/sh
# shellcheck disable=SC1090

SUB_FILE="/etc/shpun/subscription.json"
OUT_CFG="/etc/shpun/xray.json"
CONF="/etc/shpun/agent.conf"
SELECTED_LINK_FILE="/etc/shpun/selected_link_index"
ROUTES_MODE_FILE="/etc/shpun/routes/mode"
SMART_RU_DOMAINS_FILE="/etc/shpun/routes/presets/smart_ru.domains"
CUSTOM_ROUTES_FILE="/etc/shpun/routes/custom.json"

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
b64_url_decode() {
    local in="$1"
    local mod out

    in="${in//-/+}"
    in="${in//_/\/}"

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
            gsub(/[^A-Za-z0-9+\/=]/, "", $0)
            line = $0
            out  = ""

            for (i = 1; i <= length(line); i += 4) {
                quad = substr(line, i, 4)
                if (length(quad) < 4)
                    break

                chunk = decode_quad(quad)
                if (chunk == "") {
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

SELECTED_LINK_INDEX="$(cat "$SELECTED_LINK_FILE" 2>/dev/null | tr -d '\r\n ' || echo 0)"
case "$SELECTED_LINK_INDEX" in
    ''|*[!0-9]*) SELECTED_LINK_INDEX=0 ;;
esac

LINK="$(jsonfilter -i "$SUB_FILE" -e "@.subscription.links[$SELECTED_LINK_INDEX]" 2>/dev/null)"

if [ -z "$LINK" ] && [ "$SELECTED_LINK_INDEX" != "0" ]; then
    logger -t shpun-build "selected link index $SELECTED_LINK_INDEX not found, fallback to 0"
    SELECTED_LINK_INDEX=0
    echo "0" > "$SELECTED_LINK_FILE" 2>/dev/null || true
    LINK="$(jsonfilter -i "$SUB_FILE" -e '@.subscription.links[0]' 2>/dev/null)"
fi

[ -n "$LINK" ] || {
    logger -t shpun-build "No links[0] in subscription"
    exit 1
}

LINK="${LINK%\"}"
LINK="${LINK#\"}"

JSON_PROTO="$(jsonfilter -i "$SUB_FILE" -e '@.router_profile.proto' 2>/dev/null)"

case "$LINK" in
    ss://*)    ROUTER_PROTO="ss" ;;
    vless://*) ROUTER_PROTO="vless" ;;
    *)         ROUTER_PROTO="unknown" ;;
esac

if [ -n "$JSON_PROTO" ] && [ "$JSON_PROTO" != "$ROUTER_PROTO" ]; then
    logger -t shpun-build "router_profile.proto mismatch: json='$JSON_PROTO', link_scheme='$ROUTER_PROTO' — using link_scheme"
fi

logger -t shpun-build "router profile proto=$ROUTER_PROTO selected_link=$SELECTED_LINK_INDEX"

REDIR_PORT="${REDIR_PORT:-12345}"
TPROXY_PORT="${TPROXY_PORT:-12346}"
TPROXY_MARK="${TPROXY_MARK:-233}"

# smart_ru domain preset support
json_escape() {
    printf '%s' "$1" | awk '
        {
            gsub(/\\/,"\\\\")
            gsub(/"/,"\\\"")
            printf "%s", $0
        }
    '
}

get_routing_mode() {
    mode="$(cat "$ROUTES_MODE_FILE" 2>/dev/null | tr -d '\r\n ' || true)"
    [ -z "$mode" ] && mode="full"
    echo "$mode"
}

is_ipv4_cidr() {
    entry="$(printf '%s' "$1" | tr -d ' \t\r\n')"
    [ -n "$entry" ] || return 1

    case "$entry" in
        */*) ip="${entry%%/*}"; prefix="${entry##*/}" ;;
        *)   ip="$entry";       prefix="32" ;;
    esac

    case "$prefix" in ''|*[!0-9]*) return 1 ;; esac
    [ "$prefix" -gt 32 ] 2>/dev/null && return 1

    oldifs="$IFS"
    IFS='.'
    set -- $ip
    IFS="$oldifs"

    [ "$#" -eq 4 ] || return 1
    for octet in "$@"; do
        case "$octet" in ''|*[!0-9]*) return 1 ;; esac
        [ "$octet" -gt 255 ] 2>/dev/null && return 1
    done

    return 0
}

is_domain_entry() {
    domain="$(printf '%s' "$1" | tr -d ' \t\r\n')"
    [ -n "$domain" ] || return 1

    case "$domain" in
        *://*|*/*|*:*|*..*|.*|*.) return 1 ;;
        \*.*) domain="${domain#*.}" ;;
        *\**) return 1 ;;
    esac

    case "$domain" in
        *.*) ;;
        *) return 1 ;;
    esac

    oldifs="$IFS"
    IFS='.'
    set -- $domain
    IFS="$oldifs"

    for label in "$@"; do
        [ -n "$label" ] || return 1
        [ "${#label}" -le 63 ] 2>/dev/null || return 1
        case "$label" in
            -*|*-) return 1 ;;
            *[!A-Za-z0-9-]*) return 1 ;;
        esac
    done

    return 0
}

domain_to_xray() {
    domain="$(printf '%s' "$1" | tr -d ' \t\r\n')"
    case "$domain" in
        \*.*) domain="${domain#*.}" ;;
    esac
    printf 'domain:%s' "$domain"
}

build_smart_ru_domain_rule() {
    [ "$(get_routing_mode)" = "smart_ru" ] || return 0
    [ -s "$SMART_RU_DOMAINS_FILE" ] || return 0

    first=1
    domains=""
    count=0

    while IFS= read -r raw_domain; do
        domain="$(printf '%s' "$raw_domain" | tr -d ' \t\r')"
        [ -z "$domain" ] && continue
        case "$domain" in
            \#*) continue ;;
        esac
        case "$domain" in
            *[!A-Za-z0-9._*-]*)
                continue
                ;;
        esac

        case "$domain" in
            \*.*) domain="domain:${domain#*.}" ;;
            *)    domain="domain:$domain" ;;
        esac

        escaped="$(json_escape "$domain")"
        if [ "$first" -eq 1 ]; then
            domains="\"$escaped\""
            first=0
        else
            domains="$domains,
          \"$escaped\""
        fi
        count=$((count + 1))
    done < "$SMART_RU_DOMAINS_FILE"

    [ "$count" -gt 0 ] || return 0

    cat <<EOF
      {
        "type": "field",
        "outboundTag": "direct",
        "domain": [
          $domains
        ]
      },
EOF

    logger -t shpun-build "smart_ru direct domains enabled: $count"
}

SMART_RU_RULE="$(build_smart_ru_domain_rule)"

build_custom_domain_rule() {
    key="$1"
    outbound="$2"
    [ -s "$CUSTOM_ROUTES_FILE" ] || return 0
    command -v jsonfilter >/dev/null 2>&1 || return 0

    tmp="/tmp/shpun_custom_domains_${key}_$$.tmp"
    jsonfilter -i "$CUSTOM_ROUTES_FILE" -e "@.${key}[*]" 2>/dev/null | tr -d '"' > "$tmp" 2>/dev/null

    first=1
    domains=""
    count=0

    while IFS= read -r entry; do
        entry="$(printf '%s' "$entry" | tr -d ' \t\r\n')"
        [ -z "$entry" ] && continue
        is_ipv4_cidr "$entry" && continue
        is_domain_entry "$entry" || continue

        xray_domain="$(domain_to_xray "$entry")"
        escaped="$(json_escape "$xray_domain")"
        if [ "$first" -eq 1 ]; then
            domains="\"$escaped\""
            first=0
        else
            domains="$domains,
          \"$escaped\""
        fi
        count=$((count + 1))
    done < "$tmp"

    rm -f "$tmp"
    [ "$count" -gt 0 ] || return 0

    cat <<EOF
      {
        "type": "field",
        "outboundTag": "$outbound",
        "domain": [
          $domains
        ]
      },
EOF

    logger -t shpun-build "custom $key domains enabled: $count outbound=$outbound"
}

CUSTOM_DIRECT_RULE="$(build_custom_domain_rule direct direct)"
CUSTOM_VPN_RULE="$(build_custom_domain_rule vpn proxy)"

# ==========================
# 2. Ветвление по типу профиля
# ==========================

case "$ROUTER_PROTO" in
    ss)
        # -------- Shadowsocks-профиль --------
        LINK_NO_PROTO="${LINK#ss://}"
        METHOD=""
        PASSWORD=""
        SERVER=""
        PORT=""
        BASE_PART="${LINK_NO_PROTO%%[\?#]*}"

        if echo "$BASE_PART" | grep -q '@'; then
            USERINFO="${BASE_PART%%@*}"
            HOSTPORT="${BASE_PART#*@}"

            if echo "$USERINFO" | grep -q ':'; then
                CRED="$USERINFO"
            else
                CRED="$(b64_url_decode "$USERINFO")" || {
                    logger -t shpun-build "Failed to base64-decode ss userinfo"
                    exit 1
                }
            fi
        else
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

        if [ -z "$METHOD" ] || [ -z "$PASSWORD" ] || [ -z "$SERVER" ] || [ -z "$PORT" ]; then
            logger -t shpun-build "Invalid SS link: method='$METHOD' server='$SERVER' port='$PORT'"
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
    "access": "none",
    "error": "none",
    "loglevel": "none"
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
    },
    {
      "tag": "tproxy-in",
      "listen": "0.0.0.0",
      "port": $TPROXY_PORT,
      "protocol": "dokodemo-door",
      "settings": {
        "network": "udp",
        "followRedirect": true
      },
      "streamSettings": {
        "sockopt": {
          "tproxy": "tproxy"
        }
      },
      "sniffing": {
        "enabled": false
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
            "udp": true
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
$CUSTOM_DIRECT_RULE
$SMART_RU_RULE
$CUSTOM_VPN_RULE
      {
        "type": "field",
        "network": "tcp",
        "outboundTag": "proxy"
      },
      {
        "type": "field",
        "network": "udp",
        "outboundTag": "proxy"
      }
    ]
  }
}
EOF

        logger -t shpun-build "xray config built (Shadowsocks, TCP+UDP, server=$SERVER:$PORT, method=$METHOD, redir=$REDIR_PORT, tproxy=$TPROXY_PORT)"
        exit 0
        ;;

    vless)
        # -------- VLESS / Reality --------
        LINK_NO_PROTO="${LINK#vless://}"
        LINK_NO_FRAGMENT="${LINK_NO_PROTO%%#*}"
        USER_HOST="${LINK_NO_FRAGMENT%%\?*}"
        PARAMS=""
        [ "$LINK_NO_FRAGMENT" != "$USER_HOST" ] && PARAMS="${LINK_NO_FRAGMENT#*\?}"

        UUID="${USER_HOST%%@*}"
        HOSTPORT="${USER_HOST#*@}"
        SERVER="${HOSTPORT%%:*}"
        PORT="${HOSTPORT##*:}"

        url_decode() {
            local data="${1//+/ }"
            printf '%b' "${data//%/\\x}"
        }

        get_param() {
            printf '%s' "$PARAMS" | tr '&' '\n' | awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/,""); print; exit}'
        }

        SECURITY="$(url_decode "$(get_param security)")"
        TYPE="$(url_decode "$(get_param type)")"
        HOST="$(url_decode "$(get_param host)")"
        PATH_VAL="$(url_decode "$(get_param path)")"
        PBK="$(url_decode "$(get_param pbk)")"
        SID="$(url_decode "$(get_param sid)")"
        FP="$(url_decode "$(get_param fp)")"
        FLOW="$(url_decode "$(get_param flow)")"
        SNI="$(url_decode "$(get_param sni)")"
        ALPN="$(url_decode "$(get_param alpn)")"
        ENCRYPTION="$(url_decode "$(get_param encryption)")"
        HEADER_TYPE="$(url_decode "$(get_param headerType)")"

        [ -z "$TYPE" ]       && TYPE="tcp"
        [ -z "$FP" ]         && FP="chrome"
        [ -z "$ENCRYPTION" ] && ENCRYPTION="none"
        [ -z "$SNI" ]        && SNI="$HOST"

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

        if [ -n "$FLOW" ]; then
            USER_FLOW_LINE=",\n                \"flow\": \"$FLOW\""
        else
            USER_FLOW_LINE=""
        fi

        TCP_HEADER_BLOCK=""
        if [ "$TYPE" = "tcp" ] && [ -n "$HEADER_TYPE" ] && [ "$HEADER_TYPE" != "none" ]; then
            TCP_HEADER_BLOCK=$(cat <<EOF
        "tcpSettings": {
          "header": {
            "type": "$HEADER_TYPE"
          }
        },
EOF
)
        fi

        if [ "$SECURITY" = "reality" ]; then
            [ -z "$PBK" ] && {
                logger -t shpun-build "VLESS reality link missing pbk"
                exit 1
            }
            STREAM_SETTINGS=$(cat <<EOF
      "streamSettings": {
        "network": "$TYPE",
        "security": "reality",
$TCP_HEADER_BLOCK        "realitySettings": {
          "show": false,
          "fingerprint": "$FP",
          "serverName": "$SNI",
          "publicKey": "$PBK",
          "shortId": "$SID",
          "spiderX": "/"
        }
      }
EOF
)
        elif [ "$SECURITY" = "tls" ]; then
            STREAM_SETTINGS=$(cat <<EOF
      "streamSettings": {
        "network": "$TYPE",
        "security": "tls",
$TCP_HEADER_BLOCK        "tlsSettings": {
          "serverName": "$SNI",
          "fingerprint": "$FP",
          "allowInsecure": false
        }
      }
EOF
)
        else
            STREAM_SETTINGS=$(cat <<EOF
      "streamSettings": {
        "network": "$TYPE",
        "security": "none"
      }
EOF
)
        fi

        if [ "$TYPE" != "tcp" ]; then
            logger -t shpun-build "Unsupported VLESS network type for current router config: '$TYPE'"
            exit 1
        fi

        cat >"$OUT_CFG" <<EOF
{
  "log": {
    "access": "none",
    "error": "none",
    "loglevel": "none"
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
    },
    {
      "tag": "tproxy-in",
      "listen": "0.0.0.0",
      "port": $TPROXY_PORT,
      "protocol": "dokodemo-door",
      "settings": {
        "network": "udp",
        "followRedirect": true
      },
      "streamSettings": {
        "sockopt": {
          "tproxy": "tproxy"
        }
      },
      "sniffing": {
        "enabled": false
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
                "encryption": "$ENCRYPTION"$USER_FLOW_LINE
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
$CUSTOM_DIRECT_RULE
$SMART_RU_RULE
$CUSTOM_VPN_RULE
      {
        "type": "field",
        "network": "tcp",
        "outboundTag": "proxy"
      },
      {
        "type": "field",
        "network": "udp",
        "outboundTag": "proxy"
      }
    ]
  }
}
EOF

        logger -t shpun-build "xray config built (VLESS, TCP+UDP, server=$SERVER:$PORT, security=${SECURITY:-none}, redir=$REDIR_PORT, tproxy=$TPROXY_PORT)"
        exit 0
        ;;

    *)
        logger -t shpun-build "Unknown router profile proto='$ROUTER_PROTO', cannot build config"
        exit 1
        ;;
esac
