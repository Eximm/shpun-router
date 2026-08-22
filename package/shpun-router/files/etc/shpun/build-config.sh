#!/bin/sh
# shellcheck disable=SC1090

SUB_FILE="${SUB_FILE:-/etc/shpun/subscription.json}"
OUT_CFG="${OUT_CFG:-/etc/shpun/xray.json}"
CONF="${CONF:-/etc/shpun/agent.conf}"
SELECTED_LINK_FILE="${SELECTED_LINK_FILE:-/etc/shpun/selected_link_index}"
ROUTES_MODE_FILE="${ROUTES_MODE_FILE:-/etc/shpun/routes/mode}"
SMART_RU_DOMAINS_FILE="${SMART_RU_DOMAINS_FILE:-/etc/shpun/routes/presets/smart_ru.domains}"
ALWAYS_VPN_DOMAINS_FILE="${ALWAYS_VPN_DOMAINS_FILE:-/etc/shpun/routes/presets/always_vpn.domains}"
CUSTOM_ROUTES_FILE="${CUSTOM_ROUTES_FILE:-/etc/shpun/routes/custom.json}"

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
# 1. Select the VLESS subscription link
# ==========================

SELECTED_LINK_INDEX="$(cat "$SELECTED_LINK_FILE" 2>/dev/null | tr -d '\r\n ' || echo 0)"
case "$SELECTED_LINK_INDEX" in
    ''|*[!0-9]*) SELECTED_LINK_INDEX=0 ;;
esac

get_subscription_link() {
    idx="$1"

    for base in "@.subscription.links[$idx]" "@.links[$idx]"; do
        for suffix in "" ".url" ".link" ".uri" ".vless"; do
            val="$(jsonfilter -i "$SUB_FILE" -e "${base}${suffix}" 2>/dev/null | head -n 1 | tr -d '\r\n')"
            case "$val" in
                vless://*)
                    printf '%s\n' "$val"
                    return 0
                    ;;
            esac
        done
    done

    return 1
}

LINK="$(get_subscription_link "$SELECTED_LINK_INDEX" || true)"

if [ -z "$LINK" ] && [ "$SELECTED_LINK_INDEX" != "0" ]; then
    logger -t shpun-build "selected link index $SELECTED_LINK_INDEX not found, fallback to 0"
    SELECTED_LINK_INDEX=0
    echo "0" > "$SELECTED_LINK_FILE" 2>/dev/null || true
    LINK="$(get_subscription_link 0 || true)"
fi

[ -n "$LINK" ] || {
    logger -t shpun-build "No usable links[0] in subscription"
    exit 1
}

LINK="${LINK%\"}"
LINK="${LINK#\"}"

case "$LINK" in
    vless://*) ;;
    *)
        logger -t shpun-build "Unsupported subscription link scheme; VLESS is required"
        exit 1
        ;;
esac

logger -t shpun-build "router profile proto=vless selected_link=$SELECTED_LINK_INDEX"

REDIR_PORT="${REDIR_PORT:-12345}"
TPROXY_PORT="${TPROXY_PORT:-12346}"
TPROXY_MARK="${TPROXY_MARK:-233}"
HTTP_PROXY_PORT="${HTTP_PROXY_PORT:-10809}"
DNS_PROXY_PORT="${DNS_PROXY_PORT:-1053}"

mask_host() {
    host="$(printf '%s' "$1" | tr -d ' \t\r\n')"
    [ -n "$host" ] || {
        printf 'hidden'
        return
    }

    case "$host" in
        *.*) printf '%s' "${host%%.*}.***" ;;
        *)   printf 'hidden' ;;
    esac
}

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

build_file_domain_rule() {
    file="$1"
    outbound="$2"
    label="$3"
    [ -s "$file" ] || return 0

    first=1
    domains=""
    count=0

    while IFS= read -r entry; do
        entry="$(printf '%s' "$entry" | tr -d ' \t\r\n')"
        [ -z "$entry" ] && continue
        case "$entry" in \#*) continue ;; esac
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
    done < "$file"

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

    logger -t shpun-build "$label domains enabled: $count outbound=$outbound"
}

