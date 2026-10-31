#!/usr/bin/env bash
# Install the standalone Server Guard files; never change system firewall or SSH settings.
set -euo pipefail
umask 022
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
prefix=/usr/local
launch=0
while (($#)); do
 case $1 in
  --prefix) (($# >= 2)) || { echo '缺少安装目录' >&2; exit 1; }; prefix=$2; shift 2;;
  --launch) launch=1; shift;;
  *) echo '用法: install.sh [--launch] [--prefix 绝对路径]' >&2; exit 1;;
 esac
done
[[ $(id -u) == 0 ]] || { echo '请使用 root 或 sudo 运行安装脚本' >&2; exit 1; }
[[ $prefix == /* && $prefix != / && $prefix != *$'\n'* ]] || { echo '安装目录必须是绝对路径' >&2; exit 1; }
prefix=${prefix%/}
target=$prefix/lib/vpsmanager/server-guard
launcher=$prefix/bin/vps-guard
for path in "$prefix" "$prefix/lib" "$prefix/lib/vpsmanager" "$target" "$prefix/bin" "$launcher"; do
 [[ ! -L $path && $(realpath -m -- "$path") == "$path" ]] || { echo "拒绝符号链接路径: $path" >&2; exit 1; }
done
if [[ -e $target && ! -f $target/.vpsmanager-guard ]]; then echo '目标目录不属于本工具，拒绝覆盖' >&2; exit 1; fi
if [[ -e $launcher ]] && ! { [[ -f $launcher ]] && sed -n '2p' "$launcher" | grep -qx '# vpsmanager-server-guard-launcher-v1'; }; then echo 'vps-guard 命令已存在，拒绝覆盖' >&2; exit 1; fi
for file in server-guard.sh backends.sh selinux.sh; do
 [[ -f $HERE/$file && ! -L $HERE/$file ]] || { echo "缺少脚本: $file" >&2; exit 1; }
 [[ ! -L $target/$file ]] || { echo "拒绝覆盖符号链接: $target/$file" >&2; exit 1; }
 bash -n "$HERE/$file"
done
[[ ! -L $target/.vpsmanager-guard ]] || { echo '拒绝符号链接标记文件' >&2; exit 1; }
install -d -m 755 "$target" "$prefix/bin"
printf '%s\n' 'vpsmanager-server-guard-v1' > "$target/.vpsmanager-guard"
for file in server-guard.sh backends.sh selinux.sh; do install -m 755 "$HERE/$file" "$target/$file"; done
printf '#!/bin/bash\n# vpsmanager-server-guard-launcher-v1\nexport PATH=/usr/sbin:/usr/bin:/sbin:/bin\nif [[ $(id -u) != 0 ]]; then exec sudo --preserve-env=SSH_CONNECTION /bin/bash %q "$@"; fi\nexec /bin/bash %q "$@"\n' "$target/server-guard.sh" "$target/server-guard.sh" > "$launcher"
chmod 755 "$launcher"
legacy=$prefix/bin/vpsguard
if [[ -f $legacy && ! -L $legacy ]] && cmp -s "$legacy" <(printf '#!/usr/bin/env bash\n# vpsmanager-server-guard-launcher-v1\nexec %q "$@"\n' "$target/server-guard.sh"); then rm -- "$legacy"; fi
printf '安装完成。运行 vps-guard 启动中文菜单（普通用户会提示 sudo 验证）。\n'
if ((launch)); then exec bash "$launcher"; fi
