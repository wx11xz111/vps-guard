#!/usr/bin/env bash
# Fetch/extract ONLY. Never execute downloaded content or install packages.
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
umask 077
archive='' checksum='' repo='' version='' output='' stage=''
die() { printf 'ERROR / 错误: %s\n' "$*" >&2; exit 1; }
while (($#)); do
 (($# >= 2)) || die 'missing option value'
 case $1 in
  --archive) archive=$2;; --sha256) checksum=$2;; --repo) repo=$2;; --version) version=$2;; --output) output=$2;;
  *) die 'use --archive or --repo/--version, plus --sha256 and --output';;
 esac
 shift 2
done
[[ $checksum =~ ^[a-fA-F0-9]{64}$ ]] || die 'expected SHA256 must come from a trusted channel / 需提供可信SHA256'
[[ -n $output && ! -e $output && ! -L $output ]] || die 'output must be a NEW directory'
if [[ -n $archive ]]; then
 [[ -z $repo && -z $version && -f $archive && ! -L $archive ]] || die 'invalid offline archive or mixed download arguments'
 archive=$(realpath -e -- "$archive")
else
 [[ $repo =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die 'repo must be owner/name'
 [[ $repo != *..* && $version =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$ ]] || die 'invalid fixed release version'
 case ${version,,} in latest|main|master|head) die 'a fixed release version is required';; esac
 command -v curl >/dev/null || die 'curl is required; install explicitly'
fi
parent=$(realpath -e -- "$(dirname -- "$output")")
name=$(basename -- "$output")
[[ $name != . && $name != .. && $name != *$'\n'* ]] || die 'unsafe output path'
output=$parent/$name
[[ ! -e $output && ! -L $output ]] || die 'output exists'
stage=$(mktemp -d "$parent/.server-guard-fetch.XXXXXXXX")
trap '[[ -z $stage || $stage != "$parent"/.server-guard-fetch.* ]] || rm -rf -- "$stage"' EXIT
if [[ -z $archive ]]; then
 archive=$stage/server-guard.tar.gz
 curl --fail --location --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 180 \
  --output "$archive" "https://github.com/$repo/releases/download/$version/server-guard.tar.gz"
fi
[[ $(stat -c %s "$archive") -le 10485760 ]] || die 'bundle too large'
printf '%s  %s\n' "$checksum" "$archive" | sha256sum --check --status || die 'SHA256 mismatch / 校验失败'
tar -tzf "$archive" > "$stage/members"
while IFS= read -r member; do
 case $member in server-guard/|server-guard/server-guard.sh|server-guard/backends.sh|server-guard/selinux.sh|server-guard/fetch.sh|server-guard/SERVER_GUARD.md) :;; *) die 'unexpected archive member / 包含非预期文件';; esac
done < "$stage/members"
[[ $(sort "$stage/members" | uniq -d | wc -l) == 0 ]] || die 'duplicate archive member'
tar -tvzf "$archive" > "$stage/types"
awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {exit 1} {size+=$3} END {if(size>10485760)exit 1}' "$stage/types" || die 'links/devices/oversized contents refused'
tar -xzf "$archive" -C "$stage" --no-same-owner --no-same-permissions
for file in server-guard.sh backends.sh selinux.sh fetch.sh; do
 [[ -f $stage/server-guard/$file && ! -L $stage/server-guard/$file ]] || die 'incomplete bundle'
 bash -n "$stage/server-guard/$file" || die 'invalid Bash syntax in bundle'
done
chmod 700 "$stage/server-guard"
find "$stage/server-guard" -type f -exec chmod 600 {} +
[[ ! -e $output && ! -L $output ]] || die 'output appeared during fetch'
mv -T -- "$stage/server-guard" "$output"
printf 'Verified bundle / 已校验工具包: %s\nReview it before running; no downloaded code has been executed. / 请审阅后再运行，尚未执行下载代码。\n' "$output"
