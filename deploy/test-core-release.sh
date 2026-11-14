#!/bin/sh
# Hermetic core upgrade, checksum failure, boot-cache and rollback regression.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
d=$(mktemp -d /tmp/shpun-core-fixture.XXXXXX)
trap 'rm -rf "$d"' EXIT
mkdir "$d/bin"
cat > "$d/good" <<'CORE'
#!/bin/sh
exit 0
CORE
cat > "$d/old" <<'CORE'
#!/bin/sh
echo original
CORE
chmod +x "$d/good" "$d/old"
expected=$(sha256sum "$d/good" | cut -d' ' -f1)
export CORE_FIXTURE="$d"
cat > "$d/bin/curl" <<'MOCK'
#!/bin/sh
printf 'called\n' >> "$CORE_FIXTURE/downloads"
case "$CORE_DOWNLOAD_MODE" in fail) exit 28;; corrupt) printf invalid > "$CORE_FIXTURE/candidate-source";; *) cp "$CORE_FIXTURE/good" "$CORE_FIXTURE/candidate-source";; esac
while [ "$#" -gt 0 ]; do
 if [ "$1" = -o ]; then cp "$CORE_FIXTURE/candidate-source" "$2"; exit; fi
 shift
done
exit 2
MOCK
cat > "$d/bin/logger" <<'MOCK'
#!/bin/sh
exit 0
MOCK
cat > "$d/bin/pidof" <<'MOCK'
#!/bin/sh
test "$CORE_RUNNING" = 1 || exit 1
echo 123
MOCK
cat > "$d/bin/df" <<'MOCK'
#!/bin/sh
printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\nfixture 100000 1 99999 1%% /\n'
MOCK
chmod +x "$d/bin/"*
export PATH="$d/bin:$PATH"
export CORE_DOWNLOAD_MODE=good CORE_RUNNING=0
printf '%s  xray-aarch64\n' "$expected" > "$d/manifest"
sed -e "s|target=/tmp/xray|target=$d/target|" \
 -e "s|state=/tmp/shpun-core-release|state=$d/state|" \
 -e "s|cache=/etc/shpun/core-release|cache=$d/cache|" \
 -e "s|manifest=/usr/share/shpun/core-release.sha256|manifest=$d/manifest|" \
 -e "s|/tmp/shpun-core-candidate.XXXXXX|$d/candidate.XXXXXX|g" \
 -e "s|/etc/shpun/xray.json|$d/live-config|g" \
 -e "s|df -k /etc/shpun|df -k $d|g" \
 -e 's|"/proc/$p/exe"|"$CORE_FIXTURE/running"|' \
 -e "s|/etc/init.d/shpun-xray-udp-seed|$d/old-seed|g" \
 "$repo/package/shpun-router/files/etc/shpun/core-release.sh" > "$d/helper"
cp "$d/old" "$d/target"
CORE_DOWNLOAD_MODE=corrupt sh "$d/helper" prepare aarch64 && exit 1
cmp -s "$d/target" "$d/old"
test ! -e "$d/state/pending"
rm "$d/state/failed"
CORE_DOWNLOAD_MODE=fail sh "$d/helper" prepare aarch64 && exit 1
cmp -s "$d/target" "$d/old"
rm "$d/state/failed"
sh "$d/helper" prepare aarch64
cmp -s "$d/target" "$d/good"
cmp -s "$d/state/previous" "$d/old"
test -e "$d/state/pending"
sh "$d/helper" rollback
cmp -s "$d/target" "$d/old"
test ! -e "$d/state/pending"
before=$(wc -l < "$d/downloads")
sh "$d/helper" prepare aarch64 && exit 1
test "$(wc -l < "$d/downloads")" = "$before"
rm "$d/state/failed"
sh "$d/helper" prepare aarch64
cp "$d/good" "$d/running"
CORE_RUNNING=1 sh "$d/helper" confirm
test ! -e "$d/state/pending"
test ! -e "$d/state/previous"
test -f "$d/cache/xray.gz"
rm "$d/target"
sh "$d/helper" seed
cmp -s "$d/target" "$d/good"
test "$(wc -l < "$d/downloads")" -gt "$before"
count=$(wc -l < "$d/downloads")
sh "$d/helper" prepare aarch64
test "$(wc -l < "$d/downloads")" = "$count"
mkdir "$d/state/lock"
echo $$ > "$d/state/lock/pid"
sh "$d/helper" prepare aarch64 && exit 1
cmp -s "$d/target" "$d/good"
rm "$d/state/lock/pid"
rmdir "$d/state/lock"
echo PASS core-checksum-rollback-cooldown-lock-and-offline-boot-cache

