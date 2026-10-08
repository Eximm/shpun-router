#!/bin/sh
set -eu
d="$1"
for v in ${TEST_VARIANTS:-24 25}; do
 awk '/^function (norm|cleanup_server_name|link_value|parse_link_info|host_is_rush_gateway|server_group)\(/ { emit=1 } emit { print } emit && /^}/ { emit=0 }' "$d/rpc-$v.uc" > "$d/rpc-fixture.uc"
 cat "$d/rpc-assertions.uc" >> "$d/rpc-fixture.uc"
 ucode "$d/rpc-fixture.uc"
 echo "PASS version=$v RPC URI host/default-port/IPv6/aliases/groups"
done
