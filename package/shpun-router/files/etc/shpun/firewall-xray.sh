#!/bin/sh

CONF="/etc/shpun/agent.conf"
LOGTAG="shpun-firewall"

ROUTES_DIR="/etc/shpun/routes"
MODE_FILE="$ROUTES_DIR/mode"
CIDRS_FILE="$ROUTES_DIR/ru.cidrs"
ALWAYS_VPN_CIDRS_FILE="$ROUTES_DIR/presets/always_vpn.cidrs"
CUSTOM_SCRIPT="/etc/shpun/apply-custom-routes.sh"
RU_LIVE_SHA_FILE="/tmp/shpun-ru-live.sha256"
DOMAIN_DIRECT_RELOAD_FILE="/tmp/shpun-domain-direct-needs-reload"
UDP_READY_FILE="/etc/shpun/udp_ready"

LOCKDIR="/tmp/shpun-firewall.lock"

REDIR_PORT_DEFAULT=12345
TPROXY_PORT_DEFAULT=12346
TPROXY_MARK_DEFAULT=233
TPROXY_TABLE_DEFAULT=233
CHUNK_SIZE_DEFAULT=500

log() {
    logger -t "$LOGTAG" "$*"
}

lock_acquire() {
    i=0
    while ! mkdir "$LOCKDIR" 2>/dev/null; do
        lock_pid="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
        case "$lock_pid" in
            ''|*[!0-9]*)
                if [ "$i" -ge 2 ]; then
                    rm -f "$LOCKDIR/pid" 2>/dev/null
                    rmdir "$LOCKDIR" 2>/dev/null || true
                    continue
                fi
                ;;
            *)
                if ! kill -0 "$lock_pid" 2>/dev/null; then
                    rm -f "$LOCKDIR/pid" 2>/dev/null
                    rmdir "$LOCKDIR" 2>/dev/null || true
                    continue
                fi
                ;;
        esac
        i=$((i + 1))
        [ "$i" -gt 120 ] && {
            log "failed to acquire firewall lock"
            return 1
        }
        sleep 1
    done

    echo "$$" > "$LOCKDIR/pid"
    trap 'rm -f "$LOCKDIR/pid" 2>/dev/null; rmdir "$LOCKDIR" 2>/dev/null' EXIT INT TERM
    return 0
}

load_conf() {
    [ -f "$CONF" ] && . "$CONF"

    [ -z "$REDIR_PORT" ]   && REDIR_PORT="$REDIR_PORT_DEFAULT"
    [ -z "$TPROXY_PORT" ]  && TPROXY_PORT="$TPROXY_PORT_DEFAULT"
    [ -z "$TPROXY_MARK" ]  && TPROXY_MARK="$TPROXY_MARK_DEFAULT"
    [ -z "$TPROXY_TABLE" ] && TPROXY_TABLE="$TPROXY_TABLE_DEFAULT"
    [ -z "$CHUNK_SIZE" ]   && CHUNK_SIZE="$CHUNK_SIZE_DEFAULT"

    case "$CHUNK_SIZE" in
        ''|*[!0-9]*) CHUNK_SIZE="$CHUNK_SIZE_DEFAULT" ;;
    esac
    [ "$CHUNK_SIZE" -lt 25 ] 2>/dev/null && CHUNK_SIZE=25
    [ "$CHUNK_SIZE" -gt 1000 ] 2>/dev/null && CHUNK_SIZE=1000
}

get_mode() {
    mode="full"
    [ -f "$MODE_FILE" ] && mode="$(tr -d '\r\n' < "$MODE_FILE")"
    [ -z "$mode" ] && mode="full"

    case "$mode" in
        full|smart_ru|split_ru)
            echo "$mode"
            ;;
        *)
            log "unknown mode '$mode' — using full"
            echo "full"
            ;;
    esac
}

get_lan_if() {
    uci get network.lan.device 2>/dev/null || \
    uci get network.lan.ifname 2>/dev/null || \
    echo br-lan
}

