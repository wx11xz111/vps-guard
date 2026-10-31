#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
FETCH=$HERE/../fetch.sh
[[ -f $FETCH ]] || { echo 'FAIL: verified standalone bundle fetch entry point missing'; exit 1; }
: "${TMPDIR:?isolated TMPDIR required}"
work=$(mktemp -d "$TMPDIR/guard-package.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/server-guard"
cp "$HERE/../server-guard.sh" "$HERE/../backends.sh" "$HERE/../selinux.sh" "$FETCH" "$work/server-guard/"
tar -C "$work" -czf "$work/good.tar.gz" server-guard
sum=$(sha256sum "$work/good.tar.gz"); sum=${sum%% *}
bash "$FETCH" --archive "$work/good.tar.gz" --sha256 "$sum" --output "$work/delivery" >/dev/null
cmp "$work/server-guard/server-guard.sh" "$work/delivery/server-guard.sh"
cmp "$work/server-guard/selinux.sh" "$work/delivery/selinux.sh"
[[ $(stat -c %a "$work/delivery") == 700 ]]
if bash "$FETCH" --archive "$work/good.tar.gz" --sha256 "$sum" --output "$work/delivery" >/dev/null 2>&1; then echo 'FAIL: existing output overwritten'; exit 1; fi
if bash "$FETCH" --archive "$work/good.tar.gz" --sha256 "${sum//?/0}" --output "$work/bad" >/dev/null 2>&1; then echo 'FAIL: checksum mismatch accepted'; exit 1; fi
[[ ! -e $work/bad ]]
mv "$work/server-guard/selinux.sh" "$work/selinux.saved"
tar -C "$work" -czf "$work/incomplete.tar.gz" server-guard
mv "$work/selinux.saved" "$work/server-guard/selinux.sh"
incomplete_sum=$(sha256sum "$work/incomplete.tar.gz"); incomplete_sum=${incomplete_sum%% *}
if bash "$FETCH" --archive "$work/incomplete.tar.gz" --sha256 "$incomplete_sum" --output "$work/incomplete" >/dev/null 2>&1; then echo 'FAIL: missing SELinux module accepted'; exit 1; fi
[[ ! -e $work/incomplete ]]
ln -s /etc/passwd "$work/server-guard/escape"
tar -C "$work" -czf "$work/link.tar.gz" server-guard
sum=$(sha256sum "$work/link.tar.gz"); sum=${sum%% *}
if bash "$FETCH" --archive "$work/link.tar.gz" --sha256 "$sum" --output "$work/link" >/dev/null 2>&1; then echo 'FAIL: linked bundle accepted'; exit 1; fi
[[ ! -e $work/link ]]
if bash "$FETCH" --repo '../bad' --version main --sha256 "$sum" --output "$work/remote" >/dev/null 2>&1; then echo 'FAIL: unsafe repo accepted'; exit 1; fi
echo 'PASS: offline bundle digest, extraction boundary, no overwrite and no auto-execution'
