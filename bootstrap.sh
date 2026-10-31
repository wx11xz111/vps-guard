#!/usr/bin/env bash
# Download a fixed, checksummed version before installing VPS Guard.
set -euo pipefail
umask 077
[[ $# == 0 || ($# == 1 && $1 == --check) ]] || { echo '用法: bootstrap.sh [--check]' >&2; exit 1; }
for tool in curl sha256sum mktemp; do command -v "$tool" >/dev/null || { echo "缺少依赖: $tool" >&2; exit 1; }; done
stage=$(mktemp -d "${TMPDIR:-/tmp}/vpsguard.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
base='https://raw.githubusercontent.com/wx11xz111/vps-guard/2c076805bcf6a3655a8efb6b92f63b4ce6974fc5'
for file in server-guard.sh backends.sh selinux.sh install.sh; do
 curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 120 --output "$stage/$file" "$base/$file"
done
(cd "$stage" && sha256sum --check --status <<'SUMS'
a242fc95b2cdf8ed10b9394278f06e1d97cb071b0d81537f8b190884d85d0ccf  server-guard.sh
2f5f82d33124bbaf19a21da6da13bd855e6c507d5644f82d784ae38d6e137474  backends.sh
873f5ba3b6c1a5d06a9bb0e8580ad7489225bc8c8e39b98fecd162b1ddddbe3d  selinux.sh
322d9662534974d951dd84ee61bc8752b6337f32747f136f12967245e88c192f  install.sh
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