get_lan_ip() {
    uci get network.lan.ipaddr 2>/dev/null || echo 192.168.1.1
}

check_tproxy() {
    command -v nft >/dev/null 2>&1 || return 1

    modprobe nft_tproxy 2>/dev/null || true
    modprobe nf_tproxy_ipv4 2>/dev/null || true
    modprobe nf_tproxy_ipv6 2>/dev/null || true

    nft delete table inet shpun_tproxy_test >/dev/null 2>&1 || true
    nft add table inet shpun_tproxy_test >/dev/null 2>&1 || return 1

    nft 'add chain inet shpun_tproxy_test c { type filter hook prerouting priority mangle; policy accept; }' >/dev/null 2>&1 || {
        nft delete table inet shpun_tproxy_test >/dev/null 2>&1
        return 1
    }

    nft 'add rule inet shpun_tproxy_test c meta l4proto udp tproxy ip to :12346 meta mark set 0xe9' >/dev/null 2>&1
    rc=$?

    nft delete table inet shpun_tproxy_test >/dev/null 2>&1
    return "$rc"
}

tproxy_routes_add() {
    ip rule show | grep -q "fwmark 0x${TPROXY_MARK}" || \
        ip rule add fwmark "0x${TPROXY_MARK}" table "$TPROXY_TABLE" 2>/dev/null

    ip route show table "$TPROXY_TABLE" | grep -q "local default" || \
        ip route add local default dev lo table "$TPROXY_TABLE" 2>/dev/null

    log "tproxy: ip rule/route added (mark=0x${TPROXY_MARK}, table=${TPROXY_TABLE})"
}

tproxy_routes_del() {
    while ip rule show | grep -q "fwmark 0x${TPROXY_MARK}"; do
        ip rule del fwmark "0x${TPROXY_MARK}" table "$TPROXY_TABLE" 2>/dev/null || break
    done

    ip route del local default dev lo table "$TPROXY_TABLE" 2>/dev/null
    log "tproxy: ip rule/route removed"
}

nft_create_base() {
    MODE="$1"

    nft delete table inet shpun 2>/dev/null

    nft add table inet shpun || return 1

    # Keep ru_dst available in every mode.  This lets split_ru be prepared
    # while the current rules keep carrying traffic, then enabled with only a
    # short ruleset swap instead of deleting the live table first.
    nft add set inet shpun ru_dst '{ type ipv4_addr; flags interval; auto-merge; }' || return 1

    nft add set inet shpun always_vpn '{ type ipv4_addr; flags interval; auto-merge; }' || return 1
    nft add set inet shpun custom_direct '{ type ipv4_addr; flags interval; auto-merge; }' || return 1
    nft add set inet shpun custom_vpn '{ type ipv4_addr; flags interval; auto-merge; }' || return 1
    # dnsmasq populates this set for smart_ru and custom direct domains.  It is
    # intentionally used only for UDP: TCP remains routed by Xray using SNI.
    nft add set inet shpun domain_direct '{ type ipv4_addr; }' || return 1
    : > "$DOMAIN_DIRECT_RELOAD_FILE"

    nft add chain inet shpun prerouting '{ type nat hook prerouting priority dstnat; policy accept; }' || return 1

    return 0
}

nft_set_has_elements() {
    nft list set inet shpun "$1" 2>/dev/null | grep -q 'elements = {'
}

