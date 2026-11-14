#!/bin/sh
# Install a pinned core and retain the previous binary until procd starts it.
set -eu
umask 077
target=/tmp/xray
state=/tmp/shpun-core-release
cache=/etc/shpun/core-release
manifest=/usr/share/shpun/core-release.sha256
base=https://router.shpun.net/files/xray/releases/26.6.27-reply-close1
log() { logger -t shpun-core "$*"; }
hash() { sha256sum "$1" | cut -d' ' -f1; }
mkdir -p "$state"
if ! mkdir "$state/lock" 2>/dev/null; then
 owner="$(cat "$state/lock/pid" 2>/dev/null || true)"
 case "$owner" in ''|*[!0-9]*) exit 1;; esac
 kill -0 "$owner" 2>/dev/null && exit 1
 rm -f "$state/lock/pid"
 rmdir "$state/lock"
 mkdir "$state/lock"
fi
echo $$ > "$state/lock/pid"
candidate= stage=
cleanup() {
 [ -z "$candidate" ] || rm -f "$candidate"
 [ -z "$stage" ] || rm -f "$stage"
 rm -f "$state/lock/pid"
 rmdir "$state/lock" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP
case "$1" in
 seed)
  pidof xray >/dev/null 2>&1 && exit 0
  test -s "$cache/expected" && test -s "$cache/xray.gz" || exit 0
  expected="$(cat "$cache/expected")"
  awk -v hash="$expected" '$1==hash {found=1} END {exit !found}' "$manifest" || exit 1
  candidate="$(mktemp /tmp/shpun-core-candidate.XXXXXX)"
  gzip -dc "$cache/xray.gz" > "$candidate"
  test "$(hash "$candidate")" = "$expected"
  chmod 755 "$candidate"
  "$candidate" version >/dev/null 2>&1
  mv "$candidate" "$target"
  log "verified packaged core restored from local cache"
  ;;
 prepare)
  arch="$2"
  case "$arch" in aarch64|amd64|armv7|mips_24kc|mipsel_24kc) ;; *) exit 1;; esac
  expected="$(awk -v name="xray-$arch" '$2==name {print $1}' "$manifest")"
  printf '%s\n' "$expected" | grep -Eq '^[0-9a-f]{64}$'
  printf '%s\n' "$expected" > "$state/expected"
  if [ -x "$target" ] && [ "$(hash "$target")" = "$expected" ]; then exit 0; fi
  last="$(cat "$state/failed" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  case "$last" in ''|*[!0-9]*) last=0;; esac
  if [ "$last" -gt 0 ] && [ "$now" -ge "$last" ] && [ "$((now-last))" -lt 3600 ]; then exit 1; fi
  candidate="$(mktemp /tmp/shpun-core-candidate.XXXXXX)"
  loaded=0
  if [ -f "$cache/xray.gz" ]; then
   if gzip -dc "$cache/xray.gz" > "$candidate" && [ "$(hash "$candidate")" = "$expected" ]; then loaded=1; fi
  fi
  if [ "$loaded" = 0 ]; then
   if ! curl -q -fLsS --proto '=https' --noproxy '*' --connect-timeout 5 --max-time 90 \
     "$base/xray-$arch" -o "$candidate" >/dev/null 2>&1 ||
     [ "$(hash "$candidate")" != "$expected" ]; then
    date +%s > "$state/failed"
    log "core download failed verification; retaining installed binary"
    exit 1
   fi
  fi
  chmod 755 "$candidate"
  if ! "$candidate" version >/dev/null 2>&1; then
   date +%s > "$state/failed"
   exit 1
  fi
  if [ -s /etc/shpun/xray.json ] &&
    ! "$candidate" run -test -config /etc/shpun/xray.json >/dev/null 2>&1; then
   date +%s > "$state/failed"
   log "core rejected current configuration; retaining installed binary"
   exit 1
  fi
  if [ -e "$target" ] && [ ! -e "$state/previous" ]; then
   cp -p "$target" "$state/previous"
   hash "$state/previous" > "$state/previous.sha256"
  fi
  rm -f "$state/confirmed"
  touch "$state/pending"
  mv "$candidate" "$target"
  rm -f "$state/failed"
  log "verified core staged for architecture $arch"
  ;;
 confirm)
  test -s "$state/expected" || exit 0
  expected="$(cat "$state/expected")"
  p="$(pidof xray || true)"
  case "$p" in ''|*' '*) exit 1;; esac
  test "$(hash "/proc/$p/exe")" = "$expected"
  test "$(hash "$target")" = "$expected"
  if [ ! -e "$state/confirmed" ]; then
   free="$(df -k /etc/shpun | awk 'NR==2 {print $4}')"
   size="$(wc -c < "$target")"
   if [ "$free" -gt "$((size/1024 + 2048))" ]; then
    mkdir -p "$cache"
    stage="$(mktemp "$cache/.xray.XXXXXX")"
    if gzip -c "$target" > "$stage" && [ "$(gzip -dc "$stage" | sha256sum | cut -d' ' -f1)" = "$expected" ]; then
     mv "$stage" "$cache/xray.gz"
     cp "$state/expected" "$cache/expected"
     if [ -x /etc/init.d/shpun-xray-udp-seed ]; then
      /etc/init.d/shpun-xray-udp-seed disable
     fi
     log "core cache verified; legacy pilot seed disabled"
    else
     rm -f "$stage"
     log "core cache could not be written"
    fi
   else
    log "core cache skipped on small flash; verified network bootstrap retained"
   fi
   touch "$state/confirmed"
  fi
  rm -f "$state/pending" "$state/previous" "$state/previous.sha256"
  ;;
 rollback)
  if [ -f "$state/previous" ] && [ -f "$state/previous.sha256" ]; then
   test "$(hash "$state/previous")" = "$(cat "$state/previous.sha256")"
   mv "$state/previous" "$target"
  fi
  rm -f "$state/pending" "$state/previous.sha256" "$state/confirmed"
  date +%s > "$state/failed"
  log "restored previous core after startup failure"
  ;;
 *) exit 2;;
esac

