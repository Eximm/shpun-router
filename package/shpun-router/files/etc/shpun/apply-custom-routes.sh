#!/bin/sh

LOGTAG="shpun-custom-routes"
CUSTOM_FILE="/etc/shpun/routes/custom.json"
CHUNK_SIZE="${CUSTOM_ROUTES_CHUNK_SIZE:-50}"

log() {
    logger -t "$LOGTAG" "$*"
}

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

apply_set() {
    set_name="$1"
    key="$2"
    tmp="/tmp/shpun_custom_${set_name}_$$.tmp"

    nft list table inet shpun >/dev/null 2>&1 || {
        log "table inet shpun not found — skipping $set_name"
        return 1
    }

    nft list set inet shpun "$set_name" >/dev/null 2>&1 || {
        nft add set inet shpun "$set_name" '{ type ipv4_addr; flags interval; }' 2>/dev/null || {
            log "failed to create set $set_name"
            return 1
        }
    }

    nft flush set inet shpun "$set_name" 2>/dev/null || {
        log "failed to flush set $set_name"
        return 1
    }

    rm -f "$tmp"

    if [ -f "$CUSTOM_FILE" ] && [ -s "$CUSTOM_FILE" ] && command -v jsonfilter >/dev/null 2>&1; then
        jsonfilter -i "$CUSTOM_FILE" -e "@.${key}[*]" 2>/dev/null | tr -d '"' > "$tmp" 2>/dev/null
    fi

    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        log "$set_name: empty, nothing to apply"
        return 0
    fi

    chunk=""
    count=0
    added=0
    skipped=0
    failed=0

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
            nft add element inet shpun "$set_name" "{ $chunk }" 2>/dev/null || {
                log "failed to add elements to $set_name"
                failed=1
            }
            chunk=""
            count=0
        fi
    done < "$tmp"

    rm -f "$tmp"

    if [ -n "$chunk" ]; then
        nft add element inet shpun "$set_name" "{ $chunk }" 2>/dev/null || {
            log "failed to add final elements to $set_name"
            failed=1
        }
    fi

    log "$set_name: applied $added entries, skipped $skipped"

    [ "$failed" -eq 0 ]
}

case "${1:-apply}" in
    apply|"")
        rc=0
        apply_set "custom_vpn" "vpn" || rc=1
        apply_set "custom_direct" "direct" || rc=1
        exit "$rc"
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
