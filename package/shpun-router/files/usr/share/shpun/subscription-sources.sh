#!/bin/sh
# URL-only migration library. Never source agent.conf or touch the live tunnel.
sub_atomic_write() {
 local target="$1" value="$2" tmp
 tmp=$(mktemp "${target}.tmp.XXXXXX") || return 1
 chmod 600 "$tmp"
 if printf '%s\n' "$value" > "$tmp" && mv -f "$tmp" "$target"; then return 0; fi
 rm -f "$tmp"; return 1
}
sub_canonical_url() {
 case "$1" in
  https://melori.site/*|http://melori.site/*|https://sub.melori.site/*|http://sub.melori.site/*)
   printf 'https://sub.netget.online/%s' "${1#*://*/}" ;;
  https://mirepo.space/*|http://mirepo.space/*)
   printf 'https://cdn.netget.online/%s' "${1#*://*/}" ;;
  *) printf '%s' "$1" ;;
 esac
}
sub_token() {
 local value="${1%%\?*}"
 value="${value%%\#*}"; value="${value%/}"
 printf '%s' "${value##*/}"
}
sub_legacy_eligible() {
 local old current
 [ -s "$1" ] && [ -s "$SUB_URL_FILE" ] || return 1
 old=$(cat "$1"); current=$(cat "$SUB_URL_FILE")
 [ "$(sub_canonical_url "$old")" != "$old" ] || return 1
 [ -n "$(sub_token "$old")" ] && [ "$(sub_token "$old")" = "$(sub_token "$current")" ]
}
sub_remember_legacy() {
 local old="$1" target="$2"
 [ "$(sub_canonical_url "$old")" != "$old" ] || return 0
 sub_atomic_write "$target" "$old"
}
sub_migrate_state() {
 local root="$1" name old new tmp conf
 for name in subscription_url subscription_mirror_url; do
  [ -s "$root/$name" ] || continue
  old=$(cat "$root/$name" | tr -d '\r\n')
  new=$(sub_canonical_url "$old")
  [ "$old" != "$new" ] || continue
  sub_remember_legacy "$old" "$root/${name}.legacy" || return 1
  sub_atomic_write "$root/$name" "$new" || return 1
 done
 conf="$root/agent.conf"
 if [ -f "$conf" ]; then
  # load_conf runs each loop: never create overlay temp files after migration.
  grep -Eq "^[[:space:]]*SUBSCRIPTION_MIRROR_BASE_URL=[\"']?https?://mirepo[.]space/?[\"']?[[:space:]]*$" "$conf" || return 0
  # Preserve all other admin settings; migrate only the exact known old base.
  tmp=$(mktemp "${conf}.tmp.XXXXXX") || return 1
  chmod 600 "$tmp"
  if awk 'BEGIN { q=sprintf("%c",39); dq=sprintf("%c",34) }
   /^[[:space:]]*SUBSCRIPTION_MIRROR_BASE_URL=/ {
    v=$0; sub(/^[^=]*=/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v);
    if ((substr(v,1,1)==dq && substr(v,length(v),1)==dq) ||
        (substr(v,1,1)==q && substr(v,length(v),1)==q)) v=substr(v,2,length(v)-2);
    if (v ~ /^https?:\/\/mirepo[.]space\/?$/) {
     print "SUBSCRIPTION_MIRROR_BASE_URL=" dq "https://cdn.netget.online" dq; next;
    }
   } { print }' "$conf" > "$tmp"; then
   if cmp -s "$conf" "$tmp"; then rm -f "$tmp"; else mv -f "$tmp" "$conf" || return 1; fi
  else rm -f "$tmp"; return 1; fi
 fi
}
sub_link_at() {
 local file="$1" idx="$2" base suffix value
 for base in "@.subscription.links[$idx]" "@.links[$idx]"; do
  for suffix in "" .url .link .uri .vless .hysteria2 .hy2; do
   value=$(jsonfilter -i "$file" -e "$base$suffix" 2>/dev/null | head -n 1)
   case "$value" in vless://*|hysteria2://*|hy2://*) printf '%s' "$value"; return 0 ;; esac
  done
 done
 return 1
}
sub_find_selected_index() {
 local old="$1" candidate="$2" selected="$3" current value idx=0
 current=$(sub_link_at "$old" "$selected") || return 1
 while [ "$idx" -lt 512 ]; do
  value=$(sub_link_at "$candidate" "$idx") || return 1
  [ "$value" != "$current" ] || { printf '%s' "$idx"; return 0; }
  idx=$((idx + 1))
 done
 return 1
}

