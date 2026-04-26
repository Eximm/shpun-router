#!/bin/sh

# /etc/shpun/apply-custom-routes.sh
#
# Применяет пользовательские маршруты из custom.json в nftables.
# Вызывается из:
#   - shpun.uc (custom_routes_set) — при сохранении из UI
#   - firewall-xray.sh (nft_init) — при старте VPN
#
# Требует: nftables таблица inet shpun уже существует (создаётся firewall-xray.sh)
# Файл данных: /etc/shpun/routes/custom.json
# Формат: { "vpn": ["1.2.3.4", "5.0.0.0/8"], "direct": ["10.10.10.0/24"] }

LOGTAG="shpun-custom-routes"
CUSTOM_FILE="/etc/shpun/routes/custom.json"

log() {
    logger -t "$LOGTAG" "$*"
}

# ──────────────────────────────────────────────
# Валидация одной записи — только IPv4 и CIDR
# ──────────────────────────────────────────────
validate_entry() {
    local entry="$1"

    # Убираем пробелы
    entry="$(printf '%s' "$entry" | tr -d ' \t\r\n')"
    [ -z "$entry" ] && return 1

    # Проверяем формат: IP или IP/prefix
    local ip prefix

    case "$entry" in
        */*)
            ip="${entry%%/*}"
            prefix="${entry##*/}"
            ;;
        *)
            ip="$entry"
            prefix="32"
            ;;
    esac

    # Проверяем что prefix — число 0-32
    case "$prefix" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac
    [ "$prefix" -gt 32 ] 2>/dev/null && return 1

    # Проверяем формат IP (четыре октета 0-255)
    local IFS_OLD="$IFS"
    IFS='.'
    # shellcheck disable=SC2086
    set -- $ip
    IFS="$IFS_OLD"

    [ $# -ne 4 ] && return 1

    local octet
    for octet in "$1" "$2" "$3" "$4"; do
        case "$octet" in
            ''|*[!0-9]*)
                return 1
                ;;
        esac
        [ "$octet" -gt 255 ] 2>/dev/null && return 1
    done

    return 0
}

# ──────────────────────────────────────────────
# Читаем custom.json и отдаём список для нужного ключа
# Формат вывода: один IP/CIDR на строку
# ──────────────────────────────────────────────
read_entries() {
    local key="$1"   # "vpn" или "direct"

    [ -f "$CUSTOM_FILE" ] || return 0
    [ -s "$CUSTOM_FILE" ] || return 0

    command -v jsonfilter >/dev/null 2>&1 || {
        log "jsonfilter not found, cannot read $CUSTOM_FILE"
        return 0
    }

    # jsonfilter возвращает одно значение на строку для массива
    jsonfilter -i "$CUSTOM_FILE" -e "@.${key}[*]" 2>/dev/null | \
        tr -d '"' | \
        while IFS= read -r entry; do
            entry="$(printf '%s' "$entry" | tr -d ' \t\r\n')"
            [ -z "$entry" ] && continue
            printf '%s\n' "$entry"
        done
}

# ──────────────────────────────────────────────
# Применяем один set в nftables
# ──────────────────────────────────────────────
apply_set() {
    local set_name="$1"   # custom_vpn или custom_direct
    local key="$2"         # vpn или direct

    # Проверяем что таблица существует
    nft list table inet shpun >/dev/null 2>&1 || {
        log "table inet shpun not found — skipping $set_name"
        return 1
    }

    # Создаём set если не существует
    nft list set inet shpun "$set_name" >/dev/null 2>&1 || {
        nft add set inet shpun "$set_name" \
            '{ type ipv4_addr; flags interval; }' 2>/dev/null || {
            log "failed to create set $set_name"
            return 1
        }
    }

    # Очищаем set
    nft flush set inet shpun "$set_name" 2>/dev/null

    # Наполняем из файла
    local chunk=""
    local count=0
    local added=0
    local skipped=0

    while IFS= read -r entry; do
        [ -z "$entry" ] && continue

        if ! validate_entry "$entry"; then
            log "invalid entry skipped: '$entry'"
            skipped=$((skipped + 1))
            continue
        fi

        if [ -z "$chunk" ]; then
            chunk="$entry"
        else
            chunk="$chunk, $entry"
        fi

        count=$((count + 1))
        added=$((added + 1))

        # Добавляем порциями по 100
        if [ "$count" -ge 100 ]; then
            nft add element inet shpun "$set_name" "{ $chunk }" 2>/dev/null || \
                log "failed to add elements to $set_name: $chunk"
            chunk=""
            count=0
        fi
    done <<EOF
$(read_entries "$key")
EOF

    # Остаток
    if [ -n "$chunk" ]; then
        nft add element inet shpun "$set_name" "{ $chunk }" 2>/dev/null || \
            log "failed to add elements to $set_name: $chunk"
    fi

    log "$set_name: applied $added entries, skipped $skipped"
    return 0
}

# ──────────────────────────────────────────────
# Добавляем правила в prerouting если их нет
# Правила custom_direct и custom_vpn должны стоять
# ПОСЛЕ исключения LAN IP, НО ДО ru_dst и основного правила
# ──────────────────────────────────────────────
ensure_rules() {
    # Проверяем есть ли уже правила с custom в цепочке
    # Если есть — не дублируем
    nft list chain inet shpun prerouting 2>/dev/null | grep -q "custom_direct" && \
    nft list chain inet shpun prerouting 2>/dev/null | grep -q "custom_vpn" && \
        return 0

    # Правила добавляются через firewall-xray.sh при init
    # Здесь только обновляем sets — правила уже в цепочке
    return 0
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────
case "${1:-apply}" in
    apply|"")
        apply_set "custom_vpn"    "vpn"
        apply_set "custom_direct" "direct"
        ensure_rules
        exit 0
        ;;

    validate)
        # Режим валидации: читает stdin, выводит ok/err для каждой строки
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