nft_fill_cidr_set_slow() {
    set_name="$1"
    file="$2"
    label="$3"
    replace_existing="${4:-0}"
    batch_total="${5:-0}"
    batch_skipped="${6:-0}"

    added=0
    failed=0
    skipped="$batch_skipped"

    [ "$replace_existing" = "1" ] && nft flush set inet shpun "$set_name" >/dev/null 2>&1

    while IFS= read -r cidr; do
        cidr="$(printf '%s' "$cidr" | tr -d ' \t\r')"
        [ -z "$cidr" ] && continue

        case "$cidr" in
            \#*) continue ;;
            *[!0-9./]*)
                skipped=$((skipped + 1))
                continue
                ;;
        esac

        case "$cidr" in
            */*) ip="${cidr%%/*}"; prefix="${cidr##*/}" ;;
            *)   ip="$cidr";       prefix="32" ;;
        esac

        case "$prefix" in
            ''|*[!0-9]*)
                skipped=$((skipped + 1))
                continue
                ;;
        esac

        [ "$prefix" -gt 32 ] 2>/dev/null && {
            skipped=$((skipped + 1))
            continue
        }

        oldifs="$IFS"
        IFS='.'
        set -- $ip
        IFS="$oldifs"

        [ "$#" -eq 4 ] || {
            skipped=$((skipped + 1))
            continue
        }

        valid_ip=1
        for octet in "$@"; do
            case "$octet" in
                ''|*[!0-9]*) valid_ip=0 ;;
            esac
            [ "$octet" -gt 255 ] 2>/dev/null && valid_ip=0
        done

        [ "$valid_ip" -eq 1 ] || {
            skipped=$((skipped + 1))
            continue
        }

        if nft add element inet shpun "$set_name" "{ $cidr }" >/dev/null 2>&1; then
            added=$((added + 1))
        else
            failed=$((failed + 1))
        fi
    done < "$file"

    if [ "$added" -gt 0 ] || nft_set_has_elements "$set_name"; then
        log "$label: fallback loaded after batch failure (added=$added failed=$failed skipped=$skipped batch_total=$batch_total)"
        return 0
    fi

    log "$label: fallback failed after batch failure (added=0 failed=$failed skipped=$skipped batch_total=$batch_total)"
    return 1
}

nft_fill_cidr_set() {
    set_name="$1"
    file="$2"
    label="$3"
    replace_existing="${4:-0}"
    [ -s "$file" ] || return 0

    tmp="/tmp/shpun_${set_name}_$$.nft"
    clean_tmp="${tmp}.clean"
    start_ts="$(date +%s 2>/dev/null || echo 0)"

    log "$label: loading started chunk=$CHUNK_SIZE batch=$tmp"

    chunk=""
    count=0
    total=0
    skipped=0

    rm -f "$tmp" "$clean_tmp"
    if ! tr -d ' \t\r' < "$file" > "$clean_tmp" 2>/dev/null; then
        rm -f "$tmp" "$clean_tmp"
        log "$label: failed to prepare normalized CIDR input"
        return 1
    fi

    if [ "$replace_existing" = "1" ]; then
        if ! printf 'flush set inet shpun %s\n' "$set_name" > "$tmp"; then
            rm -f "$tmp" "$clean_tmp"
            log "$label: failed to initialize nft batch"
            return 1
        fi
    fi

    while IFS= read -r cidr; do
        [ -z "$cidr" ] && continue

        case "$cidr" in
            \#*) continue ;;
        esac

        case "$cidr" in
            *[!0-9./]*)
                skipped=$((skipped + 1))
                continue
                ;;
        esac

        case "$cidr" in
            */*) ip="${cidr%%/*}"; prefix="${cidr##*/}" ;;
            *)   ip="$cidr";       prefix="32" ;;
        esac

        case "$prefix" in
            ''|*[!0-9]*)
                skipped=$((skipped + 1))
                continue
                ;;
        esac

        [ "$prefix" -gt 32 ] 2>/dev/null && {
            skipped=$((skipped + 1))
            continue
        }

        oldifs="$IFS"
        IFS='.'
        set -- $ip
        IFS="$oldifs"

        if [ "$#" -ne 4 ]; then
            skipped=$((skipped + 1))
            continue
        fi

        valid_ip=1
        for octet in "$@"; do
            case "$octet" in
                ''|*[!0-9]*) valid_ip=0 ;;
            esac
            [ "$octet" -gt 255 ] 2>/dev/null && valid_ip=0
        done

        if [ "$valid_ip" -ne 1 ]; then
            skipped=$((skipped + 1))
            continue
        fi

        chunk="${chunk:+$chunk, }$cidr"
        count=$((count + 1))
        total=$((total + 1))

        if [ "$count" -ge "$CHUNK_SIZE" ]; then
            if ! printf 'add element inet shpun %s { %s }\n' "$set_name" "$chunk" >> "$tmp"; then
                rm -f "$tmp" "$clean_tmp"
                log "$label: failed to write nft batch"
                return 1
            fi
            chunk=""
            count=0
        fi
    done < "$clean_tmp"

    if [ -n "$chunk" ]; then
        if ! printf 'add element inet shpun %s { %s }\n' "$set_name" "$chunk" >> "$tmp"; then
            rm -f "$tmp" "$clean_tmp"
            log "$label: failed to write nft batch"
            return 1
        fi
    fi

    if [ "$total" -eq 0 ]; then
        rm -f "$tmp" "$clean_tmp"
        log "$label: no valid CIDR entries found (skipped=$skipped)"
        return 1
    fi

    if ! nft -f "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp" "$clean_tmp"
        log "$label: batch load failed total=$total skipped=$skipped, trying fallback"
        nft_fill_cidr_set_slow "$set_name" "$file" "$label" "$replace_existing" "$total" "$skipped"
        return $?
    fi

    rm -f "$tmp" "$clean_tmp"
    end_ts="$(date +%s 2>/dev/null || echo 0)"
    duration=$((end_ts - start_ts))
    log "$label: loaded $total CIDR entries (skipped=$skipped, duration=${duration}s)"
    return 0
}

