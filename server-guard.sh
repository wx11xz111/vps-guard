#!/usr/bin/env bash
# Independent, fail-closed SSH/firewall transactions. No panel dependency.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
umask 077
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
LANGUAGE=zh ROOT='' ADAPTER='' MODE=${1:-menu} ACTION='' PORT='' TO_PORT='' ID='' SCOPE=owned APPLY=0 DRY=0 TIMEOUT=180 BACKEND_REQUEST='' MENU_EXTRA=0
[[ $# == 0 ]] || shift
die() { printf 'ERROR / 错误: %s\n' "$*" >&2; exit 1; }
say() { if [[ $LANGUAGE == en ]]; then printf '%s\n' "$1"; else printf '%s\n' "$2"; fi; }
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
  --lang|--port|--to-port|--id|--scope|--timeout|--backend)
   (($# >= 2)) || die 'missing option value / 缺少参数值'
   case $1 in --lang) LANGUAGE=$2;; --port) PORT=$2; MENU_EXTRA=1;; --to-port) TO_PORT=$2; MENU_EXTRA=1;; --id) ID=$2; MENU_EXTRA=1;; --scope) SCOPE=$2; MENU_EXTRA=1;; --timeout) TIMEOUT=$2; MENU_EXTRA=1;; --backend) BACKEND_REQUEST=$2; MENU_EXTRA=1;; esac; shift 2;;
  firewall-setup|firewall-allow|firewall-edit|firewall-delete|firewall-disable|firewall-clear|firewall-restore|ssh-port|fail2ban-enable|fail2ban-disable)
   [[ -z $ACTION ]] || die 'only one action / 每次仅一个动作'; ACTION=$1; shift;;
  *) die 'unknown argument / 未知参数';;
 esac
