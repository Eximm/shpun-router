#!/bin/sh
set -eu
mode=$(cat "$MOCK_STATE/scenario")
selected=$(cat "$MOCK_STATE/selected_link_index")
target=''
out=''
prev=''
for arg in "$@"; do
 [ "$prev" != '-o' ] || out="$arg"
 prev="$arg"
 target="$arg"
done
case "$mode" in
 all_fail|cancel) exit 1 ;;
 fallback) [ "$selected" = 1 ] || exit 1 ;;
 preferred) [ "$selected" = 2 ] || exit 1 ;;
 quality) case "$target" in *speed*) exit 1 ;; esac ;;
esac
if [ -n "$out" ] && [ "$out" != /dev/null ]; then head -c 8192 /dev/zero > "$out"; fi
exit 0