nft_fill_ru_dst() {
    nft_fill_cidr_set ru_dst "$CIDRS_FILE" ru_dst || return 1
    mark_ru_live
}

nft_fill_always_vpn() {
    [ -s "$ALWAYS_VPN_CIDRS_FILE" ] || return 0
    nft_fill_cidr_set always_vpn "$ALWAYS_VPN_CIDRS_FILE" always_vpn || {
        log "always_vpn: ignored invalid optional CIDR list"
        return 0
    }
}

nft_replace_cidr_set() {
    set_name="$1"
    file="$2"
    label="$3"

    if ! nft list table inet shpun >/dev/null 2>&1; then
        log "$label: live nft table absent, current file will be loaded on next VPN start"
        return 0
    fi

    if ! nft list set inet shpun "$set_name" >/dev/null 2>&1; then
        log "$label: live set $set_name absent, current file will be loaded on next applicable VPN start"
        return 0
    fi

    if ! nft_fill_cidr_set "$set_name" "$file" "$label" 1; then
        log "$label: keeping current live set after failed transactional load"
        return 1
    fi

    log "$label: live nft set updated in one transaction without VPN restart"
    return 0
}

calc_file_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'
    fi
}

mark_ru_live() {
    ru_sha="$(calc_file_sha256 "$CIDRS_FILE")"
    [ -n "$ru_sha" ] && printf '%s\n' "$ru_sha" > "$RU_LIVE_SHA_FILE"
    return 0
}

ru_live_matches_file() {
    nft_set_has_elements ru_dst || return 1
    [ -s "$RU_LIVE_SHA_FILE" ] || return 1
    live_sha="$(tr -d '\r\n ' < "$RU_LIVE_SHA_FILE" 2>/dev/null)"
    file_sha="$(calc_file_sha256 "$CIDRS_FILE")"
    [ -n "$file_sha" ] && [ "$live_sha" = "$file_sha" ]
}

nft_replace_ru_dst() {
    nft_replace_cidr_set ru_dst "$CIDRS_FILE" ru_dst || return 1
    mark_ru_live
}

