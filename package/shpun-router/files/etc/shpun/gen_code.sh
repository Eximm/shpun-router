#!/bin/sh
STATE_DIR="/etc/shpun"
CODE_FILE="$STATE_DIR/router_code"
mkdir -p "$STATE_DIR"

if [ -f "$CODE_FILE" ]; then
  echo "Router code: $(cat $CODE_FILE)"
  exit 0
fi

PREFIX=$(head /dev/urandom | tr -dc 'A-Z0-9' | head -c 4)
SUFFIX=$(head /dev/urandom | tr -dc 'A-Z0-9' | head -c 4)
CODE="${PREFIX}-${SUFFIX}"

echo "$CODE" > "$CODE_FILE"
echo "Generated router code: $CODE"
