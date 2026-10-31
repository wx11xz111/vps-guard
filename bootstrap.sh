#!/usr/bin/env bash
# Download a fixed, checksummed version before installing VPS Guard.
set -euo pipefail
umask 077
[[ $# == 0 || ($# == 1 && $1 == --check) ]] || { echo '用法: bootstrap.sh [--check]' >&2; exit 1; }
for tool in curl sha256sum mktemp; do command -v "$tool" >/dev/null || { echo "缺少依赖: $tool" >&2; exit 1; }; done
stage=$(mktemp -d "${TMPDIR:-/tmp}/vpsguard.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
base='https://raw.githubusercontent.com/wx11xz111/vps-guard/c31a985e6a18f273ad76a686476355fa4065f9a5'
for file in server-guard.sh backends.sh selinux.sh install.sh; do
 curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 120 --output "$stage/$file" "$base/$file"
done
(cd "$stage" && sha256sum --check --status <<'SUMS'
09b8ae9b40866ee1182008a955a6b91c17a2b33513017fdcbb0c790ce1b3bfc8  server-guard.sh
05da44a0549249cb3dfc0461d93ec2e4314eed9dcf9a2aa4144459053346e9b9  backends.sh
873f5ba3b6c1a5d06a9bb0e8580ad7489225bc8c8e39b98fecd162b1ddddbe3d  selinux.sh
90f707f3127e455d952b0fd28db8c3ba573c8d738f4ddc51dd375367931ef256  install.sh
SUMS
) || { echo '下载文件校验失败，已停止安装' >&2; exit 1; }
echo '加固脚本校验通过。'
[[ ${1:-} != --check ]] || exit 0
[[ -t 0 && -e /dev/tty ]] || { echo '请在 SSH 交互终端运行。' >&2; exit 1; }
if [[ $(id -u) == 0 ]]; then
 bash "$stage/install.sh" --launch < /dev/tty
else
 command -v sudo >/dev/null || { echo '需要 sudo 或 root' >&2; exit 1; }
 sudo --preserve-env=SSH_CONNECTION bash "$stage/install.sh" --launch < /dev/tty
fi