nft_apply_tcp_redirect_rules() {
    LAN_IF="$1"
    LAN_IP="$2"
    MODE="$3"

    nft flush chain inet shpun prerouting || return 1

    nft add rule inet shpun prerouting iifname "$LAN_IF" ip daddr "$LAN_IP" return || return 1
    nft add rule inet shpun prerouting iifname "$LAN_IF" ip daddr 0.0.0.0/8 return || return 1
    nft add rule inet shpun prerouting iifname "$LAN_IF" ip daddr 10.0.0.0/8 return || return 1
    nft add rule inet shpun prerouting iifname "$LAN_IF" ip daddr 127.0.0.0/8 return || return 1
    nft add rule inet shpun prerouting iifname "$LAN_IF" ip daddr 169.254.0.0/16 return || return 1
    nft add rule inet shpun prerouting iifname "$LAN_IF" ip daddr 172.16.0.0/12 return || return 1
    nft add rule inet shpun prerouting iifname "$LAN_IF" ip daddr 192.168.0.0/16 return || return 1
    nft add rule inet shpun prerouting iifname "$LAN_IF" ip daddr 224.0.0.0/4 return || return 1
    nft add rule inet shpun prerouting iifname "$LAN_IF" ip daddr 255.255.255.255 return || return 1
    nft add rule inet shpun prerouting iifname "$LAN_IF" ip daddr @always_vpn ip protocol tcp counter redirect to :"$REDIR_PORT" || return 1
    nft add rule inet shpun prerouting iifname "$LAN_IF" ip daddr @custom_vpn ip protocol tcp counter redirect to :"$REDIR_PORT" || return 1
    nft add rule inet shpun prerouting iifname "$LAN_IF" ip daddr @custom_direct counter return || return 1

    if [ "$MODE" = "split_ru" ]; then
        nft add rule inet shpun prerouting iifname "$LAN_IF" ip daddr @ru_dst return || return 1
    fi

    nft add rule inet shpun prerouting iifname "$LAN_IF" ip protocol tcp tcp dport != "$REDIR_PORT" counter redirect to :"$REDIR_PORT" || return 1

    return 0
}

nft_apply_udp_rules() {
    LAN_IF="$1"
    LAN_IP="$2"
    MODE="$3"

    nft add chain inet shpun prerouting_mangle '{ type filter hook prerouting priority mangle; policy accept; }' 2>/dev/null || true
    nft flush chain inet shpun prerouting_mangle || return 1

    nft add rule inet shpun prerouting_mangle iifname "$LAN_IF" ip daddr "$LAN_IP" return || return 1
    nft add rule inet shpun prerouting_mangle iifname "$LAN_IF" ip daddr 0.0.0.0/8 return || return 1
    nft add rule inet shpun prerouting_mangle iifname "$LAN_IF" ip daddr 10.0.0.0/8 return || return 1
    nft add rule inet shpun prerouting_mangle iifname "$LAN_IF" ip daddr 127.0.0.0/8 return || return 1
    nft add rule inet shpun prerouting_mangle iifname "$LAN_IF" ip daddr 169.254.0.0/16 return || return 1
    nft add rule inet shpun prerouting_mangle iifname "$LAN_IF" ip daddr 172.16.0.0/12 return || return 1
    nft add rule inet shpun prerouting_mangle iifname "$LAN_IF" ip daddr 192.168.0.0/16 return || return 1
    nft add rule inet shpun prerouting_mangle iifname "$LAN_IF" ip daddr 224.0.0.0/4 return || return 1
    nft add rule inet shpun prerouting_mangle iifname "$LAN_IF" ip daddr 255.255.255.255 return || return 1

    nft add rule inet shpun prerouting_mangle iifname "$LAN_IF" meta l4proto udp ip daddr @always_vpn counter tproxy ip to :"$TPROXY_PORT" meta mark set "0x${TPROXY_MARK}" || return 1
    nft add rule inet shpun prerouting_mangle iifname "$LAN_IF" meta l4proto udp ip daddr @custom_vpn counter tproxy ip to :"$TPROXY_PORT" meta mark set "0x${TPROXY_MARK}" || return 1
    nft add rule inet shpun prerouting_mangle iifname "$LAN_IF" ip daddr @custom_direct counter return || return 1
    nft add rule inet shpun prerouting_mangle iifname "$LAN_IF" meta l4proto udp ip daddr @domain_direct counter return || return 1

    if [ "$MODE" = "split_ru" ]; then
        nft add rule inet shpun prerouting_mangle iifname "$LAN_IF" ip daddr @ru_dst return || return 1
    fi

    if [ "$MODE" = "smart_ru" ]; then
        nft add rule inet shpun prerouting_mangle iifname "$LAN_IF" meta l4proto udp udp dport 443 counter reject || return 1
    fi

    nft add rule inet shpun prerouting_mangle iifname "$LAN_IF" meta l4proto udp counter tproxy ip to :"$TPROXY_PORT" meta mark set "0x${TPROXY_MARK}" || return 1

    return 0
}

