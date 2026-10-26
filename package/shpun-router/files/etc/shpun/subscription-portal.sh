#!/bin/sh
# Own, LAN-only captive state. No TLS interception or subscriber data in responses.
set -eu
umask 077
S=/tmp/shpun-subscription-portal
ROOT=/etc/shpun
[ ! -L "$S" ] || exit 1
mkdir -p "$S";[ "$(readlink -f "$S")" = "$S" ] || exit 1;chmod 700 "$S"
binding(){ cat "$ROOT/router_code" "$ROOT/subscription_url" 2>/dev/null | sha256sum | cut -d' ' -f1; }
random(){ head -c32 /dev/urandom | sha256sum | cut -c1-32; }
http_stop(){
 if [ -s "$S/http.pid" ];then p=$(cat "$S/http.pid");case "$p" in ''|*[!0-9]*)return;;esac
  if [ -r "/proc/$p/cmdline" ] && tr '\000' ' ' < "/proc/$p/cmdline" | grep -F '/usr/share/shpun/portal' >/dev/null;then kill "$p" 2>/dev/null || true;fi
 fi
 rm -f "$S/http.pid"
}
rules_clear(){
 if [ -f "$S/nft-owned" ] && nft list table inet shpun_subscription_portal >/dev/null 2>&1;then nft delete table inet shpun_subscription_portal || return 1;fi
 rm -f "$S/nft-owned"
}
release(){
 rules_clear;http_stop
 if [ -f "$S/dns.json" ];then ucode "$ROOT/subscription-portal-dns.uc" "$S/dns.json" restore;/etc/init.d/dnsmasq reload;fi
 rm -f "$S/blocked" "$S/ack" "$S/profile" "$S/generation" "$S/token" "$S/network-held"
 [ ! -x /etc/init.d/shpun-dns-policy ] || /etc/init.d/shpun-dns-policy start
}
locked=0
unlock(){ [ "$locked" = 0 ] || { rm -f "$S/lock/pid";rmdir "$S/lock" 2>/dev/null || true; }; }
lock(){
 if [ -s "$S/lock/pid" ];then p=$(cat "$S/lock/pid");case "$p" in ''|*[!0-9]*)exit 1;;esac
  kill -0 "$p" 2>/dev/null || { rm -f "$S/lock/pid";rmdir "$S/lock" 2>/dev/null || true; }
 fi
 i=0;until mkdir "$S/lock" 2>/dev/null;do i=$((i+1));[ "$i" -le 5 ] || exit 1;sleep 1;done
 echo $$ > "$S/lock/pid";locked=1;trap unlock EXIT;trap 'exit 130' HUP INT TERM
}
case "${1:-reconcile}" in
 blocked) [ -s "$S/blocked" ];exit $?;;
 confirm)
  lock
  [ -s "$S/generation" ] && [ "${2:-}" = "$(cat "$S/generation")" ] || exit 1
  ucode -e 'import{readfile}from"fs";let n=json(readfile("/tmp/shpun-subscription-notice/state.json")),t=clock()[0];if(n.source_available!=true||n.status!="active"||t<n.checked_at||t-n.checked_at>600)exit(1);'
  printf '%s' "$2" > "$S/profile";exit 0;;
 ack|continue)
  lock
  [ -s "$S/generation" ] && [ -s "$S/token" ] || exit 1
  if [ "$1" = continue ];then token=$(cat "$S/token");else token=$(head -c32);fi
  [ "$token" = "$(cat "$S/token")" ] || exit 1
  cp "$S/generation" "$S/ack"
  rules_clear
  # The VPN remains fenced off until fresh HEAD plus authoritative profile ok=1.
  exit 0;;
 stop) lock;release;rm -f "$S/state.json";exit 0;;
 reconcile) lock;;
 *) exit 2;;
