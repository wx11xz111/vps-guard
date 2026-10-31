#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
: "${TMPDIR:?isolated TMPDIR required}"
work=$(mktemp -d "$TMPDIR/guard-install-test.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
prefix=$work/prefix
export GUARD_TEST_ROOT=$work/root GUARD_TEST_ADAPTER=$HERE/adapter.sh
mkdir -p "$GUARD_TEST_ROOT"
chmod 700 "$GUARD_TEST_ROOT"
printf 'server-guard-fixture-v1\n' > "$GUARD_TEST_ROOT/.server-guard-test"
bash "$HERE/../install.sh" --prefix "$prefix" > "$work/output"
for file in server-guard.sh backends.sh selinux.sh; do cmp "$HERE/../$file" "$prefix/lib/vpsmanager/server-guard/$file"; done
[[ -x $prefix/bin/vps-guard ]]
printf '0\n' | PATH="$prefix/bin:$PATH" script -q -c vps-guard /dev/null > "$work/menu"
grep -q '服务器保护菜单' "$work/menu"
printf '0\n' | script -q -c "bash '$HERE/../install.sh' --prefix '$prefix' --launch" /dev/null > "$work/launch"
grep -q '服务器保护菜单' "$work/launch"
bash "$HERE/../install.sh" --prefix "$prefix" >/dev/null
printf 'foreign\n' > "$prefix/bin/vpsguard"
bash "$HERE/../install.sh" --prefix "$prefix" >/dev/null
grep -qx foreign "$prefix/bin/vpsguard"
printf '#!/usr/bin/env bash\n# vpsmanager-server-guard-launcher-v1\nexec %q "$@"\n' "$prefix/lib/vpsmanager/server-guard/server-guard.sh" > "$prefix/bin/vpsguard"
bash "$HERE/../install.sh" --prefix "$prefix" >/dev/null
[[ ! -e $prefix/bin/vpsguard && -x $prefix/bin/vps-guard ]]
rm "$prefix/lib/vpsmanager/server-guard/selinux.sh"
printf 'sentinel\n' > "$work/sentinel"
ln -s "$work/sentinel" "$prefix/lib/vpsmanager/server-guard/selinux.sh"
if bash "$HERE/../install.sh" --prefix "$prefix" > /dev/null 2>&1; then echo 'FAIL: followed installed symlink'; exit 1; fi
grep -qx sentinel "$work/sentinel"
mkdir -p "$work/foreign/bin"
printf 'foreign\n' > "$work/foreign/bin/vps-guard"
if bash "$HERE/../install.sh" --prefix "$work/foreign" > /dev/null 2>&1; then echo 'FAIL: overwrote foreign command'; exit 1; fi
grep -qx foreign "$work/foreign/bin/vps-guard"
echo 'PASS: install, Chinese launcher, repeat install and foreign command protection'
