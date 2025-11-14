#!/bin/sh
#
# Shpun Router — генератор кода роутера
# Формат: XXXX-XXXX (символы A–Z и 0–9)

STATE_DIR="/etc/shpun"
CODE_FILE="$STATE_DIR/router_code"

set -eu

mkdir -p "$STATE_DIR" || {
    echo "Failed to create $STATE_DIR" >&2
    exit 1
}

# Если код уже существует — просто вывести и выйти
if [ -s "$CODE_FILE" ]; then
    CODE="$(cat "$CODE_FILE")"
    printf 'Router code: %s\n' "$CODE"
    exit 0
fi

# Генерация 8 случайных символов A-Z0-9 из /dev/urandom
RAW="$(tr -dc 'A-Z0-9' </dev/urandom 2>/dev/null | head -c 8)"
[ "${#RAW}" -lt 8 ] && RAW="ABCD1234"

CODE="${RAW%????}-${RAW#????}"

echo "$CODE" >"$CODE_FILE"
echo "Generated router code: $CODE"
