#!/bin/sh
# Raise the file-descriptor limit before replacing the wrapper with Xray.
[ "$#" -ge 1 ] || exit 64
ENGINE_BIN="$1"
shift

[ -x "$ENGINE_BIN" ] || exit 127
ulimit -n 16384 2>/dev/null || true
exec "$ENGINE_BIN" "$@"