done
[[ $LANGUAGE == zh || $LANGUAGE == en ]] || die 'language must be zh/en'
[[ $SCOPE == owned || $SCOPE == all ]] || die 'scope must be owned/all'
[[ $TIMEOUT =~ ^[0-9]{2,4}$ ]] && ((10#$TIMEOUT >= 30 && 10#$TIMEOUT <= 3600)) || die 'timeout must be 30..3600 seconds'
[[ -z $PORT ]] || port_valid "$PORT" || die 'invalid port / 端口无效'
[[ -z $TO_PORT ]] || port_valid "$TO_PORT" || die 'invalid destination port / 新端口无效'
[[ -z $TO_PORT || $ACTION == firewall-edit ]] || die '--to-port is only for firewall-edit'
[[ -z $ID ]] || id_valid "$ID" || die 'invalid transaction id / 事务编号无效'
[[ -z $BACKEND_REQUEST || $BACKEND_REQUEST =~ ^(nftables|iptables|ufw|firewalld)$ ]] || die 'invalid backend'
[[ $MODE =~ ^(menu|status|ports|plan|apply|confirm|rollback|recover)$ ]] || die 'use menu/status/ports/plan/apply/confirm/rollback'
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
CONFIG_PATHS=(etc/nftables.conf etc/iptables etc/sysconfig/iptables etc/sysconfig/ip6tables etc/ufw etc/default/ufw etc/firewalld etc/ssh/sshd_config etc/fail2ban/jail.d/server-guard.local var/lib/server-guard/firewalld.owned)
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
}
preflight() {
 platform; secure_paths; discover
 local running
 [[ -d $ROOT/run/systemd/system ]] || die 'persistent systemd rollback required'
 running=$(os systemctl is-system-running 2>/dev/null) || [[ $running == degraded ]] || die 'systemd unavailable'
 [[ $running == running || $running == degraded ]] || die 'systemd unavailable'
 if [[ $ACTION == firewall-restore ]]; then
  [[ -n $ID ]] || die '--id required'; valid_transaction "$ID"
  local saved_backend; saved_backend=$(sed -n '2p' "$STATE/transactions/$ID/meta")
  [[ $saved_backend =~ ^(nftables|iptables|ufw|firewalld)$ ]] || die 'invalid saved backend'
  [[ -z $BACKEND_REQUEST || $BACKEND_REQUEST == "$saved_backend" ]] || die 'restore backend mismatch'
  BACKEND_REQUEST=$saved_backend
 fi
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
  if os systemctl is-active --quiet ssh.socket || os systemctl is-active --quiet sshd.socket || os systemctl is-enabled --quiet ssh.socket || os systemctl is-enabled --quiet sshd.socket; then die 'socket-activated SSH unsupported; no changes / socket激活暂不支持'; fi
  se_preflight || die 'SELinux preflight failed / SELinux预检失败'
  os sshd -t -f "$ROOT/etc/ssh/sshd_config" || die 'sshd -t failed'
 fi
 if [[ $ACTION == fail2ban-* ]]; then need fail2ban-client fail2ban fail2ban; os fail2ban-client -t >/dev/null || die 'existing Fail2ban configuration invalid'; fi
 [[ $ACTION != firewall-allow || -n $PORT ]] || die '--port required'
 if [[ $ACTION == firewall-restore ]]; then [[ -n $ID ]] || die '--id required'; valid_transaction "$ID"; [[ $(sed -n '2p' "$STATE/transactions/$ID/meta") == "$BACKEND" ]] || die 'restore backend mismatch'; fi
}
lock_state() {
 mkdir -p "$STATE/transactions"; chmod 700 "$STATE" "$STATE/transactions"
 exec 9> "$STATE/lock"; flock -n 9 || die 'another server-guard process holds the lock'
}
valid_transaction() {
 id_valid "$1" || die 'invalid transaction id'
 local saved=$STATE/transactions/$1
 [[ -f $saved/meta && -f $saved/config.tar && -f $saved/services && -f $saved/checksums ]] || die 'transaction backup incomplete'
 (cd "$saved" && sha256sum --check --status checksums) || die 'transaction checksum mismatch / 备份完整性校验失败'
 if [[ $(sed -n '5p' "$saved/meta") =~ ^schema-[23]$ && $(sed -n '1p' "$saved/meta") == ssh-port ]]; then
  local f
  for f in meta full local export target target-local; do
   [[ -f $saved/selinux.$f ]] && grep -Eq "^[a-f0-9]{64}  selinux\.$f$" "$saved/checksums" || die 'SELinux snapshot incomplete / SELinux快照不完整'
  done
  if [[ $(sed -n '5p' "$saved/meta") == schema-3 ]]; then
   for f in active target-active; do
    [[ -f $saved/selinux.$f ]] && grep -Eq "^[a-f0-9]{64}  selinux\.$f$" "$saved/checksums" || die 'SELinux complete context snapshot missing / SELinux完整上下文快照缺失'
   done
  fi
 fi
 tar -tf "$saved/config.tar" >/dev/null || die 'invalid configuration backup'
}
save_services() {
 local s active enabled
 for s in nftables netfilter-persistent iptables ip6tables ufw firewalld fail2ban; do
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
arm() {
 mkdir -p "$STATE/runner" "$UNITS"
 if [[ $HERE != "$STATE/runner" ]]; then cp -- "$HERE/server-guard.sh" "$HERE/backends.sh" "$HERE/selinux.sh" "$STATE/runner/"; fi
 chmod 700 "$STATE/runner"; chmod 600 "$STATE/runner/"*.sh
 # Fixed production path; adapters are passed only in fixture units, never evaluated.
 local exec_line='/bin/bash /var/lib/server-guard/runner/server-guard.sh recover --apply' calendar next environment=''
 if [[ -n $ROOT ]]; then exec_line="/bin/bash \"$STATE/runner/server-guard.sh\" recover --apply"; fi
 if [[ -n $ROOT ]]; then environment="Environment=\"GUARD_TEST_ROOT=$ROOT\" \"GUARD_TEST_ADAPTER=$ADAPTER\""; fi
 calendar=$(date -u -d "+$TIMEOUT seconds" '+%Y-%m-%d %H:%M:%S UTC')
 date -d "$calendar" +%s > "$TX/deadline"
 for unit in server-guard-rollback.service server-guard-boot.service; do
  cat > "$UNITS/$unit" <<EOF
[Unit]
Description=Server Guard pending transaction recovery
After=network.target
[Service]
Type=oneshot
$environment
ExecStart=$exec_line
Restart=on-failure
RestartSec=30s
UMask=0077
[Install]
WantedBy=multi-user.target
EOF
 done
 cat > "$UNITS/server-guard-rollback.timer" <<EOF
[Unit]
Description=Server Guard confirmation deadline
[Timer]
OnCalendar=$calendar
Persistent=true
AccuracySec=1s
Unit=server-guard-rollback.service
[Install]
WantedBy=timers.target
EOF
 chmod 600 "$UNITS/server-guard-boot.service" "$UNITS/server-guard-rollback.service" "$UNITS/server-guard-rollback.timer"
 se_labels
 os systemctl daemon-reload
 os systemctl enable server-guard-boot.service
 os systemctl enable --now server-guard-rollback.timer
 os systemctl is-enabled --quiet server-guard-boot.service
 os systemctl is-active --quiet server-guard-rollback.timer
 next=$(os systemctl show --property=NextElapseUSecRealtime --value server-guard-rollback.timer)
 [[ -n $next && $next != n/a && $(date -d "$next" +%s) -gt $(date +%s) ]]
}
disarm() {
 os systemctl disable --now server-guard-rollback.timer
 os systemctl disable server-guard-boot.service
 # Keep recovery units and runner on disk for audit/retry; disabled after success.
}
restore_services() {
 local s active enabled
 while read -r s active enabled; do
  case $s in nftables|netfilter-persistent|iptables|ip6tables|ufw|firewalld|fail2ban) :;; *) return 1;; esac
  [[ $active =~ ^[01]$ && $enabled =~ ^[01]$ ]] || return 1
  # Only affected services; never start unrelated firewalls.
  case "$BACKEND:$s:$OLD_ACTION" in
   nftables:nftables:*|iptables:netfilter-persistent:*|iptables:iptables:*|iptables:ip6tables:*|ufw:ufw:*|firewalld:firewalld:*|*:fail2ban:fail2ban-*) ;;
   *) continue;;
  esac
  if [[ $BACKEND == iptables ]]; then
   if [[ -f $TX/family && $(cat "$TX/family") == debian && ($s == iptables || $s == ip6tables) ]]; then continue; fi
   if [[ -f $TX/family && $(cat "$TX/family") == rhel && $s == netfilter-persistent ]]; then continue; fi
  fi
  if [[ $enabled == 1 ]]; then os systemctl enable "$s" || return; else os systemctl disable "$s" || return; fi
  if [[ $active == 1 ]]; then os systemctl start "$s" || return; else os systemctl stop "$s" || return; fi
 done < "$TX/services"
}
restore_transaction() {
 local p
 OLD_ACTION=$(sed -n '1p' "$TX/meta"); BACKEND=$(sed -n '2p' "$TX/meta")
 [[ $BACKEND =~ ^(nftables|iptables|ufw|firewalld)$ || ($BACKEND == none && $OLD_ACTION == fail2ban-*) ]] || return 1
 export GUARD_RECOVERING=1
 if [[ $BACKEND == none ]]; then
  p=etc/fail2ban/jail.d/server-guard.local
  rm -f -- "$ROOT/$p" || return
  if grep -Fxq "$p" "$TX/paths"; then os tar --selinux -C "${ROOT:-/}" -xf "$TX/config.tar" -- "$p" || return; fi
 else
  for p in "${CONFIG_PATHS[@]}"; do rm -rf -- "$ROOT/${p:?}" || return; done
  os tar --selinux -C "${ROOT:-/}" -xf "$TX/config.tar" || return
 fi
 restore_services || return
 backend_restore || return
 if [[ $OLD_ACTION == ssh-port ]]; then
  se_restore_context || return
  os sshd -t -f "$ROOT/etc/ssh/sshd_config" && reload_ssh || return
  se_rollback || return
 fi
 if [[ $OLD_ACTION == fail2ban-* ]]; then
  os fail2ban-client -t >/dev/null || return
  if grep -q '^fail2ban 1 ' "$TX/services"; then os systemctl reload-or-restart fail2ban || return; fi
 fi
}
recover_locked() {
 [[ -f $STATE/pending ]] || return 0
 local pending; pending=$(cat "$STATE/pending"); valid_transaction "$pending"
 [[ -z $ID || $ID == "$pending" ]] || die 'id is not the pending transaction'
 TX=$STATE/transactions/$pending
 if restore_transaction; then
  printf '%s rolled-back %s\n' "$(date -u +%FT%TZ)" "$pending" >> "$STATE/audit.log"
  rm -- "$STATE/pending"; disarm
  say "Rolled back: $pending" "已回退：$pending"
 else
  printf '%s rollback-failed %s\n' "$(date -u +%FT%TZ)" "$pending" >> "$STATE/audit.log"
  say 'Recovery failed; pending state and timer retained for retry.' '回退失败；保留待确认状态和独立回退任务以便重试。' >&2
  return 1
 fi
}
reload_ssh() { if os systemctl is-active --quiet ssh; then os systemctl reload ssh; elif os systemctl is-active --quiet sshd; then os systemctl reload sshd; else return 1; fi; }
mutate() {
 if [[ $ACTION == ssh-port ]]; then se_apply; fi
 backend_change
 case $ACTION in
  ssh-port)
   # Prepend global Ports before any Include/Match; preserve all existing ports.
   local p
   { for p in "${PORTS[@]}"; do printf 'Port %s\n' "$p"; done; cat "$ROOT/etc/ssh/sshd_config"; } > "$TX/sshd.new"
   cp -- "$TX/sshd.new" "$ROOT/etc/ssh/sshd_config"
   se_restore_context
   os sshd -t -f "$ROOT/etc/ssh/sshd_config"
   reload_ssh;;
  fail2ban-enable|fail2ban-disable)
   mkdir -p "$ROOT/etc/fail2ban/jail.d"
   { printf '[server-guard-sshd]\nfilter = sshd\nbackend = systemd\nenabled = %s\n' "$([[ $ACTION == fail2ban-enable ]] && echo true || echo false)"
     printf 'port = %s\n' "$(IFS=,; echo "${PORTS[*]}")"
     printf 'ignoreip = 127.0.0.1/8 ::1 %s\n' "$CLIENT"
   } > "$ROOT/etc/fail2ban/jail.d/server-guard.local"
   os fail2ban-client -t >/dev/null
   os systemctl reload-or-restart fail2ban;;
 esac
}
menu_invoke() { bash "$HERE/server-guard.sh" "$@" --lang "$LANGUAGE"; }
menu_read() { IFS= read -r REPLY; }
menu_ports() {
 local output kind protocol port line
 output=$(menu_invoke ports) || return 1
 while IFS= read -r line; do
  if [[ $line == backend=* ]]; then
   if [[ $LANGUAGE == en ]]; then printf 'Firewall backend: %s\n' "${line#backend=}"; else printf '防火墙后端：%s\n' "${line#backend=}"; fi
   continue
  fi
  read -r kind protocol port <<< "$line"
  case $kind in
   protected-ssh) if [[ $LANGUAGE == en ]]; then printf 'Protected SSH port: %s/%s\n' "$port" "$protocol"; else printf 'SSH 保护端口：%s/%s\n' "$port" "$protocol"; fi;;
   owned) if [[ $LANGUAGE == en ]]; then printf 'Managed port: %s/%s\n' "$port" "$protocol"; else printf '本工具管理端口：%s/%s\n' "$port" "$protocol"; fi;;
  esac
 done <<< "$output"
}
menu_change() {
 local -a args=("$@")
 local answer
 menu_invoke plan "${args[@]}" || return 1
 if [[ $LANGUAGE == en ]]; then printf 'Type YES to apply (anything else cancels): '; else printf '输入“确认”执行，其他内容取消：'; fi
 menu_read || return 0
 answer=$REPLY
 if [[ ($LANGUAGE == zh && $answer != 确认) || ($LANGUAGE == en && $answer != YES) ]]; then
  say 'Cancelled.' '已取消。'
  return 0
 fi
 menu_invoke apply "${args[@]}" --apply
}
menu() {
 local choice first second transaction
 if [[ ! -t 0 && -z $ADAPTER ]]; then die 'menu requires an interactive terminal / 菜单需要交互终端'; fi
 while :; do
  if [[ $LANGUAGE == en ]]; then
   printf '\n=== Server Guard ===\n1 Install and enable firewall\n2 Ports  3 Add port  4 Edit port  5 Delete port\n6 SSH port  7 Enable Fail2ban  8 Disable Fail2ban\n9 Status\n10 Disable firewall  11 Clear owned ports  12 Clear all rules\n13 Restore firewall  14 Confirm transaction  15 Roll back transaction\n0 Exit\nChoose: '
  else
   printf '\n╔══════════ 服务器保护菜单 ══════════╗\n'
   printf '\n【防火墙与端口】\n 1 安装并启用防火墙\n 2 查看端口       3 添加端口       4 修改端口\n 5 删除端口\n'
   printf '\n【SSH 与防爆破】\n 6 切换 SSH 端口  7 启用 Fail2ban  8 停用 Fail2ban\n'
   printf '\n【状态与维护】\n 9 查看状态\n10 关闭防火墙    11 清空自有端口  12 清空全部规则\n'
   printf '13 恢复防火墙    14 确认变更      15 手工回退\n 0 退出\n请选择：'
  fi
  menu_read || return 0
  choice=$REPLY
  case $choice in
   0) return 0;;
   2) menu_ports || say 'Port lookup failed.' '端口查询失败。';;
   3|5|6)
    if [[ $LANGUAGE == en ]]; then printf 'Port: '; else printf '端口：'; fi
    menu_read || return 0; first=$REPLY
    case $choice in
     3) menu_change firewall-allow --port "$first" || say 'Action failed.' '操作失败。';;
     5) menu_change firewall-delete --port "$first" || say 'Action failed.' '操作失败。';;
     6) menu_change ssh-port --port "$first" || say 'Action failed.' '操作失败。';;
    esac;;
   4)
    if [[ $LANGUAGE == en ]]; then printf 'Current port: '; else printf '原端口：'; fi
    menu_read || return 0; first=$REPLY
    if [[ $LANGUAGE == en ]]; then printf 'New port: '; else printf '新端口：'; fi
    menu_read || return 0; second=$REPLY
    menu_change firewall-edit --port "$first" --to-port "$second" || say 'Action failed.' '操作失败。';;
   9)
    if ! menu_invoke status; then say 'Guard status incomplete.' '保护工具状态查询不完整。'; fi
    if os systemctl is-active --quiet fail2ban; then
     if has fail2ban-client && os fail2ban-client status server-guard-sshd >/dev/null 2>&1; then
      say 'Fail2ban: service active; this tool jail active' 'Fail2ban：服务运行中，本工具 jail 运行中'
     elif [[ -f $ROOT/etc/fail2ban/jail.d/server-guard.local ]] && grep -Eq '^enabled[[:space:]]*=[[:space:]]*true$' "$ROOT/etc/fail2ban/jail.d/server-guard.local"; then
      say 'Fail2ban: service active; this tool jail not running' 'Fail2ban：服务运行中，本工具 jail 未运行'
     else
      say 'Fail2ban: service active; this tool jail disabled' 'Fail2ban：服务运行中，本工具 jail 未启用'
     fi
    else say 'Fail2ban: service inactive' 'Fail2ban：服务未运行'; fi;;
   1) menu_change firewall-setup || say 'Action failed.' '操作失败。';;
   7) menu_change fail2ban-enable || say 'Action failed.' '操作失败。';;
   8) menu_change fail2ban-disable || say 'Action failed.' '操作失败。';;
   10) menu_change firewall-disable --scope all || say 'Action failed.' '操作失败。';;
   11) menu_change firewall-clear || say 'Action failed.' '操作失败。';;
   12) menu_change firewall-clear --scope all || say 'Action failed.' '操作失败。';;
   13|14|15)
    if [[ $LANGUAGE == en ]]; then printf 'Transaction ID: '; else printf '事务编号：'; fi
    menu_read || return 0; transaction=$REPLY
    case $choice in
     13) menu_change firewall-restore --id "$transaction" || say 'Action failed.' '操作失败。';;
     14) menu_invoke confirm --id "$transaction" --apply || say 'Confirmation failed.' '确认失败。';;
     15)
      if ! id_valid "$transaction"; then say 'A valid transaction ID is required.' '必须输入有效的事务编号。'; continue; fi
      if [[ $LANGUAGE == en ]]; then printf 'Roll back transaction %s? Type YES: ' "$transaction"; else printf '回退事务 %s？输入“确认”执行：' "$transaction"; fi
      menu_read || return 0
      if [[ ($LANGUAGE == zh && $REPLY != 确认) || ($LANGUAGE == en && $REPLY != YES) ]]; then say 'Cancelled.' '已取消。'; continue; fi
      menu_invoke rollback --id "$transaction" --apply || say 'Rollback failed.' '回退失败。';;
    esac;;
   *) say 'Unknown choice.' '选项无效。';;
  esac
 done
}
if [[ $ACTION == firewall-setup ]]; then
 [[ $MODE == plan || $MODE == apply ]] || die 'firewall-setup requires plan/apply'
 [[ -z $PORT$TO_PORT$ID$BACKEND_REQUEST && $SCOPE == owned ]] || die 'firewall-setup takes no port/backend/id/scope'
 setup_firewall
 exit
