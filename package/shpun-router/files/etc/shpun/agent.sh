#!/bin/sh
# shpun-agent — получает subscription_url и поднимает VPN (xray или xray-lite)
set -eu

STATE_DIR="/etc/shpun"
CODE_FILE="$STATE_DIR/router_code"
SUB_FILE="$STATE_DIR/subscription_url"
VPN_READY_FILE="$STATE_DIR/vpn_ready"

CONF="$STATE_DIR/agent.conf"
getvar(){ awk -F= -v k="$1" '$1==k{val=$2} END{gsub(/^[ \t"]+|[ \t"]+$/,"",val); print val}' "$CONF" 2>/dev/null; }

XRAY_CONF="$(getvar XRAY_CONF)"; [ -n "$XRAY_CONF" ] || XRAY_CONF="/etc/xray/config.json"
XRAY_INIT="$(getvar XRAY_INIT)"; [ -n "$XRAY_INIT" ] || XRAY_INIT="/etc/init.d/xray"
XRAY_LITE_INIT="$(getvar XRAY_LITE_INIT)"; [ -n "$XRAY_LITE_INIT" ] || XRAY_LITE_INIT="/etc/init.d/xray-lite"
XRAY_BIN="/usr/bin/xray"

API_URL="https://bill.shpyn.online/shm/v1/public/router_public"

POLL_BASE=30; POLL_MAX=$((10*60)); POLL_JIT=15
OK_INTERVAL=$((6*60*60)); OK_JIT_MIN=$((10*60)); OK_JIT_MAX=$((30*60))
FAIL_INTERVAL=60

LOCK="/var/run/shpun-agent.lock"
log(){ logger -t shpun-agent "$*"; }
cleanup(){ rm -f "$LOCK"; exit 0; }; trap cleanup INT TERM
lock(){ if [ -e "$LOCK" ]; then old="$(cat "$LOCK" 2>/dev/null || echo 0)"; kill -0 "$old" 2>/dev/null && exit 0; fi; echo $$ >"$LOCK"; }

need(){ command -v "$1" >/dev/null 2>&1 || { log "missing $1"; exit 1; }; }
http_get(){ uclient-fetch -qO- -T 20 "$1"; }
http_fetch(){ uclient-fetch -qO "$2" -T 30 "$1"; }
http_ok(){ uclient-fetch -qO /dev/null -T 15 "$1" >/dev/null 2>&1; }

ensure(){
  need uclient-fetch; need od; need sed; mkdir -p "$STATE_DIR"
  [ -x /etc/shpun/gen_code.sh ] || { log "gen_code.sh missing"; exit 1; }
}

get_code(){
  [ -s "$CODE_FILE" ] || /etc/shpun/gen_code.sh >/dev/null 2>&1 || { log "code gen failed"; return 1; }
  cat "$CODE_FILE"
}

json_ok(){ echo "$1" | sed -n 's/.*"ok":[ ]*\([0-9]\+\).*/\1/p'; }
json_sub(){ echo "$1" | sed -n 's/.*"subscription_url":"\([^"]*\)".*/\1/p'; }