nft_apply_custom() {
    [ -x "$CUSTOM_SCRIPT" ] || {
        log "custom routes helper not found"
        return 1
    }

    SHPUN_FIREWALL_LOCK_HELD=1 "$CUSTOM_SCRIPT" apply || {
        log "custom routes apply failed"
        return 1
    }

    return 0
}

nft_ensure_live_sets() {
    nft list table inet shpun >/dev/null 2>&1 || return 1

    for set_name in ru_dst always_vpn custom_direct custom_vpn; do
        if ! nft list set inet shpun "$set_name" >/dev/null 2>&1; then
            nft add set inet shpun "$set_name" '{ type ipv4_addr; flags interval; auto-merge; }' || return 1
        fi
    done

    if ! nft list set inet shpun domain_direct >/dev/null 2>&1; then
        nft add set inet shpun domain_direct '{ type ipv4_addr; }' || return 1
        : > "$DOMAIN_DIRECT_RELOAD_FILE"
    fi

    return 0
}

nft_prepare_mode() {
    MODE="$(get_mode)"

    nft_ensure_live_sets || {
        log "prepare mode=$MODE: live nft table is not ready"
        return 1
    }

    if [ "$MODE" = "split_ru" ]; then
        [ -s "$CIDRS_FILE" ] || {
            log "prepare mode=split_ru: $CIDRS_FILE missing"
            return 1
        }
        if ru_live_matches_file; then
            log "prepare mode=split_ru: reusing verified live ru_dst set"
        else
            nft_replace_ru_dst || return 1
        fi
    fi

    log "prepare mode=$MODE: live sets ready; active traffic rules unchanged"
    return 0
}

nft_apply_mode_live() {
    LAN_IF="$(get_lan_if)"
    LAN_IP="$(get_lan_ip)"
    MODE="$(get_mode)"

    if [ "${SHPUN_MODE_PREPARED:-0}" != "1" ]; then
        nft_prepare_mode || return 1
    else
        nft_ensure_live_sets || return 1
        log "live mode=$MODE: using preloaded route sets"
    fi

    if ! nft_apply_tcp_redirect_rules "$LAN_IF" "$LAN_IP" "$MODE"; then
        log "live mode=$MODE: failed to replace TCP rules"
        return 1
    fi

    if check_tproxy; then
        tproxy_routes_add
        if ! nft_apply_udp_rules "$LAN_IF" "$LAN_IP" "$MODE"; then
            log "live mode=$MODE: failed to replace UDP rules"
            return 1
        fi
        echo "ok" > "$UDP_READY_FILE"
    else
        rm -f "$UDP_READY_FILE"
        nft delete chain inet shpun prerouting_mangle 2>/dev/null || true
        tproxy_routes_del
    fi

    nft_apply_custom || return 1
    log "live mode=$MODE: firewall rules activated without rebuilding the nft table"
    return 0
}

