#!/usr/bin/env bash
# Independent SSH/firewall operations with backups. No panel dependency.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
umask 077
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
LANGUAGE=zh ROOT='' ADAPTER='' MODE=${1:-menu} ACTION='' PORT='' TO_PORT='' ID='' SCOPE=owned APPLY=0 DRY=0 BACKEND_REQUEST='' MENU_EXTRA=0
F2B_MAXRETRY='' F2B_FINDTIME='' F2B_BANTIME='' F2B_OPTIONS=0
F2B_INSTALL=0 TARGET_IP='' FW_OFFLINE=0 SSH_SOCKET='' SSH_SERVICE=''
[[ $# == 0 ]] || shift
ui_printf() {
 local tone=$1 color='' reset=''
 shift
 # Decide for the actual output stream, including stderr redirects.
 if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR:-} ]]; then
  case $tone in
   title|info) color=$'\033[1;36m';;
   section) color=$'\033[1;34m';;
   success) color=$'\033[1;32m';;
   warning) color=$'\033[1;33m';;
   error) color=$'\033[1;31m';;
   prompt) color=$'\033[1;35m';;
   muted) color=$'\033[90m';;
  esac
  [[ -z $color ]] || reset=$'\033[0m'
 fi
 printf '%s' "$color"
 printf "$@"
 printf '%s' "$reset"
}
die() { ui_printf error 'ERROR / 错误: %s\n' "$*" >&2; exit 1; }
say() { if [[ $LANGUAGE == en ]]; then ui_printf "${3:-info}" '%s\n' "$1"; else ui_printf "${3:-info}" '%s\n' "$2"; fi; }
port_valid() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && ((10#$1 <= 65535)); }
id_valid() { [[ $1 =~ ^[0-9]{14}-[a-f0-9]{16}$ ]]; }
address_valid() {
 local a=$1 n rest left right; local -a oct
 if [[ $a == *:* ]]; then
  [[ $a =~ ^[a-fA-F0-9:]+$ ]] || return 1
  if [[ $a == *::* ]]; then
   left=${a%%::*}; right=${a#*::}; [[ $right != *::* ]] || return 1
   [[ -z $left || $left =~ ^[a-fA-F0-9]{1,4}(:[a-fA-F0-9]{1,4})*$ ]] || return 1
   [[ -z $right || $right =~ ^[a-fA-F0-9]{1,4}(:[a-fA-F0-9]{1,4})*$ ]] || return 1
   rest=${left:+$left:}$right; rest=${rest%:}; IFS=: read -r -a oct <<< "$rest"
   ((${#oct[@]} < 8))
  else [[ $a =~ ^([a-fA-F0-9]{1,4}:){7}[a-fA-F0-9]{1,4}$ ]]; fi
  return
 fi
 [[ $a =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
 IFS=. read -r -a oct <<< "$a"; for n in "${oct[@]}"; do [[ ${#n} -le 3 ]] && ((10#$n <= 255)) || return 1; done
}
while (($#)); do
 case $1 in
  --apply) APPLY=1; MENU_EXTRA=1; shift;;
  --dry-run) DRY=1; MENU_EXTRA=1; shift;;
  --lang|--port|--to-port|--scope|--backend|--maxretry|--findtime|--bantime|--ip)
   (($# >= 2)) || die 'missing option value / 缺少参数值'
   case $1 in --maxretry|--findtime|--bantime) [[ -n $2 ]] || die 'missing Fail2ban option value / 缺少封禁参数值';; esac
   case $1 in --lang) LANGUAGE=$2;; --port) PORT=$2; MENU_EXTRA=1;; --to-port) TO_PORT=$2; MENU_EXTRA=1;; --scope) SCOPE=$2; MENU_EXTRA=1;; --backend) BACKEND_REQUEST=$2; MENU_EXTRA=1;; --ip) TARGET_IP=$2; MENU_EXTRA=1;;
    --maxretry) F2B_MAXRETRY=$2; F2B_OPTIONS=1; MENU_EXTRA=1;;
    --findtime) F2B_FINDTIME=$2; F2B_OPTIONS=1; MENU_EXTRA=1;;
    --bantime) F2B_BANTIME=$2; F2B_OPTIONS=1; MENU_EXTRA=1;;
   esac; shift 2;;
  firewall-setup|firewall-start|firewall-restart|firewall-allow|firewall-edit|firewall-delete|firewall-disable|firewall-clear|ssh-port|fail2ban-enable|fail2ban-disable|fail2ban-restart|fail2ban-unban|fail2ban-whitelist)
   [[ -z $ACTION ]] || die 'only one action / 每次仅一个动作'; ACTION=$1; shift;;
  *) die 'unknown argument / 未知参数';;
 esac
done
[[ $LANGUAGE == zh || $LANGUAGE == en ]] || die 'language must be zh/en'
[[ $SCOPE == owned || $SCOPE == all ]] || die 'scope must be owned/all'
[[ -z $PORT ]] || port_valid "$PORT" || die 'invalid port / 端口无效'
[[ -z $TO_PORT ]] || port_valid "$TO_PORT" || die 'invalid destination port / 新端口无效'
[[ -z $TO_PORT || $ACTION == firewall-edit ]] || die '--to-port is only for firewall-edit'
[[ -z $BACKEND_REQUEST || $BACKEND_REQUEST =~ ^(nftables|iptables|ufw|firewalld)$ ]] || die 'invalid backend'
case $MODE in confirm|rollback) die 'Confirmation and rollback commands were removed; successful changes take effect immediately / 确认和回退命令已取消，成功执行后直接生效';; esac
[[ $MODE =~ ^(menu|status|ports|rules|backups|fail2ban-status|fail2ban-logs|plan|apply|recover)$ ]] || die 'use menu/status/ports/rules/backups/fail2ban-status/fail2ban-logs/plan/apply'
if [[ $ACTION == fail2ban-unban || $ACTION == fail2ban-whitelist ]]; then
 address_valid "$TARGET_IP" || die '--ip requires a valid IPv4/IPv6 address / 请输入有效IPv4或IPv6地址'
