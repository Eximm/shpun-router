#!/bin/sh

LOGTAG="shpun-custom-routes"
CUSTOM_FILE="/etc/shpun/routes/custom.json"
CHUNK_SIZE="${CUSTOM_ROUTES_CHUNK_SIZE:-50}"
LOCKDIR="/tmp/shpun-firewall.lock"

log() {
    logger -t "$LOGTAG" "$*"
}

lock_acquire() {
    [ "$SHPUN_FIREWALL_LOCK_HELD" = "1" ] && return 0

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

case "$CHUNK_SIZE" in
    ''|*[!0-9]*) CHUNK_SIZE=50 ;;
esac
[ "$CHUNK_SIZE" -lt 1 ] 2>/dev/null && CHUNK_SIZE=50
[ "$CHUNK_SIZE" -gt 1000 ] 2>/dev/null && CHUNK_SIZE=1000

validate_entry() {
    entry="$(printf '%s' "$1" | tr -d ' \t\r\n')"
    [ -z "$entry" ] && return 1

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

validate_domain() {
    entry="$(printf '%s' "$1" | tr -d ' \t\r\n')"
    [ -z "$entry" ] && return 1

    case "$entry" in
        *://*|*/*|*:*|*..*|.*|*.) return 1 ;;
        \*.*) entry="${entry#*.}" ;;
        *\**) return 1 ;;
    esac

    case "$entry" in
        *.*) ;;
        *) return 1 ;;
    esac

    oldifs="$IFS"
    IFS='.'
    set -- $entry
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

append_set_batch() {
    set_name="$1"
    key="$2"
    batch="$3"
    tmp="/tmp/shpun_custom_${set_name}_$$.tmp"

    rm -f "$tmp"

    if [ -s "$CUSTOM_FILE" ] && command -v jsonfilter >/dev/null 2>&1; then
        if ! jsonfilter -i "$CUSTOM_FILE" -e "@.${key}[*]" 2>/dev/null |
            tr -d '"' > "$tmp" 2>/dev/null; then
            rm -f "$tmp"
            log "$set_name: failed to prepare route entries"
            return 1
        fi
    fi

    printf 'flush set inet shpun %s\n' "$set_name" >> "$batch" || {
        rm -f "$tmp"
        log "$set_name: failed to write route batch"
        return 1
    }

    chunk=""
    count=0
    added=0
    skipped=0

    if [ -s "$tmp" ]; then
        while IFS= read -r entry; do
            entry="$(printf '%s' "$entry" | tr -d ' \t\r\n')"
            [ -z "$entry" ] && continue

            if ! validate_entry "$entry"; then
                if validate_domain "$entry"; then
                    skipped=$((skipped + 1))
                    continue
                fi
                log "invalid entry skipped: '$entry'"
                skipped=$((skipped + 1))
                continue
            fi

            chunk="${chunk:+$chunk, }$entry"
            count=$((count + 1))
            added=$((added + 1))

            if [ "$count" -ge "$CHUNK_SIZE" ]; then
                printf 'add element inet shpun %s { %s }\n' "$set_name" "$chunk" >> "$batch" || {
                    rm -f "$tmp"
                    log "$set_name: failed to write route batch"
                    return 1
                }
                chunk=""
                count=0
            fi
        done < "$tmp"
    fi

    rm -f "$tmp"

    if [ -n "$chunk" ]; then
        printf 'add element inet shpun %s { %s }\n' "$set_name" "$chunk" >> "$batch" || {
            log "$set_name: failed to write route batch"
            return 1
        }
    fi

    log "$set_name: prepared $added IP/CIDR entries, skipped $skipped domain/invalid entries"
    return 0
}

apply_routes() {
    batch="/tmp/shpun_custom_all_$$.nft"
    rm -f "$batch"

    : > "$batch" 2>/dev/null || {
        log "cannot create custom routes batch; keeping current live routes"
        return 1
    }

    nft list table inet shpun >/dev/null 2>&1 || {
        log "table inet shpun not found; routes will apply on next VPN start"
        return 1
    }

    for set_name in custom_vpn custom_direct; do
        nft list set inet shpun "$set_name" >/dev/null 2>&1 || {
            log "live set $set_name not found; keeping current live routes"
            return 1
        }
    done

    append_set_batch custom_vpn vpn "$batch" || {
        rm -f "$batch"
        return 1
    }
    append_set_batch custom_direct direct "$batch" || {
        rm -f "$batch"
        return 1
    }

    [ -s "$batch" ] || {
        rm -f "$batch"
        log "custom routes batch is empty; keeping current live routes"
        return 1
    }

    if ! nft -f "$batch" 2>/dev/null; then
        rm -f "$batch"
        log "atomic custom routes apply failed; keeping current live routes"
        return 1
    fi

    rm -f "$batch"
    log "custom VPN and direct routes applied in one transaction"
    return 0
}

case "${1:-apply}" in
    apply|"")
        lock_acquire || exit 1
        apply_routes
        exit $?
        ;;
    validate)
        while IFS= read -r line; do
            line="$(printf '%s' "$line" | tr -d ' \t\r\n')"
            [ -z "$line" ] && continue
            if validate_entry "$line"; then
                printf 'ok %s\n' "$line"
            else
                printf 'err %s\n' "$line"
            fi
        done
        exit 0
        ;;
    *)
        echo "Usage: $0 [apply|validate]" >&2
        exit 1
        ;;
esac
