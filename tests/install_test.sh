#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
: "${TMPDIR:?isolated TMPDIR required}"
work=$(mktemp -d "$TMPDIR/guard-install-test.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
prefix=$work/prefix
bash "$HERE/../install.sh" --prefix "$prefix" > "$work/output"
for file in server-guard.sh backends.sh selinux.sh; do cmp "$HERE/../$file" "$prefix/lib/vpsmanager/server-guard/$file"; done
[[ -x $prefix/bin/vpsguard ]]
printf '0\n' | script -q -c "bash '$prefix/bin/vpsguard'" /dev/null > "$work/menu"
grep -q '服务器保护菜单' "$work/menu"
bash "$HERE/../install.sh" --prefix "$prefix" >/dev/null
rm "$prefix/lib/vpsmanager/server-guard/selinux.sh"
printf 'sentinel\n' > "$work/sentinel"
ln -s "$work/sentinel" "$prefix/lib/vpsmanager/server-guard/selinux.sh"
if bash "$HERE/../install.sh" --prefix "$prefix" > /dev/null 2>&1; then echo 'FAIL: followed installed symlink'; exit 1; fi
grep -qx sentinel "$work/sentinel"
mkdir -p "$work/foreign/bin"
printf 'foreign\n' > "$work/foreign/bin/vpsguard"
if bash "$HERE/../install.sh" --prefix "$work/foreign" > /dev/null 2>&1; then echo 'FAIL: overwrote foreign command'; exit 1; fi
grep -qx foreign "$work/foreign/bin/vpsguard"
echo 'PASS: install, Chinese launcher, repeat install and foreign command protection'