dl_conf(){
  url="$1"; tmp="$XRAY_CONF.tmp"
  http_fetch "$url" "$tmp" || { rm -f "$tmp"; return 1; }
  [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
  mkdir -p "$(dirname "$XRAY_CONF")"
  if [ -f "$XRAY_CONF" ] && cmp -s "$tmp" "$XRAY_CONF"; then rm -f "$tmp"; return 0; fi
  mv "$tmp" "$XRAY_CONF"; return 2
}

svc_status(){
  if [ -x "$XRAY_INIT" ]; then "$XRAY_INIT" status 2>/dev/null | grep -qi running && return 0; fi
  if [ -x "$XRAY_LITE_INIT" ]; then "$XRAY_LITE_INIT" status 2>/dev/null | grep -qi running && return 0; fi
  return 1
}

svc_restart(){
  if [ -x "$XRAY_INIT" ]; then "$XRAY_INIT" enable >/dev/null 2>&1 || true; "$XRAY_INIT" restart >/dev/null 2>&1 || true; return 0; fi
  if [ -x "$XRAY_LITE_INIT" ]; then "$XRAY_LITE_INIT" enable >/dev/null 2>&1 || true; "$XRAY_LITE_INIT" restart >/dev/null 2>&1 || true; return 0; fi
  return 1
}

xray_test(){
  [ -x "$XRAY_BIN" ] || return 0
  "$XRAY_BIN" -test -config "$XRAY_CONF" >/dev/null 2>&1
}

wait_running(){
  i=0; while [ $i -lt 15 ]; do svc_status && return 0; sleep 1; i=$((i+1)); done; return 1
}

mark_ready(){
  if wait_running; then echo 1 >"$VPN_READY_FILE"; log "vpn_ready=1"; else rm -f "$VPN_READY_FILE"; log "vpn still not running"; fi
}

randu(){ dd if=/dev/urandom bs=2 count=1 2>/dev/null | od -An -tu2 | tr -d ' '; }
randr(){ min="$1"; max="$2"; span=$((max-min+1)); n="$(randu)"; echo $(( min + (n % span) )); }

main(){
  backoff=$POLL_BASE
  while :; do
    if [ ! -s "$SUB_FILE" ]; then
      CODE="$(get_code || true)"; [ -z "$CODE" ] && { sleep "$POLL_BASE"; continue; }
      JSON="$(http_get "$API_URL?code=$CODE&format=json" || true)"
      [ "$(json_ok "$JSON")" = "1" ] && SUB="$(json_sub "$JSON" || true)" || SUB=""
      if [ -n "$SUB" ]; then
        echo "$SUB" >"$SUB_FILE"; log "got subscription_url"
        changed=0; if dl_conf "$SUB"; then :; else rc=$?; [ "$rc" -eq 2 ] && changed=1; fi
        if [ "$changed" -eq 1 ]; then
          xray_test || true
          svc_restart || true
          mark_ready
        else
          mark_ready
        fi
        backoff=$POLL_BASE
      fi
      if [ ! -s "$SUB_FILE" ]; then
        max=$((backoff + backoff * POLL_JIT / 100)); sleep "$(randr "$backoff" "$max")"
        backoff=$(( backoff + backoff/2 )); [ "$backoff" -gt "$POLL_MAX" ] && backoff="$POLL_MAX"
        continue
      fi
    fi

    SUB_URL="$(cat "$SUB_FILE" 2>/dev/null || true)"; [ -z "$SUB_URL" ] && { rm -f "$SUB_FILE"; sleep "$POLL_BASE"; continue; }

    if http_ok "$SUB_URL"; then
      if [ ! -s "$XRAY_CONF" ]; then
        changed=0; if dl_conf "$SUB_URL"; then :; else rc=$?; [ "$rc" -eq 2 ] && changed=1; fi
        [ "$changed" -eq 1 ] && { xray_test || true; svc_restart || true; }
      fi
      mark_ready
      off="$(randr "$OK_JIT_MIN" "$OK_JIT_MAX")"; [ "$(randr 0 1)" -eq 0 ] && off=$((-off))
      t=$(( OK_INTERVAL + off )); [ "$t" -lt 60 ] && t=60; sleep "$t"
    else
      log "subscription invalid -> reset"
      rm -f "$VPN_READY_FILE" "$SUB_FILE"
      [ -x "$XRAY_INIT" ] && "$XRAY_INIT" stop >/dev/null 2>&1 || true
      [ -x "$XRAY_LITE_INIT" ] && "$XRAY_LITE_INIT" stop >/dev/null 2>&1 || true
      sleep "$FAIL_INTERVAL"
    fi
  done
}

lock; ensure; log "shpun-agent started"; main