ALWAYS_VPN_RULE="$(build_file_domain_rule "$ALWAYS_VPN_DOMAINS_FILE" proxy always_vpn)"

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
# 2. VLESS / Reality
# ==========================

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

        get_first_param() {
            for key in "$@"; do
                val="$(get_param "$key")"
                [ -n "$val" ] && {
                    printf '%s' "$val"
                    return 0
                }
            done
            return 0
        }

        is_enabled_value() {
            case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in
                1|true|yes|on|enabled) return 0 ;;
                *) return 1 ;;
            esac
        }

        csv_part() {
            printf '%s' "$1" | awk -F, -v n="$2" '{gsub(/^[ \t]+|[ \t]+$/, "", $n); print $n}'
        }

        json_csv_array() {
            printf '%s' "$1" | tr ',' '\n' | awk '
                function esc(s) {
                    gsub(/^[ \t]+|[ \t]+$/, "", s)
                    gsub(/\\/,"\\\\",s)
                    gsub(/"/,"\\\"",s)
                    return s
                }
                esc($0) != "" {
                    if (n++ > 0) printf ", "
                    printf "\"%s\"", esc($0)
                }
            '
        }

        SECURITY="$(url_decode "$(get_param security)")"
        TYPE="$(url_decode "$(get_param type)")"
        HOST="$(url_decode "$(get_param host)")"
        PATH_VAL="$(url_decode "$(get_param path)")"
        PBK="$(url_decode "$(get_param pbk)")"
        SID="$(url_decode "$(get_param sid)")"
        FP="$(url_decode "$(get_param fp)")"
        FLOW="$(url_decode "$(get_first_param flow xtlsFlow xtls_flow vlessFlow vless_flow)")"
        SNI="$(url_decode "$(get_param sni)")"
        ALPN="$(url_decode "$(get_param alpn)")"
        ENCRYPTION="$(url_decode "$(get_param encryption)")"
        HEADER_TYPE="$(url_decode "$(get_param headerType)")"
        SPX="$(url_decode "$(get_first_param spx spiderX spiderx)")"
        PACKET_ENCODING="$(url_decode "$(get_first_param packetEncoding packet_encoding)")"
        MUX_RAW="$(url_decode "$(get_first_param mux muxEnabled mux_enabled)")"
        MUX_CONCURRENCY="$(url_decode "$(get_first_param muxConcurrency mux_concurrency)")"
        FRAGMENT_RAW="$(url_decode "$(get_first_param fragment fragmentTemplate fragment_template fragmentPattern fragment_pattern)")"
        FRAGMENT_PACKETS="$(url_decode "$(get_first_param fragmentPackets fragmentPacket fragment_packets fragment_packet packets)")"
        FRAGMENT_LENGTH="$(url_decode "$(get_first_param fragmentLength fragmentSize fragment_length fragment_size length)")"
        FRAGMENT_INTERVAL="$(url_decode "$(get_first_param fragmentInterval fragment_interval interval)")"
        NOISE_RAW="$(url_decode "$(get_first_param noise noisePattern noise_pattern)")"
        NOISE_TYPE="$(url_decode "$(get_first_param noiseType noise_type)")"
        NOISE_PACKET="$(url_decode "$(get_first_param noisePacket noisePackets noise_packet noise_packets packet)")"
        NOISE_DELAY="$(url_decode "$(get_first_param noiseDelay noise_delay delay)")"
        RANDOM_UA="$(url_decode "$(get_first_param randomUserAgent random_user_agent userAgentRandom user_agent_random randomUA random_ua)")"

        [ -z "$TYPE" ]       && TYPE="tcp"
        [ -z "$FP" ]         && FP="firefox"
        [ -z "$ENCRYPTION" ] && ENCRYPTION="none"
        [ -z "$SNI" ]        && SNI="$HOST"
        [ -z "$SPX" ]        && SPX="/"

        if [ -n "$FRAGMENT_RAW" ]; then
            [ -n "$FRAGMENT_LENGTH" ]   || FRAGMENT_LENGTH="$(csv_part "$FRAGMENT_RAW" 1)"
            [ -n "$FRAGMENT_INTERVAL" ] || FRAGMENT_INTERVAL="$(csv_part "$FRAGMENT_RAW" 2)"
            [ -n "$FRAGMENT_PACKETS" ]  || FRAGMENT_PACKETS="$(csv_part "$FRAGMENT_RAW" 3)"
        fi

        if [ -n "$NOISE_RAW" ]; then
            noise_rest="$NOISE_RAW"
            case "$noise_rest" in
                *:*)
                    [ -n "$NOISE_TYPE" ] || NOISE_TYPE="${noise_rest%%:*}"
                    noise_rest="${noise_rest#*:}"
                    ;;
            esac
            [ -n "$NOISE_PACKET" ] || NOISE_PACKET="$(csv_part "$noise_rest" 1)"
            [ -n "$NOISE_DELAY" ]  || NOISE_DELAY="$(csv_part "$noise_rest" 2)"
        fi

        [ -n "$FRAGMENT_PACKETS" ] || FRAGMENT_PACKETS="tlshello"
        [ -n "$NOISE_PACKET" ] && [ -z "$NOISE_TYPE" ] && NOISE_TYPE="rand"

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
            USER_FLOW_LINE=$(cat <<EOF
,
                "flow": "$FLOW"
EOF
)
            logger -t shpun-build "VLESS user flow enabled: $FLOW"
        else
            USER_FLOW_LINE=""
        fi
        if [ -n "$PACKET_ENCODING" ]; then
            USER_PACKET_ENCODING_LINE=$(cat <<EOF
,
                "packetEncoding": "$PACKET_ENCODING"
EOF
)
        else
            USER_PACKET_ENCODING_LINE=""
        fi

        MUX_BLOCK=""
        if is_enabled_value "$MUX_RAW"; then
            case "$MUX_CONCURRENCY" in
                ''|*[!0-9]*) MUX_CONCURRENCY=8 ;;
            esac
            MUX_BLOCK=$(cat <<EOF
      "mux": {
        "enabled": true,
        "concurrency": $MUX_CONCURRENCY
      },
EOF
)
        fi

        NOISES_BLOCK=""
        if [ -n "$NOISE_TYPE" ] && [ -n "$NOISE_PACKET" ]; then
            [ -n "$NOISE_DELAY" ] || NOISE_DELAY="10-16"
            NOISES_BLOCK=$(cat <<EOF
,
        "noises": [
          {
            "type": "$NOISE_TYPE",
            "packet": "$NOISE_PACKET",
            "delay": "$NOISE_DELAY"
          }
        ]
EOF
)
        fi

        DIALER_SOCKOPT_BLOCK=""
        FRAGMENT_OUTBOUND_BLOCK=""
        if [ -n "$FRAGMENT_LENGTH" ] || [ -n "$FRAGMENT_INTERVAL" ] || [ -n "$NOISES_BLOCK" ]; then
            [ -n "$FRAGMENT_LENGTH" ] || FRAGMENT_LENGTH="10-20"
            [ -n "$FRAGMENT_INTERVAL" ] || FRAGMENT_INTERVAL="10-50"
            DIALER_SOCKOPT_BLOCK=$(cat <<EOF
        "sockopt": {
          "dialerProxy": "fragment"
        },
EOF
)
            FRAGMENT_OUTBOUND_BLOCK=$(cat <<EOF
    {
      "tag": "fragment",
      "protocol": "freedom",
      "settings": {
        "fragment": {
          "packets": "$FRAGMENT_PACKETS",
          "length": "$FRAGMENT_LENGTH",
          "interval": "$FRAGMENT_INTERVAL"
        }$NOISES_BLOCK
      }
    },
EOF
)
            logger -t shpun-build "VLESS masking enabled: fragment packets=$FRAGMENT_PACKETS length=$FRAGMENT_LENGTH interval=$FRAGMENT_INTERVAL noise=${NOISE_TYPE:-none}"
        fi

        if is_enabled_value "$RANDOM_UA"; then
            logger -t shpun-build "VLESS random user-agent requested by link but ignored: Xray router config has no HTTP user-agent layer for REALITY TCP"
        fi

        TLS_ALPN_LINE=""
        if [ -n "$ALPN" ]; then
            ALPN_ARRAY="$(json_csv_array "$ALPN")"
            if [ -n "$ALPN_ARRAY" ]; then
                TLS_ALPN_LINE=$(cat <<EOF
,
          "alpn": [$ALPN_ARRAY]
EOF
)
            fi
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
$TCP_HEADER_BLOCK$DIALER_SOCKOPT_BLOCK        "realitySettings": {
          "show": false,
          "fingerprint": "$FP",
          "serverName": "$SNI",
          "publicKey": "$PBK",
          "shortId": "$SID",
          "spiderX": "$SPX"
        }
      }