nft_init() {
    start_ts="$(date +%s 2>/dev/null || echo 0)"

    LAN_IF="$(get_lan_if)"
    LAN_IP="$(get_lan_ip)"
    MODE="$(get_mode)"

    if [ "$MODE" = "split_ru" ] && [ ! -s "$CIDRS_FILE" ]; then
        log "nft init: split_ru requested but $CIDRS_FILE missing"
        return 1
    fi

    rm -f "$UDP_READY_FILE"
    WITH_TPROXY="no"
    if check_tproxy; then
        WITH_TPROXY="yes"
        tproxy_routes_add
        log "nft init: tproxy OK (port=$TPROXY_PORT mark=0x${TPROXY_MARK})"
    else
        log "nft init: tproxy unavailable — TCP-only"
        tproxy_routes_del
    fi

    log "nft init: mode=$MODE tproxy=$WITH_TPROXY redirect=$REDIR_PORT lan=$LAN_IF chunk=$CHUNK_SIZE"

    if ! nft_create_base "$MODE"; then
        log "nft init: failed to create base nft objects"
        nft delete table inet shpun 2>/dev/null
        tproxy_routes_del
        return 1
    fi

    nft_fill_always_vpn

    if [ "$MODE" = "split_ru" ]; then
        if ! nft_fill_ru_dst; then
            log "nft init: failed to load ru_dst"
            nft delete table inet shpun 2>/dev/null
            tproxy_routes_del
            return 1
        fi
    fi

    if ! nft_apply_tcp_redirect_rules "$LAN_IF" "$LAN_IP" "$MODE"; then
        log "nft init: failed to apply tcp rules"
        nft delete table inet shpun 2>/dev/null
        tproxy_routes_del
        return 1
    fi

    if [ "$WITH_TPROXY" = "yes" ]; then
        if ! nft_apply_udp_rules "$LAN_IF" "$LAN_IP" "$MODE"; then
            log "nft init: failed to apply tproxy rules, falling back to TCP-only"
            nft delete chain inet shpun prerouting_mangle 2>/dev/null
            tproxy_routes_del
            WITH_TPROXY="no"
        else
            echo "ok" > "$UDP_READY_FILE"
        fi
    fi

    if ! nft_apply_custom; then
        log "nft init: failed to apply custom routes"
        rm -f "$UDP_READY_FILE"
        nft delete table inet shpun 2>/dev/null
        tproxy_routes_del
        return 1
    fi

    end_ts="$(date +%s 2>/dev/null || echo 0)"
    duration=$((end_ts - start_ts))
    log "nft init: complete mode=$MODE tproxy=$WITH_TPROXY duration=${duration}s"
    return 0
}

nft_stop() {
    log "removing table inet shpun"
    rm -f "$UDP_READY_FILE"
    rm -f "$RU_LIVE_SHA_FILE"
    rm -f "$DOMAIN_DIRECT_RELOAD_FILE"
    nft delete table inet shpun 2>/dev/null
    tproxy_routes_del
}

case "$1" in
    start|"")
        load_conf
        lock_acquire || exit 1
        command -v nft >/dev/null 2>&1 && { nft_init && exit 0; }
        log "nft not found"
        exit 1
        ;;
    init)
        load_conf
        lock_acquire || exit 1
        command -v nft >/dev/null 2>&1 && { nft_init && exit 0; }
        exit 1
        ;;
    apply-mode)
        load_conf
        lock_acquire || exit 1
        command -v nft >/dev/null 2>&1 && { nft_apply_mode_live && exit 0; }
        exit 1
        ;;
    prepare-mode)
        load_conf
        lock_acquire || exit 1
        command -v nft >/dev/null 2>&1 && { nft_prepare_mode && exit 0; }
        exit 1
        ;;
    reload-always-vpn)
        load_conf
        lock_acquire || exit 1
        command -v nft >/dev/null 2>&1 && { nft_replace_cidr_set always_vpn "$ALWAYS_VPN_CIDRS_FILE" always_vpn && exit 0; }
        exit 1
        ;;
    reload-ru)
        load_conf
        lock_acquire || exit 1
        command -v nft >/dev/null 2>&1 && { nft_replace_ru_dst && exit 0; }
        exit 1
        ;;
    stop)
        load_conf
        lock_acquire || exit 1
        command -v nft >/dev/null 2>&1 && nft_stop
        exit 0
        ;;
    restart)
        "$0" init
        exit $?
        ;;
    *)
        echo "Usage: $0 [start|init|prepare-mode|apply-mode|reload-always-vpn|reload-ru|stop|restart]" >&2
        exit 1
        ;;
esac
