#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")/.." && pwd)
: "${TMPDIR:?isolated TMPDIR required}"
work=$(mktemp -d "$TMPDIR/vpsguard-bootstrap-test.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/bin"
cat > "$work/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -eu
out=''
while (($#)); do case $1 in --output) out=$2; shift 2;; https://*) url=$1; shift;; *) shift;; esac; done
cp "$VPS_TEST_SOURCE/${url##*/}" "$out"
[[ ${VPS_TEST_CORRUPT:-0} != 1 || ${url##*/} != selinux.sh ]] || printf 'bad' >> "$out"
MOCK
chmod +x "$work/bin/curl"
export PATH="$work/bin:$PATH" VPS_TEST_SOURCE=$HERE
bash "$HERE/bootstrap.sh" --check > "$work/result"
grep -q '校验通过' "$work/result"
if VPS_TEST_CORRUPT=1 bash "$HERE/bootstrap.sh" --check >/dev/null 2>&1; then echo 'FAIL: corrupted download accepted'; exit 1; fi
echo 'PASS: pinned downloads checked; corruption rejected before install'
