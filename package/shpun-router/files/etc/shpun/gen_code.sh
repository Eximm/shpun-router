#!/bin/sh

STATE_DIR="/etc/shpun"
CODE_FILE="$STATE_DIR/router_code"

set -eu

mkdir -p "$STATE_DIR" || {
    echo "Failed to create $STATE_DIR" >&2
    exit 1
}

if [ -s "$CODE_FILE" ]; then
    CODE=$(cat "$CODE_FILE")
    printf 'Router code: %s\n' "$CODE"
    exit 0
fi

gen_part() {
    head -c 32 /dev/urandom 2>/dev/null | tr -dc 'A-Z0-9' | head -c 4
}

PREFIX=$(gen_part || true)
SUFFIX=$(gen_part || true)

if [ -z "$PREFIX" ] || [ -z "$SUFFIX" ]; then
    echo "Failed to generate router code" >&2
    exit 1
fi

CODE="${PREFIX}-${SUFFIX}"

printf '%s\n' "$CODE" >"$CODE_FILE"
printf 'Generated router code: %s\n' "$CODE"
