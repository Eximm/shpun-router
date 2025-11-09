#!/bin/sh

STATE_DIR="/etc/shpun"
CODE_FILE="$STATE_DIR/router_code"

set -eu

if ! mkdir -p "$STATE_DIR"; then
	echo "Failed to create $STATE_DIR" >&2
	exit 1
fi

if [ -s "$CODE_FILE" ]; then
	CODE=$(cat "$CODE_FILE")
	printf 'Router code: %s\n' "$CODE"
	exit 0
fi

PREFIX=$(head -c 32 /dev/urandom 2>/dev/null | tr -dc 'A-Z0-9' | head -c 4 || true)
SUFFIX=$(head -c 32 /dev/urandom 2>/dev/null | tr -dc 'A-Z0-9' | head -c 4 || true)

if [ -z "$PREFIX" ] || [ -z "$SUFFIX" ]; then
	echo "Failed to generate router code" >&2
	exit 1
fi

CODE="${PREFIX}-${SUFFIX}"

printf '%s\n' "$CODE" >"$CODE_FILE"
printf 'Generated router code: %s\n' "$CODE"