EOF
)
        elif [ "$SECURITY" = "tls" ]; then
            STREAM_SETTINGS=$(cat <<EOF
      "streamSettings": {
        "network": "$TYPE",
        "security": "tls",
$TCP_HEADER_BLOCK$DIALER_SOCKOPT_BLOCK        "tlsSettings": {
          "serverName": "$SNI",
          "fingerprint": "$FP",
          "allowInsecure": false$TLS_ALPN_LINE
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
      "tag": "dns-in",
      "listen": "127.0.0.1",
      "port": $DNS_PROXY_PORT,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "1.1.1.1",
        "port": 53,
        "network": "tcp,udp"
      },
      "sniffing": {
        "enabled": false
      }
    },
    {
      "tag": "http-in",
      "listen": "127.0.0.1",
      "port": $HTTP_PROXY_PORT,
      "protocol": "http",
      "settings": {}
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
        "destOverride": ["http", "tls"],
        "routeOnly": true
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
                "encryption": "$ENCRYPTION"$USER_FLOW_LINE$USER_PACKET_ENCODING_LINE
              }
            ]
          }
        ]
      },
$MUX_BLOCK
$STREAM_SETTINGS
    },
$FRAGMENT_OUTBOUND_BLOCK
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
        "inboundTag": ["dns-in"],
        "outboundTag": "proxy"
      },
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
$ALWAYS_VPN_RULE
$CUSTOM_VPN_RULE
$CUSTOM_DIRECT_RULE
$SMART_RU_RULE
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

        logger -t shpun-build "xray config built (VLESS, TCP+UDP, server=$(mask_host "$SERVER"):$PORT, security=${SECURITY:-none}, flow=${FLOW:-none}, redir=$REDIR_PORT, tproxy=$TPROXY_PORT)"
        exit 0