else [[ -z $TARGET_IP ]] || die '--ip is only for fail2ban-unban/fail2ban-whitelist'; fi
case $ACTION in firewall-start|firewall-restart|firewall-disable|fail2ban-*) [[ -z $PORT$TO_PORT ]] || die 'this action takes no port options / 此操作不接受端口参数';; esac
if ((F2B_OPTIONS)); then
 [[ ($MODE == plan || $MODE == apply) && $ACTION == fail2ban-enable ]] || die 'Fail2ban options require plan/apply fail2ban-enable / 封禁参数仅用于启用Fail2ban'
 for setting in "$F2B_MAXRETRY:100" "$F2B_FINDTIME:604800" "$F2B_BANTIME:31536000"; do
  value=${setting%:*}; limit=${setting#*:}
  [[ -z $value ]] || { [[ $value =~ ^[1-9][0-9]{0,7}$ ]] && ((10#$value <= limit)); } || die 'invalid Fail2ban setting: maxretry 1..100, findtime 1..604800 seconds, bantime 1..31536000 seconds / 封禁参数须为范围内的整数（时间单位为秒）'
 done
fi
[[ $(id -u) == 0 ]] || die 'root required / 需要 root'
if [[ -n ${GUARD_TEST_ROOT:-} || -n ${GUARD_TEST_ADAPTER:-} ]]; then
 [[ -n ${GUARD_TEST_ROOT:-} && -n ${GUARD_TEST_ADAPTER:-} ]] || die 'test root and adapter must be paired'
 ROOT=$(realpath -e -- "$GUARD_TEST_ROOT")
 # Canonicalize BEFORE rejecting production roots, including // and /./.
 case $ROOT in /|/etc|/etc/*|/usr|/usr/*|/var|/var/*|/run|/run/*|/root|/home|/boot|/proc|/sys|/dev) die 'unsafe test root';; esac
 [[ -f $ROOT/.server-guard-test && ! -L $ROOT/.server-guard-test && $(cat "$ROOT/.server-guard-test") == server-guard-fixture-v1 ]] || die 'unmarked test root'
 [[ $(stat -c '%u:%a' "$ROOT") == 0:700 ]] || die 'test root must be root-owned 0700'
 ADAPTER=$(realpath -e -- "$GUARD_TEST_ADAPTER"); [[ -f $ADAPTER ]] || die 'adapter must be a regular file'
 case $ROOT$ADAPTER in *$'\n'*|*\"*|*\\*|*%*) die 'test paths contain unsupported systemd characters';; esac
 export GUARD_TEST_ROOT=$ROOT GUARD_TEST_ADAPTER=$ADAPTER
fi
os() { if [[ -n $ADAPTER ]]; then bash "$ADAPTER" "$@"; else command "$@"; fi; }
has() { if [[ -n $ADAPTER ]]; then os command-exists "$1"; else command -v "$1" >/dev/null 2>&1; fi; }
need() { has "$1" || die "missing $1; install explicitly: apt install $2 / dnf install $3 (不会自动安装)"; }
STATE=$ROOT/var/lib/server-guard
UNITS=$ROOT/etc/systemd/system
CONFIG_PATHS=(etc/nftables.conf etc/iptables etc/sysconfig/iptables etc/sysconfig/ip6tables etc/ufw etc/default/ufw etc/firewalld etc/ssh/sshd_config etc/fail2ban/jail.d/server-guard.local var/lib/server-guard/firewalld.owned var/lib/server-guard/firewall.backend)
# shellcheck source=backends.sh
source "$HERE/backends.sh"
# shellcheck source=selinux.sh
source "$HERE/selinux.sh"
secure_paths() {
 local p parent link unit
 for p in "$STATE" "$UNITS" "$UNITS/multi-user.target.wants" "$UNITS/timers.target.wants" "$UNITS/server-guard-boot.service" "$UNITS/server-guard-rollback.service" "$UNITS/server-guard-rollback.timer" "${CONFIG_PATHS[@]/#/$ROOT/}"; do
  parent=$p
  while [[ ! -e $parent && ! -L $parent ]]; do parent=${parent%/*}; [[ -n $parent ]] || parent=/; done
  [[ $(realpath -e -- "$parent") == "$parent" ]] || die "symlink path refused: $parent"
  # systemd legitimately owns symlinks throughout its unit directory. Inspect
  # only paths we write there; state/config backups remain recursively strict.
  if [[ -d $p && $p != "$UNITS" && $p != "$UNITS/"* ]]; then [[ -z $(find "$p" -type l -print -quit) ]] || die "symlink tree refused: $p"; fi
 done
 for unit in server-guard-boot.service server-guard-rollback.service server-guard-rollback.timer; do
  [[ ! -e $UNITS/$unit || -f $UNITS/$unit ]] || die 'owned unit must be a regular file'
 done
 for link in multi-user.target.wants/server-guard-boot.service timers.target.wants/server-guard-rollback.timer; do
  if [[ -e $UNITS/$link || -L $UNITS/$link ]]; then
   [[ -L $UNITS/$link && $(realpath -m -- "$UNITS/$link") == "$UNITS/${link##*/}" ]] || die 'unsafe server-guard enable link'
  fi
 done
 if [[ -e $STATE ]]; then
  [[ $(stat -c '%u:%a' "$STATE") == 0:700 ]] || die 'state must be root-owned 0700'
  [[ -z $(find "$STATE" \( ! -user root -o -perm /077 \) -print -quit) ]] || die 'unsafe state permissions'
 fi
}
platform() {
 local distro version
 [[ -f $ROOT/etc/os-release ]] || die 'missing os-release'
 distro=$(sed -n 's/^ID=//p' "$ROOT/etc/os-release" | tr -d '"')
 version=$(sed -n 's/^VERSION_ID=//p' "$ROOT/etc/os-release" | tr -d '"'); version=${version%%.*}
 [[ $version =~ ^[0-9]+$ ]] || die 'unknown distribution version'
 FAMILY=debian
 case $distro in
  debian) ((version >= 11)) || die 'Debian 11+ required';;
  ubuntu) ((version >= 22)) || die 'Ubuntu 22.04+ required';;
  rocky|almalinux|rhel) FAMILY=rhel; ((version >= 8)) || die 'RHEL family 8+ required';;
  centos) FAMILY=rhel; ((version >= 9)) || die 'CentOS 7 unsupported; CentOS Stream 9+ required';;
  *) die 'unsupported distribution / 不支持此发行版';;
 esac
}
session() {
 local extra
 read -r CLIENT CLIENT_PORT SERVER SESSION_PORT extra <<< "${SSH_CONNECTION:-}"
 [[ -n ${CLIENT:-} && -n ${SESSION_PORT:-} && -z ${extra:-} ]] || die 'SSH_CONNECTION required; use sudo --preserve-env=SSH_CONNECTION (不能猜测22端口)'
 address_valid "$CLIENT" && address_valid "$SERVER" && port_valid "$CLIENT_PORT" && port_valid "$SESSION_PORT" || die 'invalid SSH_CONNECTION'
}
established() {
 local output localaddr peer rest; local found=0
 output=$(os ss -H -tn state established) || die 'cannot verify SSH connection'
 while read -r _ _ localaddr peer rest; do
  localaddr=${localaddr//\[/}; localaddr=${localaddr//\]/}; peer=${peer//\[/}; peer=${peer//\]/}
  [[ $localaddr != "$SERVER:$SESSION_PORT" || $peer != "$CLIENT:$CLIENT_PORT" ]] || found=1
 done <<< "$output"
 [[ $found == 1 ]] || die 'SSH connection is not established / 未找到此SSH连接'
}
discover() {
 local config listeners p output
 session; established
 need sshd openssh-server openssh-server; need ss iproute2 iproute
 config=$(os sshd -T -f "$ROOT/etc/ssh/sshd_config") || die 'sshd -T failed; refusing / 无法读取有效SSH配置'
 listeners=$(os ss -H -ltnp) || die 'ss failed; refusing / 无法读取监听端口'
 output=$(awk '$1=="port" {print $2}' <<< "$config")
 [[ -n $output ]] || die 'no effective SSH ports'
 PORTS=(); while read -r p; do port_valid "$p" || die 'invalid effective SSH port'; PORTS+=("$p"); done <<< "$output"
 output=$(awk '/"sshd"/ {a=$4; sub(/^.*:/,"",a); print a}' <<< "$listeners")
 [[ -n $output ]] || die 'no identifiable sshd listener / 无法确认sshd监听'
 while read -r p; do port_valid "$p" || die 'invalid listener port'; PORTS+=("$p"); done <<< "$output"
 PORTS+=("$SESSION_PORT")
 mapfile -t PORTS < <(printf '%s\n' "${PORTS[@]}" | sort -nu)
 PROTECTED_PORTS=("${PORTS[@]}")
 case $ACTION in firewall-allow|ssh-port) [[ -z $PORT ]] || PORTS+=("$PORT");; firewall-edit) [[ -z $TO_PORT ]] || PORTS+=("$TO_PORT");; esac
 mapfile -t PORTS < <(printf '%s\n' "${PORTS[@]}" | sort -nu)
}
preflight() {
 platform; secure_paths; discover
 if [[ $ACTION == fail2ban-* ]]; then
  [[ -z $BACKEND_REQUEST ]] || die '--backend is not used for Fail2ban / Fail2ban操作无需防火墙后端'
  BACKEND=none
 else
  detect_backend; backend_preflight
 fi
 if [[ $BACKEND == firewalld ]]; then
  case $ACTION in
   firewall-allow) fw_port_unowned_or_inconsistent "$PORT" && die 'firewalld port is external or ownership is inconsistent / 端口非本工具所有或状态不一致';;
   firewall-edit) fw_port_unowned_or_inconsistent "$TO_PORT" && die 'destination firewalld port is external or inconsistent / 新端口非本工具所有或状态不一致';;
  esac
 fi
 if [[ $ACTION == firewall-edit || $ACTION == firewall-delete ]]; then
  [[ $SCOPE == owned && -n $PORT ]] || die 'owned --port required / 只允许管理自有普通端口'
  protected_port "$PORT" && die 'protected SSH port cannot be edited/deleted / SSH保护端口不可改删'
  backend_port_owned "$PORT" || die 'port is not consistently tool-owned in runtime and persistent rules / 端口不完全属于本工具'
  if [[ $ACTION == firewall-edit ]]; then
   [[ -n $TO_PORT && $TO_PORT != "$PORT" ]] || die 'a different --to-port is required'
   protected_port "$TO_PORT" && die 'destination is protected SSH port / 新端口是SSH保护端口'
   ! backend_owned_ports | grep -qx "$TO_PORT" || die 'destination port already tool-owned / 新端口已有自有规则'
  fi
 fi
 if [[ $ACTION == ssh-port ]]; then
  [[ -n $PORT ]] || die '--port required'
  ssh_service_preflight
  se_preflight || die 'SELinux preflight failed / SELinux预检失败'
  os sshd -t -f "$ROOT/etc/ssh/sshd_config" || die 'sshd -t failed'
  ssh_port_available
  if [[ -f $ROOT/etc/fail2ban/jail.d/server-guard.local ]]; then
   need fail2ban-client fail2ban fail2ban-server
   os fail2ban-client -t >/dev/null || die 'Fix Fail2ban configuration before changing SSH ports / 请先修复Fail2ban配置再修改SSH端口'
  fi
 fi
 F2B_INSTALL=0
 if [[ $ACTION == fail2ban-* ]]; then
  if has fail2ban-client; then
   os fail2ban-client -t >/dev/null || die 'existing Fail2ban configuration invalid / 已有Fail2ban配置无效，请先修复'
  elif [[ $ACTION == fail2ban-enable ]]; then
   if [[ $FAMILY == debian ]]; then need apt-get apt apt; else need dnf dnf dnf; fi
   F2B_INSTALL=1
   say 'Fail2ban is missing; after confirmation, install its server and systemd journal bindings, then enable the SSH jail.' '未安装Fail2ban；确认后将安装服务端及systemd日志依赖，再启用SSH防爆破。' warning
  else need fail2ban-client fail2ban fail2ban; fi
  if [[ $ACTION == fail2ban-restart || $ACTION == fail2ban-unban || $ACTION == fail2ban-whitelist ]]; then
   [[ -f $ROOT/etc/fail2ban/jail.d/server-guard.local ]] || die 'Enable the tool SSH protection first / 请先安装并启用本工具SSH防护'
  fi
  if [[ $ACTION == fail2ban-unban ]]; then
   os fail2ban-client status server-guard-sshd >/dev/null || die 'SSH jail is not running / SSH防护未运行'
  fi
 fi
 [[ $ACTION != firewall-allow || -n $PORT ]] || die '--port required'
}
install_fail2ban() (
 local masked=0 enabled
 enabled=$(os systemctl is-enabled fail2ban 2>/dev/null || true)
 [[ $enabled != masked* ]] || die 'Fail2ban was masked by administrator / Fail2ban已被管理员屏蔽，请先检查'
 if os systemctl is-active --quiet fail2ban; then die 'Fail2ban is active but its client is missing; repair the package first / Fail2ban服务运行中但客户端缺失，请先修复软件包'; fi
 install_cleanup() {
  local rc=$?
  if ((masked)); then
   if [[ $enabled != enabled ]] && has fail2ban-client; then os systemctl disable fail2ban || rc=1; fi
   os systemctl unmask --runtime fail2ban || rc=1
  fi
  exit "$rc"
 }
 trap install_cleanup EXIT
 masked=1
 os systemctl mask --runtime fail2ban || die 'cannot mask Fail2ban during installation / 无法临时屏蔽Fail2ban，停止安装'
 if [[ $FAMILY == debian ]]; then
  os apt-get update || die 'package index update failed / 软件源索引更新失败'
  DEBIAN_FRONTEND=noninteractive os apt-get -y install fail2ban python3-systemd || die 'Fail2ban installation failed / Fail2ban安装失败'
 else
  os dnf -y install fail2ban-server python3-systemd || die 'Fail2ban installation failed; check enabled repositories (EPEL on RHEL family) / 安装失败，请检查已启用的软件源，RHEL系列通常需要EPEL'
 fi
 need fail2ban-client fail2ban fail2ban-server
 # Keep the service stopped until its configuration has been prepared.
 if [[ $enabled != enabled ]]; then os systemctl disable fail2ban || die 'cannot preserve disabled Fail2ban state / 无法保留Fail2ban停用状态'; fi
 os fail2ban-client -t >/dev/null || die 'Installed Fail2ban configuration is invalid; package retained, service not started / 安装后配置校验失败，保留软件包且未启动服务，请检查其他jail配置'
 os systemctl unmask --runtime fail2ban || die 'cannot remove temporary Fail2ban mask / 无法移除Fail2ban临时屏蔽'
 masked=0
 say 'Fail2ban installed; preparing the configuration change.' 'Fail2ban已安装，正在准备配置变更。' success
)
lock_state() {
 mkdir -p "$STATE/transactions"; chmod 700 "$STATE" "$STATE/transactions"
 exec 9> "$STATE/lock"; flock -n 9 || die 'another server-guard process holds the lock'
}
valid_backup() {
 id_valid "$1" || die 'invalid backup id'
 local saved=$STATE/transactions/$1
 [[ -f $saved/meta && -f $saved/config.tar && -f $saved/services && -f $saved/checksums ]] || die 'backup incomplete'
 (cd "$saved" && sha256sum --check --status checksums) || die 'backup checksum mismatch / 备份完整性校验失败'
 if [[ $(sed -n '5p' "$saved/meta") =~ ^schema-[234]$ && $(sed -n '1p' "$saved/meta") == ssh-port ]]; then
  local f
  for f in meta full local export target target-local; do
   [[ -f $saved/selinux.$f ]] && grep -Eq "^[a-f0-9]{64}  selinux\.$f$" "$saved/checksums" || die 'SELinux snapshot incomplete / SELinux快照不完整'
  done
  if [[ $(sed -n '5p' "$saved/meta") =~ ^schema-[34]$ ]]; then
   for f in active target-active; do
    [[ -f $saved/selinux.$f ]] && grep -Eq "^[a-f0-9]{64}  selinux\.$f$" "$saved/checksums" || die 'SELinux complete context snapshot missing / SELinux完整上下文快照缺失'
   done
  fi
 fi
 tar -tf "$saved/config.tar" >/dev/null || die 'invalid configuration backup'
}
list_backups() {
 local saved transaction action backend status pending='' found=0
 [[ ! -f $STATE/pending ]] || pending=$(cat "$STATE/pending")
 say 'Backup IDs begin with their UTC creation time. Backups contain the state before each operation.' '备份编号前14位为UTC创建时间；备份保存每次操作前的状态。'
 for saved in "$STATE"/transactions/*; do
  [[ -d $saved ]] || continue
  transaction=${saved##*/}; id_valid "$transaction" || continue
  found=1
  if ! (valid_backup "$transaction") >/dev/null 2>&1; then
   ui_printf error 'id=%s integrity=invalid\n' "$transaction"
   continue
  fi
  action=$(sed -n '1p' "$saved/meta"); backend=$(sed -n '2p' "$saved/meta")
  # Do not render arbitrary backup metadata as terminal text.
  case $action in firewall-start|firewall-restart|firewall-allow|firewall-edit|firewall-delete|firewall-clear|firewall-disable|ssh-port|fail2ban-enable|fail2ban-disable|fail2ban-restart|fail2ban-unban|fail2ban-whitelist) :;; *) action=unknown;; esac
  case $backend in nftables|iptables|ufw|firewalld|none) :;; *) backend=unknown;; esac
  status=saved
  if [[ -f $STATE/audit.log ]]; then
   status=$(awk -v id="$transaction" '$3==id && $2~/^(applied|failed|retained|confirmed|rolled-back|rollback-failed)$/ {s=$2} END {print (s=="" ? "saved" : s)}' "$STATE/audit.log")
  fi
  if [[ -f $saved/result ]]; then
   local result; result=$(cat "$saved/result")
   case $result in running|applied|failed) status=$result;; esac
  fi
  [[ $transaction != "$pending" ]] || status=pending
  local tone=info
  case $status in pending|running) tone=warning;; applied|retained|confirmed) tone=success;; failed|rollback-failed) tone=error;; esac
  ui_printf "$tone" 'id=%s action=%s backend=%s status=%s integrity=ok\n' "$transaction" "$action" "$backend" "$status"
 done
 ((found)) || say 'No backups.' '暂无备份。'
}
save_services() {
 local s active enabled
 for s in nftables netfilter-persistent iptables ip6tables ufw firewalld fail2ban ssh sshd ssh.socket sshd.socket; do
  active=0; enabled=0
  os systemctl is-active --quiet "$s" && active=1
  os systemctl is-enabled --quiet "$s" && enabled=1
  printf '%s %s %s\n' "$s" "$active" "$enabled"
 done > "$TX/services"
}
snapshot() {
 local p; local -a paths=()
 for p in "${CONFIG_PATHS[@]}"; do [[ ! -e $ROOT/$p ]] || paths+=("$p"); done
 printf '%s\n' "${paths[@]}" > "$TX/paths"
 os tar --selinux -C "${ROOT:-/}" -cf "$TX/config.tar" -- "${paths[@]}"
 save_services; backend_snapshot; se_snapshot
 (
  cd "$TX"
  sha256sum meta family config.tar paths services > checksums
  if [[ $ACTION == ssh-port ]]; then sha256sum selinux.meta selinux.full selinux.local selinux.export selinux.target selinux.target-local selinux.active selinux.target-active >> checksums; fi
  case $BACKEND in
   nftables) sha256sum nft.runtime >> checksums;;
   iptables|ufw) sha256sum ipv4.runtime ipv6.runtime >> checksums;;
   firewalld) sha256sum fw.zones >> checksums; find firewalld -type f -exec sha256sum {} + >> checksums;;
  esac
 )
}
retire_legacy_recovery() {
 local unit changed=0 pending='' archived
 # Only cancel this tool's legacy jobs; never restore firewall/SSH state.
 for unit in server-guard-rollback.timer server-guard-rollback.service server-guard-boot.service; do
  [[ -f $UNITS/$unit ]] || continue
  case $unit in
   *.timer|server-guard-boot.service) os systemctl disable --now "$unit" || return;;
   *) os systemctl stop "$unit" || return;;
  esac
  changed=1
 done
 if [[ -f $STATE/pending ]]; then
  pending=$(cat "$STATE/pending") || return
  archived=$(mktemp "$STATE/legacy-pending.XXXXXXXX") || return
  mv -- "$STATE/pending" "$archived" || return
  id_valid "$pending" || pending=unknown
  printf '%s retained %s\n' "$(date -u +%FT%TZ)" "$pending" >> "$STATE/audit.log" || return
  changed=1
 fi
 if ((changed)); then
  printf 'immediate-v1\n' > "$STATE/workflow" || return
  say 'Legacy confirmation/recovery jobs retired; current settings and backups retained.' '旧确认及回退任务已停用，保留当前配置和备份。' success
 fi
}
legacy_recovery_present() {
 [[ -f $STATE/pending ]] && return 0
 if [[ -f $STATE/workflow && $(cat "$STATE/workflow") == immediate-v1 ]]; then return 1; fi
 local unit
 for unit in server-guard-rollback.timer server-guard-rollback.service server-guard-boot.service; do
  [[ ! -f $UNITS/$unit ]] || return 0
 done
 return 1
}
apply_change() (
 # The lock prevents two running operations, not successive completed changes.
 lock_state
 if legacy_recovery_present; then retire_legacy_recovery || die 'Cannot retire legacy recovery jobs / 无法停用旧回退任务'; fi
 preflight
 if ((F2B_INSTALL)); then install_fail2ban; preflight; fi
 ID=$(date -u +%Y%m%d%H%M%S)-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
 TX=$STATE/transactions/$ID; mkdir "$TX"
 printf '%s\n%s\n%s\n%s\nschema-4\n' "$ACTION" "$BACKEND" "$PORT" "$SSH_CONNECTION" > "$TX/meta"
 printf '%s\n' "$FAMILY" > "$TX/family"
 operation_failed() {
  local rc=$?
  trap - EXIT
  if ((rc)); then
   printf 'failed\n' > "$TX/result"
   printf '%s failed %s %s\n' "$(date -u +%FT%TZ)" "$ID" "$ACTION" >> "$STATE/audit.log"
   say "Operation failed; no automatic rollback. Backup: $ID" "操作失败，未自动回退。备份编号：$ID" error >&2
  fi
  exit "$rc"
 }
 trap operation_failed EXIT
 snapshot
 se_labels
 printf 'running\n' > "$TX/result"
 printf '%s\n' "$ID" > "$STATE/latest"
 sync -f "$STATE"
 mutate
 if [[ $ACTION == ssh-port ]]; then se_verify || die 'SELinux verification failed / SELinux授权核对失败'; fi
 printf 'applied\n' > "$TX/result"
 printf '%s applied %s %s\n' "$(date -u +%FT%TZ)" "$ID" "$ACTION" >> "$STATE/audit.log"
 trap - EXIT
 say "Applied. Backup: $ID" "已生效。备份编号：$ID" success
)
ssh_service_preflight() {
 local socket status
 SSH_SOCKET='' SSH_SERVICE=''
 for socket in ssh.socket sshd.socket; do
  if os systemctl is-active --quiet "$socket" || os systemctl is-enabled --quiet "$socket"; then
   [[ -z $SSH_SOCKET ]] || die 'Multiple SSH sockets are enabled / 多个SSH socket冲突'
   SSH_SOCKET=$socket
  fi
 done
 if [[ -n $SSH_SOCKET ]]; then
  SSH_SERVICE=${SSH_SOCKET%.socket}.service
  [[ $(os systemctl show -p KillMode --value "$SSH_SERVICE") == process ]] || die 'Socket migration requires KillMode=process to preserve current sessions / SSH服务需使用KillMode=process才支持保留连接切换'
  [[ $(os systemctl show -p SendSIGHUP --value "$SSH_SERVICE") == no ]] || die 'Socket migration requires SendSIGHUP=no / SSH服务需关闭SendSIGHUP以保留当前会话'
  status=$(os systemctl is-enabled "$SSH_SERVICE" 2>/dev/null || true)
  [[ $status != masked* ]] || die 'SSH service was masked by administrator / SSH服务已被管理员屏蔽'
 fi
}
reload_ssh() {
 if [[ -n $SSH_SOCKET ]]; then
  say 'Switching socket activation to the SSH service; existing session processes are retained.' '正在从socket激活切换为SSH服务监听，保留现有会话进程。' warning
  os systemctl disable --now "$SSH_SOCKET"
  os systemctl enable "$SSH_SERVICE"
  os systemctl restart "$SSH_SERVICE"
 elif os systemctl is-active --quiet ssh; then os systemctl reload ssh
 elif os systemctl is-active --quiet sshd; then os systemctl reload sshd
 else return 1; fi
}
ssh_port_available() {
 local output localaddr rest
 output=$(os ss -H -ltnp) || die 'Cannot inspect TCP listeners / 无法检查TCP端口占用'
 while read -r _ _ _ localaddr rest; do
  [[ ${localaddr##*:} != "$PORT" || $rest == *'"sshd"'* ]] || die "TCP port $PORT is occupied by another process / 新端口已被其他进程占用"
 done <<< "$output"
}
ssh_verify_listener() {
 local output localaddr rest attempt
 for attempt in {1..5}; do
  output=$(os ss -H -ltnp) || return 1
  while read -r _ _ _ localaddr rest; do
   [[ ${localaddr##*:} != "$PORT" || $rest != *'"sshd"'* ]] || return 0
  done <<< "$output"
  sleep 1
 done
 die "SSH did not listen on TCP $PORT / SSH新端口未监听，请保留当前连接检查"
}
fail2ban_value() {
 local key=$1 file=$ROOT/etc/fail2ban/jail.d/server-guard.local
 [[ -f $file ]] || return 0
 awk -v key="$key" '
  /^[[:space:]]*\[/ {section=$0; sub(/^[[:space:]]*/,"",section); sub(/\].*$/,"]",section); own=(section=="[server-guard-sshd]")}
  own && /^[[:space:]]*[^#;][^=]*=/ {name=$0; sub(/=.*/,"",name); gsub(/[[:space:]]/,"",name); if(name==key){value=$0; sub(/^[^=]*=[[:space:]]*/,"",value); print value}}
 ' "$file"
}
fail2ban_update() {
 local mode=$1 file=$ROOT/etc/fail2ban/jail.d/server-guard.local enabled ignore key value
 mkdir -p "${file%/*}"
 enabled=$(fail2ban_value enabled); enabled=${enabled:-false}; enabled=${enabled,,}
 case $mode in enable) enabled=true;; disable) enabled=false;; esac
 ignore=$(fail2ban_value ignoreip)
 ignore="${ignore:+$ignore }127.0.0.1/8 ::1 $CLIENT"
 [[ $mode != whitelist ]] || ignore+=" $TARGET_IP"
 ignore=$(awk '{for(i=1;i<=NF;i++)if(!seen[$i]++){printf "%s%s",sep,$i;sep=" "}} END {print ""}' <<< "$ignore")
 if [[ -f $file ]]; then
  # Preserve other sections and every unknown setting in the tool jail.
  awk '/^[[:space:]]*\[/ {section=$0; sub(/^[[:space:]]*/,"",section); sub(/\].*$/,"]",section); own=(section=="[server-guard-sshd]")} !own' "$file" > "$TX/fail2ban.new"
  awk '/^[[:space:]]*\[/ {section=$0; sub(/^[[:space:]]*/,"",section); sub(/\].*$/,"]",section); own=(section=="[server-guard-sshd]"); next} own && $0 !~ /^[[:space:]]*(filter|backend|enabled|port|ignoreip)[[:space:]]*=/' "$file" > "$TX/fail2ban.policy"
 else : > "$TX/fail2ban.new"; : > "$TX/fail2ban.policy"; fi
 {
  printf '\n[server-guard-sshd]\nfilter = sshd\nbackend = systemd\nenabled = %s\n' "$enabled"
  printf 'port = %s\nignoreip = %s\n' "$(IFS=,; echo "${PORTS[*]}")" "$ignore"
  cat "$TX/fail2ban.policy"
 } >> "$TX/fail2ban.new"
 for key in maxretry findtime bantime; do
  case $key in maxretry) value=$F2B_MAXRETRY;; findtime) value=$F2B_FINDTIME;; bantime) value=$F2B_BANTIME;; esac
  if [[ -z $value && $mode == enable ]] && ! grep -Eq "^[[:space:]]*$key[[:space:]]*=" "$TX/fail2ban.policy"; then
   case $key in maxretry) value=5;; findtime) value=600;; bantime) value=3600;; esac
  fi
  if [[ -n $value ]]; then
   # The appended jail is last; remove only its previous value.
   awk -v key="$key" '/^[[:space:]]*\[/ {section=$0; sub(/^[[:space:]]*/,"",section); sub(/\].*$/,"]",section); own=(section=="[server-guard-sshd]")} own && $0 ~ ("^[[:space:]]*" key "[[:space:]]*=") {next} {print}' "$TX/fail2ban.new" > "$TX/fail2ban.edit"
   mv "$TX/fail2ban.edit" "$TX/fail2ban.new"
   printf '%s = %s\n' "$key" "$value" >> "$TX/fail2ban.new"
  fi
 done
 cat "$TX/fail2ban.new" > "$file"
 os fail2ban-client -t >/dev/null || die 'Fail2ban configuration validation failed / Fail2ban配置校验失败'
}
fail2ban_ready() {
 local attempt
 for attempt in {1..10}; do
  if os fail2ban-client status server-guard-sshd >/dev/null 2>&1; then return 0; fi
  sleep 1
 done
 die 'Fail2ban SSH jail did not start / Fail2ban SSH防护未启动'
}
fail2ban_sync_ssh() {
 local file=$ROOT/etc/fail2ban/jail.d/server-guard.local
 if [[ ! -f $file ]]; then
  say 'Tool Fail2ban jail is not configured; enable it from main menu 10. Check other SSH jails separately.' '尚未配置本工具Fail2ban防护；可用主菜单10启用，其他jail请自行检查端口。' warning
  return 0
 fi
 say 'Synchronizing Fail2ban SSH ports.' '正在同步Fail2ban SSH防护端口。'
 fail2ban_update sync
 if os systemctl is-active --quiet fail2ban && [[ $(fail2ban_value enabled) == true ]]; then
  os fail2ban-client reload server-guard-sshd
  [[ $(fail2ban_value enabled) != true ]] || fail2ban_ready
 else say 'Fail2ban port configuration saved; protection activation is unchanged.' 'Fail2ban端口已保存，保留原防护启停状态。' warning; fi
}
fail2ban_status() {
 if ! has fail2ban-client; then say 'Fail2ban: not installed. Use main menu 10 to install and enable protection.' 'Fail2ban：未安装，可在主菜单10安装并启用防护。' warning; return 0; fi
 if ! os systemctl is-active --quiet fail2ban; then say 'Fail2ban: service stopped.' 'Fail2ban：服务未运行。' warning; return 0; fi
 say 'Fail2ban: service active.' 'Fail2ban：服务运行中。' success
 if os fail2ban-client status server-guard-sshd; then
  say 'Tool SSH jail is running.' '本工具 jail 运行中。' success
  local key value
  for key in port maxretry findtime bantime ignoreip; do value=$(fail2ban_value "$key"); ui_printf info '%s = %s\n' "$key" "${value:-inherit}"; done
 else say 'This tool SSH jail is not running. Enable it from main menu 10.' '本工具SSH防护未运行，可在主菜单10启用。' warning; fi
}
fail2ban_logs() {
 need journalctl systemd systemd
 os journalctl -u fail2ban --no-pager -n 80 || die 'Cannot read Fail2ban journal / 无法读取Fail2ban日志'
 if [[ -f $ROOT/var/log/fail2ban.log ]]; then
  say 'Recent file log (last 40 lines):' '最近文件日志（40行）：'
  tail -n 40 -- "$ROOT/var/log/fail2ban.log"
 fi
}
mutate() {
 if [[ $ACTION == ssh-port ]]; then
  local p
  {
   for p in "${PORTS[@]}"; do printf 'Port %s\n' "$p"; done
   # Normalize global Port directives instead of growing duplicate headers on
   # every operation. Keep Include, comments and Match sections unchanged.
   awk 'tolower($0) ~ /^[[:space:]]*match[[:space:]]/ {matched=1} !matched && tolower($0) ~ /^[[:space:]]*port([[:space:]]|=)/ {next} {print}' "$ROOT/etc/ssh/sshd_config"
  } > "$TX/sshd.new"
  os sshd -t -f "$TX/sshd.new"
  se_apply
 fi
 backend_change
 case $ACTION in
  ssh-port)
   # Prepend global Ports before any Include/Match; preserve all existing ports.
   cp -- "$TX/sshd.new" "$ROOT/etc/ssh/sshd_config"
   se_restore_context
   os sshd -t -f "$ROOT/etc/ssh/sshd_config"
   say 'Reloading SSH and checking its new listener.' '正在重载SSH并核对新端口监听。'
   reload_ssh
   ssh_verify_listener
   fail2ban_sync_ssh
   say "SSH TCP $PORT is listening; previous SSH ports remain available." "SSH TCP $PORT 已监听，原SSH端口继续保留；请在云安全组放行新端口。" success;;
  fail2ban-enable|fail2ban-disable)
   fail2ban_update "${ACTION#fail2ban-}"
   if [[ $ACTION == fail2ban-enable ]]; then
    os systemctl enable fail2ban
    os systemctl reload-or-restart fail2ban
    fail2ban_ready
   elif os systemctl is-active --quiet fail2ban; then os fail2ban-client reload; fi;;
  fail2ban-restart)
   os systemctl restart fail2ban
   [[ $(fail2ban_value enabled) != true ]] || fail2ban_ready;;
  fail2ban-unban) os fail2ban-client set server-guard-sshd unbanip "$TARGET_IP";;
  fail2ban-whitelist)
   fail2ban_update whitelist
   if os systemctl is-active --quiet fail2ban && [[ $(fail2ban_value enabled) == true ]]; then
    os fail2ban-client reload server-guard-sshd
    if [[ $(fail2ban_value enabled) == true ]]; then fail2ban_ready; os fail2ban-client set server-guard-sshd unbanip "$TARGET_IP"; fi
   fi;;
 esac
}
menu_invoke() { bash "$HERE/server-guard.sh" "$@" --lang "$LANGUAGE"; }
menu_read() { IFS= read -r REPLY; }
menu_confirm() {
 while :; do
  if [[ $LANGUAGE == en ]]; then ui_printf warning '%s [y/N] (default: No): ' "$1"; else ui_printf warning '%s [y/N]（默认否）：' "$2"; fi
  menu_read || return 1
  case ${REPLY,,} in
   y) return 0;;
   n|'') return 1;;
   *) say 'Please enter Y or N.' '请输入 Y 或 N。' warning;;
  esac
 done
}
menu_ports() {
 local output kind protocol port line
 output=$(menu_invoke ports) || return 1
 while IFS= read -r line; do
  if [[ $line == backend=* ]]; then
   if [[ $LANGUAGE == en ]]; then ui_printf info 'Firewall backend: %s\n' "${line#backend=}"; else ui_printf info '防火墙后端：%s\n' "${line#backend=}"; fi
   continue
  fi
  if [[ $line == firewall-state=* ]]; then
   local tone=warning; [[ ${line#firewall-state=} != active ]] || tone=success
   if [[ $LANGUAGE == en ]]; then ui_printf "$tone" 'Firewall state: %s\n' "${line#firewall-state=}"
   elif [[ ${line#firewall-state=} == active ]]; then ui_printf "$tone" '防火墙状态：已启用\n'
   else ui_printf "$tone" '防火墙状态：未启用\n'; fi
   continue
  fi
  read -r kind protocol port <<< "$line"
  case $kind in
   protected-ssh) if [[ $LANGUAGE == en ]]; then ui_printf info 'Protected SSH port: %s/%s\n' "$port" "$protocol"; else ui_printf info 'SSH 保护端口：%s/%s\n' "$port" "$protocol"; fi;;
   owned) if [[ $LANGUAGE == en ]]; then ui_printf success 'Managed port: %s/%s\n' "$port" "$protocol"; else ui_printf success '本工具管理端口：%s/%s\n' "$port" "$protocol"; fi;;
  esac
 done <<< "$output"
}
menu_change() {
 local -a args=("$@")
 menu_invoke plan "${args[@]}" || return 1
 if ! menu_confirm 'Apply these changes?' '是否执行以上变更？'; then
  say 'Cancelled.' '已取消。' muted
  return 0
 fi
 menu_invoke apply "${args[@]}" --apply
}
menu_fail2ban_policy() {
 local retries window duration
 retries=$(fail2ban_value maxretry); retries=${retries:-5}
 window=$(fail2ban_value findtime); window=${window:-600}
 duration=$(fail2ban_value bantime); duration=${duration:-3600}
 say "Configure SSH protection. Blank keeps: retries=$retries / window=${window}s / ban=${duration}s." "配置SSH防爆破：回车保留当前值，失败次数=$retries、统计窗口=$window 秒、封禁=$duration 秒。"
 say 'Maximum retries (1..100):' '最大失败次数（1..100）：' prompt
 menu_read || return 0; retries=${REPLY:-$retries}
 say 'Failure window in seconds (1..604800):' '统计窗口秒数（1..604800）：' prompt
 menu_read || return 0; window=${REPLY:-$window}
 say 'Ban duration in seconds (1..31536000):' '封禁秒数（1..31536000）：' prompt
 menu_read || return 0; duration=${REPLY:-$duration}
 menu_change fail2ban-enable --maxretry "$retries" --findtime "$window" --bantime "$duration"
}
menu_fail2ban() {
 local choice address
 while :; do
  say '=== Fail2ban protection ===' '=== Fail2ban 防护管理 ===' title
  if [[ $LANGUAGE == en ]]; then
   ui_printf info '1 Status and bans  '; ui_printf success '2 Install/enable  3 Parameters\n'
   ui_printf warning '4 Disable tool SSH jail  5 Restart Fail2ban service\n'
   ui_printf success '6 Unban IP  7 Add whitelist IP  '; ui_printf info '8 Logs\n'
   ui_printf muted '0 Back\n'; ui_printf prompt 'Choose: '
  else
   ui_printf info '1 状态与封禁列表  '; ui_printf success '2 安装并启用  3 防护参数\n'
   ui_printf warning '4 停用本工具SSH防护  5 重启Fail2ban服务\n'
   ui_printf success '6 解封IP  7 添加白名单IP  '; ui_printf info '8 查看日志\n'
   ui_printf muted '0 返回主菜单\n'; ui_printf prompt '请选择：'
  fi
  menu_read || return 0; choice=$REPLY
  case $choice in
   0) return 0;;
   1) menu_invoke fail2ban-status || say 'Status lookup failed.' '状态查询失败。' error;;
   2) menu_change fail2ban-enable || say 'Action failed.' '操作失败。' error;;
   3) menu_fail2ban_policy || say 'Action failed.' '操作失败。' error;;
   4) menu_change fail2ban-disable || say 'Action failed.' '操作失败。' error;;
   5) menu_change fail2ban-restart || say 'Action failed.' '操作失败。' error;;
   6|7)
    if [[ $choice == 6 ]]; then menu_invoke fail2ban-status || true; fi
    say 'IPv4/IPv6 address (blank cancels):' 'IPv4/IPv6地址（留空取消）：' prompt
    menu_read || return 0; address=$REPLY
    [[ -n $address ]] || continue
    if [[ $choice == 6 ]]; then menu_change fail2ban-unban --ip "$address" || say 'Action failed.' '操作失败。' error
    else menu_change fail2ban-whitelist --ip "$address" || say 'Action failed.' '操作失败。' error; fi;;
   8) menu_invoke fail2ban-logs || say 'Log lookup failed.' '日志查询失败。' error;;
   *) say 'Unknown choice.' '选项无效。' warning;;
  esac
 done
}
protection_status() {
 say 'Changes take effect immediately; no confirmation or automatic rollback.' '操作成功后直接生效，无需二次确认，不自动回退。' success
 (
  detect_backend
  local state=inactive
  case $BACKEND in
   ufw) [[ $(os ufw status) != 'Status: active'* ]] || state=active;;
   firewalld) ! os systemctl is-active --quiet firewalld || state=active;;
   nftables) [[ -z $(os nft list table inet filter 2>/dev/null) ]] || state=active;;
   iptables) if os systemctl is-active --quiet netfilter-persistent || os systemctl is-active --quiet iptables || os systemctl is-active --quiet ip6tables; then state=active; fi;;
  esac
  say "Firewall: $BACKEND ($state)" "防火墙：$BACKEND（$state）"
 ) || say 'Firewall manager unavailable or conflicting; check native rules.' '防火墙管理器未识别或存在冲突，请检查实际规则。' warning
 local config ports
 if config=$(os sshd -T -f "$ROOT/etc/ssh/sshd_config"); then
  ports=$(awk '$1=="port" {printf "%s ", $2}' <<< "$config")
  say "SSH configured TCP ports: $ports" "SSH配置TCP端口：$ports"
 else say 'Cannot read effective SSH configuration.' '无法读取SSH有效配置。' warning; fi
 fail2ban_status
}
menu() {
 local choice first second
 if [[ ! -t 0 && -z $ADAPTER ]]; then die 'menu requires an interactive terminal / 菜单需要交互终端'; fi
 while :; do
  if [[ $LANGUAGE == en ]]; then
   ui_printf title '\n=== Server Guard ===\n'
   ui_printf section '\n[Firewall]\n'
   ui_printf success ' 1 Install and enable firewall   2 Start firewall\n 3 Restart/reload firewall       '; ui_printf warning '4 Stop firewall (keep rules)\n'
   ui_printf section '\n[TCP ports]\n'
   ui_printf info ' 5 View ports  '; ui_printf success '6 Add port\n 7 Edit port   '; ui_printf error '8 Delete port\n'
   ui_printf section '\n[SSH]\n'
   ui_printf success ' 9 Change SSH port and synchronize protection\n'
   ui_printf section '\n[Fail2ban]\n'
   ui_printf success '10 Install and enable protection  '; ui_printf warning '11 Disable tool SSH protection\n'
   ui_printf success '12 Protection parameters          '; ui_printf info '13 Protection management\n'
   ui_printf section '\n[Status and maintenance]\n'
   ui_printf info '14 View status  15 Complete firewall rules\n16 Backups and results\n'
   ui_printf section '\n[Rule cleanup]\n'
   ui_printf error '17 Clear owned ports  18 Clear all supported rules\n'
   ui_printf muted '0 Exit\n'; ui_printf prompt 'Choose: '
  else
   ui_printf title '\n╔══════════ 服务器保护菜单 ══════════╗\n'
   ui_printf section '\n【防火墙】\n'
   ui_printf success ' 1 安装并启用防火墙  2 启动防火墙\n 3 重启/重载防火墙   '; ui_printf warning '4 关闭防火墙（保留规则）\n'
   ui_printf section '\n【TCP端口管理】\n'
   ui_printf info ' 5 查看端口         '; ui_printf success '6 添加TCP端口\n 7 修改TCP端口      '; ui_printf error '8 删除TCP端口\n'
   ui_printf section '\n【SSH】\n'
   ui_printf success ' 9 修改SSH端口并同步防护\n'
   ui_printf section '\n【Fail2ban防护】\n'
   ui_printf success '10 安装并启用SSH防护 '; ui_printf warning '11 停用本工具SSH防护\n'
   ui_printf success '12 配置防护参数      '; ui_printf info '13 防护管理（状态/解封/白名单/日志）\n'
   ui_printf section '\n【状态与维护】\n'
   ui_printf info '14 查看状态         15 查看完整防火墙规则\n16 查看备份与执行结果\n'
   ui_printf section '\n【规则清理】\n'
   ui_printf error '17 清空本工具端口   18 清空全部受支持规则\n'
   ui_printf muted ' 0 退出\n'; ui_printf prompt '请选择：'
  fi
  menu_read || return 0
  choice=$REPLY
  case $choice in
   0) return 0;;
   1) menu_change firewall-setup || say 'Action failed.' '操作失败。' error;;
   2) menu_change firewall-start || say 'Action failed.' '操作失败。' error;;
   3) menu_change firewall-restart || say 'Action failed.' '操作失败。' error;;
   4) menu_change firewall-disable || say 'Action failed.' '操作失败。' error;;
   5) menu_ports || say 'Port lookup failed.' '端口查询失败。' error;;
   6|8|9)
    menu_ports || true
    if [[ $LANGUAGE == en ]]; then ui_printf prompt 'TCP port (blank cancels): '; else ui_printf prompt 'TCP端口（留空取消）：'; fi
    menu_read || return 0; first=$REPLY
    [[ -n $first ]] || continue
    case $choice in
     6) menu_change firewall-allow --port "$first" || say 'Action failed.' '操作失败。' error;;
     8) menu_change firewall-delete --port "$first" || say 'Action failed.' '操作失败。' error;;
     9) menu_change ssh-port --port "$first" || say 'Action failed.' '操作失败。' error;;
    esac;;
   7)
    menu_ports || true
    if [[ $LANGUAGE == en ]]; then ui_printf prompt 'Current port: '; else ui_printf prompt '原端口：'; fi
    menu_read || return 0; first=$REPLY
    [[ -n $first ]] || continue
    if [[ $LANGUAGE == en ]]; then ui_printf prompt 'New port: '; else ui_printf prompt '新端口：'; fi
    menu_read || return 0; second=$REPLY
    [[ -n $second ]] || continue
    menu_change firewall-edit --port "$first" --to-port "$second" || say 'Action failed.' '操作失败。' error;;
   10) menu_change fail2ban-enable || say 'Action failed.' '操作失败。' error;;
   11) menu_change fail2ban-disable || say 'Action failed.' '操作失败。' error;;
   12) menu_fail2ban_policy || say 'Action failed.' '操作失败。' error;;
   13) menu_fail2ban;;
   14) menu_invoke status || say 'Guard status incomplete.' '保护工具状态查询不完整。' warning;;
   15) menu_invoke rules || say 'Rule lookup failed.' '规则查询失败。' error;;
   16) menu_invoke backups || say 'Backup lookup failed.' '备份查询失败。' error;;
   17) menu_change firewall-clear || say 'Action failed.' '操作失败。' error;;
   18) menu_change firewall-clear --scope all || say 'Action failed.' '操作失败。' error;;
   *) say 'Unknown choice.' '选项无效。' warning;;
  esac
 done
}
if [[ $ACTION == firewall-setup ]]; then
 [[ $MODE == plan || $MODE == apply ]] || die 'firewall-setup requires plan/apply'
 [[ -z $PORT$TO_PORT$ID$BACKEND_REQUEST && $SCOPE == owned ]] || die 'firewall-setup takes no port/backend/id/scope'
 if [[ $MODE == apply && $APPLY == 1 && $DRY == 0 ]] && legacy_recovery_present; then
  (secure_paths; lock_state; retire_legacy_recovery) || die 'Cannot retire legacy recovery jobs / 无法停用旧回退任务'
 fi
 setup_firewall
 exit
