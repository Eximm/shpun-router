#!/bin/sh

STATE_DIR="/etc/shpun"
CODE_FILE="$STATE_DIR/router_code"
SUB_FILE="$STATE_DIR/subscription_url"
XRAY_CONF="/etc/xray/config.json"
API_URL="https://bill.shpyn.online/shm/v1/public/router_public"

mkdir -p "$STATE_DIR"

log() {
  logger -t shpun-agent "$*"
}

if [ ! -f "$CODE_FILE" ]; then
  /etc/shpun/gen_code.sh >/dev/null 2>&1 || log "gen_code failed"
fi

CODE="$(cat "$CODE_FILE" 2>/dev/null)"

log "started, code=$CODE"

while true; do
  JSON="$(curl -s "$API_URL?code=$CODE&format=json")"
  OK="$(echo "$JSON" | grep -o '"ok":[0-9]*' | head -1 | cut -d: -f2)"

  if [ "$OK" != "1" ]; then
    sleep 15
    continue
  fi

  SUB="$(echo "$JSON" | sed -n 's/.*"subscription_url":"\([^"]*\)".*/\1/p' || true)"
  if [ -z "$SUB" ]; then
    sleep 15
    continue
  fi

  echo "$SUB" > "$SUB_FILE"
  log "got subscription url"

  curl -s "$SUB" -o "$XRAY_CONF"
  if [ ! -s "$XRAY_CONF" ]; then
    log "config download failed"
    rm -f "$SUB_FILE"
    sleep 15
    continue
  fi

  /etc/init.d/xray enable
  /etc/init.d/xray restart
  log "xray restarted"

  sleep 60
done
