#!/usr/bin/env bash
# Download a fixed, checksummed version before installing VPS Guard.
set -euo pipefail
umask 077
[[ $# == 0 || ($# == 1 && $1 == --check) ]] || { echo '用法: bootstrap.sh [--check]' >&2; exit 1; }
for tool in curl sha256sum mktemp; do command -v "$tool" >/dev/null || { echo "缺少依赖: $tool" >&2; exit 1; }; done
stage=$(mktemp -d "${TMPDIR:-/tmp}/vpsguard.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
base='https://raw.githubusercontent.com/wx11xz111/vps-guard/e44bd9037335d2705f837a42e202511a9eb73bb9'
for file in server-guard.sh backends.sh selinux.sh install.sh; do
 curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 120 --output "$stage/$file" "$base/$file"
done
(cd "$stage" && sha256sum --check --status <<'SUMS'
ef71caa04e1c9201dce8661c87b798cfe24181baf7d649e7cd24e2abbc07e675  server-guard.sh
6d9ead6998e56b3ea9fa81fc8b28d63dab4189054868ad6a9ab87c5e6b042b6b  backends.sh
ffe32b8690fda6ef515555de35d7c0ed33622af0d1cc17e518b7e13969cb8195  selinux.sh
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