fi
if [[ $MODE == menu ]]; then
 [[ -z $ACTION && $MENU_EXTRA == 0 ]] || die 'menu takes only --lang / 菜单仅接受--lang'
 if legacy_recovery_present; then
  (secure_paths; lock_state; retire_legacy_recovery) || die 'Cannot retire legacy recovery jobs / 无法停用旧回退任务'
 fi
 menu; exit
fi
if [[ $MODE == status ]]; then
 [[ -z $ACTION$PORT$TO_PORT$TARGET_IP$BACKEND_REQUEST && $APPLY == 0 && $DRY == 0 && $SCOPE == owned ]] || die 'status is read-only'
 secure_paths
 protection_status
 if legacy_recovery_present; then say 'Legacy recovery jobs will be retired on menu entry or the next apply.' '进入菜单或下次执行变更时将停用旧回退任务。' warning; fi
 exit
fi
if [[ $MODE == fail2ban-status || $MODE == fail2ban-logs ]]; then
 [[ -z $ACTION$PORT$TO_PORT$TARGET_IP$BACKEND_REQUEST && $APPLY == 0 && $DRY == 0 && $SCOPE == owned ]] || die 'Fail2ban queries are read-only / Fail2ban查询仅接受只读参数'
 secure_paths
 if [[ $MODE == fail2ban-status ]]; then fail2ban_status; else fail2ban_logs; fi
 exit