fi
if [[ $MODE == menu ]]; then
 [[ -z $ACTION && $MENU_EXTRA == 0 ]] || die 'menu takes only --lang / 菜单仅接受--lang'
 menu; exit
fi
if [[ $MODE == status ]]; then
 secure_paths
 if [[ -f $STATE/pending ]]; then printf 'pending / 待确认: %s\n' "$(cat "$STATE/pending")"; else say 'No pending transaction.' '没有待确认事务。'; fi
 exit
fi
if [[ $MODE == ports ]]; then
 [[ -z $ACTION && -z $PORT && -z $TO_PORT && $APPLY == 0 ]] || die 'ports is read-only and takes no action/port / ports仅用于只读查看'
 platform; secure_paths; discover; detect_backend; backend_preflight
 printf 'backend=%s\n' "$BACKEND"
 for p in "${PROTECTED_PORTS[@]}"; do printf 'protected-ssh tcp %s\n' "$p"; done
 owned=$(backend_owned_ports) || die 'invalid owned firewall registry / 自有规则记录无效'
 while read -r p; do [[ -z $p ]] || protected_port "$p" || printf 'owned tcp %s\n' "$p"; done <<< "$owned"
 exit
fi
if [[ $MODE == rollback || $MODE == recover ]]; then
 [[ $APPLY == 1 && $DRY == 0 ]] || die 'recovery requires --apply'
 secure_paths; [[ -d $STATE ]] || exit 0; lock_state; recover_locked; exit
