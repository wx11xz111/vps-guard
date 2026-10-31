#!/usr/bin/env bash
# Download a fixed, checksummed version before installing VPS Guard.
set -euo pipefail
umask 077
[[ $# == 0 || ($# == 1 && $1 == --check) ]] || { echo '用法: bootstrap.sh [--check]' >&2; exit 1; }
for tool in curl sha256sum mktemp; do command -v "$tool" >/dev/null || { echo "缺少依赖: $tool" >&2; exit 1; }; done
stage=$(mktemp -d "${TMPDIR:-/tmp}/vpsguard.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
base='https://raw.githubusercontent.com/wx11xz111/vps-guard/f9e3b6e171d1880c4207c57aaaa7ceffc2e81368'
for file in server-guard.sh backends.sh selinux.sh install.sh; do
 curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 120 --output "$stage/$file" "$base/$file"
done
(cd "$stage" && sha256sum --check --status <<'SUMS'
5379e3ef6ad1fff9c484a77e6a8a84206c5175517143794dc6210ee4f9b9eb50  server-guard.sh
9289a98f174560ebb637e1cd1f5ad039183af6e97364c402d11626bb6a6b1ce7  backends.sh
873f5ba3b6c1a5d06a9bb0e8580ad7489225bc8c8e39b98fecd162b1ddddbe3d  selinux.sh
e04dbdbcdaf141d68cdfdbf56ff112462f3284e7d1af9bcef61a4b8362fc2218  install.sh
SUMS
) || { echo '下载文件校验失败，已停止安装' >&2; exit 1; }
echo '加固脚本校验通过。'
[[ ${1:-} != --check ]] || exit 0
[[ -t 0 && -e /dev/tty ]] || { echo '请在 SSH 交互终端运行。' >&2; exit 1; }
if [[ $(id -u) == 0 ]]; then
 bash "$stage/install.sh" --launch < /dev/tty
else
 command -v sudo >/dev/null || { echo '需要 sudo 或 root' >&2; exit 1; }
 sudo --preserve-env=SSH_CONNECTION,NO_COLOR bash "$stage/install.sh" --launch < /dev/tty
fi