fi
if [[ $MODE == rules || $MODE == backups ]]; then
 [[ -z $ACTION$PORT$TO_PORT$ID && $APPLY == 0 && $DRY == 0 && $SCOPE == owned ]] || die 'rules/backups are read-only / 规则和备份查询只接受只读参数'
 [[ $MODE != backups || -z $BACKEND_REQUEST ]] || die 'backups takes no backend / 备份查询无需后端'
 secure_paths
 if [[ $MODE == backups ]]; then list_backups
 else detect_backend; backend_show_rules || die 'cannot read firewall rules / 无法读取防火墙规则'; fi
 exit
fi
if [[ $MODE == ports ]]; then
 [[ -z $ACTION && -z $PORT && -z $TO_PORT && $APPLY == 0 ]] || die 'ports is read-only and takes no action/port / ports仅用于只读查看'
 platform; secure_paths; discover; detect_backend; backend_read_ports
 printf 'backend=%s\n' "$BACKEND"
 [[ $BACKEND != ufw ]] || printf 'firewall-state=%s\n' "$UFW_STATE"
 for p in "${PROTECTED_PORTS[@]}"; do printf 'protected-ssh tcp %s\n' "$p"; done
 owned=$(backend_owned_ports) || die 'invalid owned firewall registry / 自有规则记录无效'
 while read -r p; do [[ -z $p ]] || protected_port "$p" || printf 'owned tcp %s\n' "$p"; done <<< "$owned"
 exit