fi
if [[ $MODE == confirm ]]; then
 [[ $APPLY == 1 && $DRY == 0 && -n $ID ]] || die 'confirm requires --id and --apply'
 secure_paths; [[ -d $STATE ]] || die 'no transaction'; lock_state; valid_transaction "$ID"
 [[ -f $STATE/pending && $(cat "$STATE/pending") == "$ID" ]] || die 'not pending'
 session; established; TX=$STATE/transactions/$ID
 deadline=$(cat "$TX/deadline")
 [[ $deadline =~ ^[0-9]+$ && $(date +%s) -lt $deadline ]] || die 'confirmation deadline passed; rollback required / 已过确认期限，请回退'
 old_session=$(sed -n '4p' "$TX/meta"); read -r old_client _ old_server _ <<< "$old_session"
 [[ $CLIENT == "$old_client" && $SERVER == "$old_server" && $SSH_CONNECTION != "$old_session" ]] || die 'confirm from a NEW SSH session at the same management source/server / 需要同管理来源的新SSH会话'
 if [[ $(sed -n '1p' "$TX/meta") == ssh-port ]]; then [[ $SESSION_PORT == "$(sed -n '3p' "$TX/meta")" ]] || die 'confirm must use new SSH port / 必须通过新端口确认'; fi
 se_confirm || die 'SELinux authorization changed; rollback required / SELinux授权变化，请检查并回退'
 printf '%s confirmed %s\n' "$(date -u +%FT%TZ)" "$ID" >> "$STATE/audit.log"
 rm -- "$STATE/pending"; disarm; say "Confirmed: $ID" "已确认：$ID"; exit
