#!/bin/sh
#
# Shpun Router — генератор кода роутера
# Формат: XXXX-XXXX (A–Z, 0–9)

STATE_DIR="/etc/shpun"
CODE_FILE="$STATE_DIR/router_code"

mkdir -p "$STATE_DIR" || exit 1

# Если код уже есть — вывести и выйти
if [ -s "$CODE_FILE" ]; then
    cat "$CODE_FILE"
    exit 0
fi

# 8 случайных символов A-Z0-9
RAW="$(tr -dc 'A-Z0-9' </dev/urandom 2>/dev/null | head -c 8)"
[ "${#RAW}" -lt 8 ] && RAW="ABCD1234"

CODE="${RAW%????}-${RAW#????}"

echo "$CODE" >"$CODE_FILE"
echo "$CODE"