fi
if [[ $MODE == recover ]]; then
 [[ $APPLY == 1 && $DRY == 0 ]] || die 'legacy cleanup requires --apply'
 secure_paths; [[ -d $STATE ]] || exit 0
 lock_state; retire_legacy_recovery
 exit
fi
[[ -n $ACTION ]] || die 'an action is required'
preflight
if [[ $MODE == plan || $DRY == 1 ]]; then
 if [[ $LANGUAGE == en ]]; then
  ui_printf section 'backend=%s action=%s port=%s to_port=%s scope=%s protected_ports=%s\n' "$BACKEND" "$ACTION" "$PORT" "$TO_PORT" "$SCOPE" "${PROTECTED_PORTS[*]}"
 else
  case $ACTION in
   firewall-start) description='启动防火墙';; firewall-restart) description='重启/重载防火墙';; firewall-disable) description='关闭防火墙（保留规则）';;
   firewall-allow) description='添加TCP放行端口';; firewall-edit) description='修改本工具TCP端口';; firewall-delete) description='删除本工具TCP端口';;
   firewall-clear) description='清空本工具端口'; [[ $SCOPE != all ]] || description='清空全部受支持防火墙规则';;
   ssh-port) description='修改SSH端口并同步防护';; fail2ban-enable) description='安装/启用SSH防爆破';; fail2ban-disable) description='停用本工具SSH防爆破';;
   fail2ban-restart) description='重启Fail2ban服务';; fail2ban-unban) description='解封指定IP';; fail2ban-whitelist) description='添加防护白名单';;
  esac
  ui_printf section '操作预览：%s\n' "$description"
  [[ $BACKEND == none ]] || ui_printf info '防火墙：%s\n' "$BACKEND"
  [[ -z $PORT ]] || ui_printf info 'TCP端口：%s\n' "$PORT"
  [[ -z $TO_PORT ]] || ui_printf info '新TCP端口：%s\n' "$TO_PORT"
  ui_printf info '保留的SSH保护端口：%s\n' "${PROTECTED_PORTS[*]}"
 fi
 if [[ $ACTION == fail2ban-enable ]]; then
  retries=${F2B_MAXRETRY:-$(fail2ban_value maxretry)}
  window=${F2B_FINDTIME:-$(fail2ban_value findtime)}
  duration=${F2B_BANTIME:-$(fail2ban_value bantime)}
  ui_printf info 'fail2ban maxretry=%s findtime=%s bantime=%s\n' "${retries:-5}" "${window:-600}" "${duration:-3600}"
  say 'Times are seconds. Existing limits are retained; first use defaults to 5 retries / 600s / 3600s.' '时间单位为秒。沿用已有参数；首次启用默认5次失败、600秒窗口、3600秒封禁。'
 fi
 case $ACTION in
  firewall-start|firewall-restart) say 'Prepare SSH allowances, then load saved rules. Restart reloads UFW/firewalld without stopping first.' '先准备SSH放行，再加载已保存规则；UFW/firewalld重启采用重载，避免先停后起。';;
  firewall-disable) say 'Stop filtering and disable autostart; keep saved rules for the next start.' '关闭过滤并禁用开机启动，保留已保存规则，供下次启动使用。' warning;;
  ssh-port) say "Allow TCP $PORT, validate and reload SSH, check its listener, then synchronize the tool Fail2ban jail. Old SSH ports stay open." "自动放行TCP $PORT → 校验并重载SSH → 核对新端口监听 → 同步本工具Fail2ban防护；保留原SSH端口。"; say 'Allow the new TCP port in your cloud security group.' '请在云安全组放行新TCP端口。' warning
   [[ -z $SSH_SOCKET ]] || say "Disable $SSH_SOCKET and enable $SSH_SERVICE with KillMode=process to retain session processes." "同时停用 $SSH_SOCKET，改由 $SSH_SERVICE 监听；已核对KillMode=process以保留当前会话进程。" warning;;
  fail2ban-restart) say 'Restart the Fail2ban service, affecting all its jails.' '重启整个Fail2ban服务，会涉及其中全部jail。' warning;;
  fail2ban-unban) say "Unban $TARGET_IP from the tool SSH jail." "从本工具SSH防护中解封：$TARGET_IP。";;
  fail2ban-whitelist) say "Persist whitelist address $TARGET_IP and unban it from the tool SSH jail." "将 $TARGET_IP 加入本工具持久白名单，并解除本工具对它的封禁。";;
 esac
 say 'Plan only; no files, services or firewall rules changed.' '仅预览；未修改文件、服务或防火墙规则。'; exit
fi
[[ $APPLY == 1 ]] || die 'mutation requires explicit --apply / 实际变更需显式--apply'
apply_change