fi
[[ -n $ACTION ]] || die 'an action is required'
preflight
if [[ $MODE == plan || $DRY == 1 ]]; then
 printf 'backend=%s action=%s port=%s to_port=%s scope=%s protected_ports=%s timeout=%ss\n' "$BACKEND" "$ACTION" "$PORT" "$TO_PORT" "$SCOPE" "${PROTECTED_PORTS[*]}" "$TIMEOUT"
 say 'Plan only; no files, services or firewall rules changed.' '仅预览；未修改文件、服务或防火墙规则。'; exit
fi
[[ $APPLY == 1 ]] || die 'mutation requires explicit --apply / 实际变更需显式--apply'
lock_state
[[ ! -f $STATE/pending ]] || die 'one pending transaction only; confirm or rollback it first'
RESTORE_ID=$ID # consumed by backends.sh
ID=$(date -u +%Y%m%d%H%M%S)-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
TX=$STATE/transactions/$ID; mkdir "$TX"
printf '%s\n%s\n%s\n%s\nschema-3\n' "$ACTION" "$BACKEND" "$PORT" "$SSH_CONNECTION" > "$TX/meta"
printf '%s\n' "$FAMILY" > "$TX/family"
snapshot
printf '%s\n' "$ID" > "$STATE/pending"
# Compensation is installed before arming; network writes occur only after arm succeeds.
NETWORK_STARTED=0
on_error_exit() {
 local rc=$?
 trap - EXIT
 if ((rc)) && [[ -f $STATE/pending ]]; then
  if [[ $NETWORK_STARTED == 1 ]]; then recover_locked || true
  else rm -- "$STATE/pending"; disarm || true; fi
 fi
 exit "$rc"
}
trap on_error_exit EXIT
arm
sync -f "$STATE"
sync -f "$UNITS"
NETWORK_STARTED=1
mutate
printf '%s applied %s %s\n' "$(date -u +%FT%TZ)" "$ID" "$ACTION" >> "$STATE/audit.log"
trap - EXIT
printf 'pending / 待确认: %s\n' "$ID"
say 'Open a NEW SSH session and confirm --id ID --apply before the deadline. Old SSH ports remain allowed.' '请在截止前通过新的SSH会话执行 confirm --id 编号 --apply。旧SSH端口保留。'
