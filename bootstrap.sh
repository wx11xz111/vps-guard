#!/usr/bin/env bash
# Download a fixed, checksummed version before installing VPS Guard.
set -euo pipefail
umask 077
[[ $# == 0 || ($# == 1 && $1 == --check) ]] || { echo '用法: bootstrap.sh [--check]' >&2; exit 1; }
for tool in curl sha256sum mktemp; do command -v "$tool" >/dev/null || { echo "缺少依赖: $tool" >&2; exit 1; }; done
stage=$(mktemp -d "${TMPDIR:-/tmp}/vpsguard.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
base='https://raw.githubusercontent.com/wx11xz111/vps-guard/edc6aaf2a2a8745f8a76edad4f2ed0bd919d1e3f'
for file in server-guard.sh backends.sh selinux.sh install.sh; do
 curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 120 --output "$stage/$file" "$base/$file"
done
(cd "$stage" && sha256sum --check --status <<'SUMS'
9a3b69d1b1c21db10be7ff3d55807abc60c0e9d6a0fbbbbc6d00a8706e2fa67f  server-guard.sh
e776eef3978aee472ba4486980ed4dd6cc740c3aaea723c15cc99196dd95f8cf  backends.sh
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