esac
bind=$(binding);gen=$(random)
SHPUN_PORTAL_BINDING=$bind SHPUN_PORTAL_GENERATION=$gen ucode -e 'import{readfile}from"fs";let r="/tmp/shpun-subscription-portal/";function load(p){try{return json(readfile(p));}catch(e){return {};}}print(sprintf("%J",{now:int(clock()[0]),binding:getenv("SHPUN_PORTAL_BINDING"),generation:getenv("SHPUN_PORTAL_GENERATION"),notice:load("/tmp/shpun-subscription-notice/state.json"),previous:load(r+"state.json"),ack:trim(readfile(r+"ack")||""),profile:trim(readfile(r+"profile")||"")}));' | ucode "$ROOT/subscription-portal-state.uc" > "$S/next"
phase=$(jsonfilter -i "$S/next" -e '@.phase')
if [ "$phase" = idle ];then
 [ ! -e "$S/blocked" ] || release
 mv "$S/next" "$S/state.json";exit 0
fi
nextgen=$(jsonfilter -i "$S/next" -e '@.generation')
if [ ! -s "$S/generation" ] || [ "$(cat "$S/generation")" != "$nextgen" ];then
 echo "$nextgen" > "$S/generation";random > "$S/token";rm -f "$S/ack" "$S/profile"
fi
# Fence agent/init before touching its routes or process.
cp "$S/generation" "$S/blocked"
if [ ! -e "$S/network-held" ];then
 [ ! -x /etc/init.d/shpun-dns-policy ] || /etc/init.d/shpun-dns-policy stop
 /etc/init.d/shpun-vpn stop
 rm -f "$ROOT/vpn_ready" "$ROOT/udp_ready" "$ROOT/xray_config_active"
 echo subscription_expired > "$ROOT/vpn_error"
 "$ROOT/firewall-xray.sh" stop
 "$ROOT/dns-xray.sh" clear
 ucode "$ROOT/subscription-portal-dns.uc" "$S/dns.json" apply
 /etc/init.d/dnsmasq reload
 touch "$S/network-held"
fi
mv "$S/next" "$S/state.json"
if [ "$phase" != captive ];then rules_clear;exit 0;fi
lanif=$(uci -q get network.lan.device || uci -q get network.lan.ifname || echo br-lan)
lanip=$(ubus call network.interface.lan status | jsonfilter -e '@["ipv4-address"][0].address')
case "$lanif" in ''|*[!a-zA-Z0-9_.:-]*)exit 1;;esac
ucode -e 'if(!match(ARGV[0]||"",/^([0-9]{1,3}\.){3}[0-9]{1,3}$/))exit(1);for(let n in split(ARGV[0],"."))if(int(n)>255)exit(1);' "$lanip"
mask=$(ubus call network.interface.lan status | jsonfilter -e '@["ipv4-address"][0].mask')
case "$mask" in ''|*[!0-9]*)exit 1;;esac
[ "$mask" -ge 1 ] && [ "$mask" -le 32 ]
echo "$lanip/$mask" > "$S/network"
echo "$lanip:2080" > "$S/authority"
if [ ! -s "$S/http.pid" ] || ! kill -0 "$(cat "$S/http.pid")" 2>/dev/null;then
 start-stop-daemon -S -b -m -p "$S/http.pid" -x /usr/sbin/uhttpd -- -f -c /dev/null -p "$lanip:2080" -h /usr/share/shpun/portal -x /cgi-bin -E /cgi-bin/index -t 10 -T 10 -k 0
fi
if nft list table inet shpun_subscription_portal >/dev/null 2>&1;then
 [ -e "$S/nft-owned" ] || exit 1
 exit 0
fi
nft -f - <<RULES
add table inet shpun_subscription_portal
add chain inet shpun_subscription_portal captive_nat { type nat hook prerouting priority -101; policy accept; }
add rule inet shpun_subscription_portal captive_nat iifname "$lanif" fib daddr type local return
add rule inet shpun_subscription_portal captive_nat iifname "$lanif" ip protocol tcp tcp dport 80 redirect to :2080
add chain inet shpun_subscription_portal forward { type filter hook forward priority -190; policy accept; }
add rule inet shpun_subscription_portal forward iifname "$lanif" udp dport { 53, 123 } accept
add rule inet shpun_subscription_portal forward iifname "$lanif" tcp dport 53 accept
add rule inet shpun_subscription_portal forward iifname "$lanif" reject with icmpx type admin-prohibited
add chain inet shpun_subscription_portal input { type filter hook input priority -190; policy accept; }
add rule inet shpun_subscription_portal input iifname != "$lanif" tcp dport 2080 drop
RULES
touch "$S/nft-owned"