#!/usr/bin/env bash
set -euo pipefail
R=${GUARD_TEST_ROOT:?}; F=$R/fixture
[[ -f $R/.server-guard-test && $R != / ]] || exit 98
cmd=$1; shift
printf '%s' "$cmd" >> "$F/log"; printf ' <%s>' "$@" >> "$F/log"; printf '\n' >> "$F/log"
bad() { echo "UNEXPECTED adapter command: $cmd $*" >&2; exit 97; }
mutation() {
 [[ -f $F/timer-ready || ${GUARD_RECOVERING:-} == 1 ]] || { echo 'network write before timer verified' >&2; exit 96; }
 printf 'MUTATE %s %s\n' "$cmd" "$*" >> "$F/log"
}
backend=$(cat "$F/backend")
service_link() {
 local operation=$1 name=$2 target=multi-user.target
 [[ $name == *.* ]] || name=$name.service
 [[ $name != *.timer ]] || target=timers.target
 mkdir -p "$R/etc/systemd/system/$target.wants"
 if [[ $operation == enable ]]; then ln -sf "../$name" "$R/etc/systemd/system/$target.wants/$name"
 else rm -f "$R/etc/systemd/system/$target.wants/$name"; fi
}
service_change() {
 local operation=$1 name=$2
 mutation "$@"
 if [[ $operation == start && -f $F/config-labels ]]; then
  while IFS='|' read -r path context inode; do
   [[ -e $R/$path && $(stat -c %i "$R/$path") == "$inode" ]] || { echo "configuration context lost before service start: $path" >&2; return 1; }
  done < "$F/config-labels"
 fi
 case $operation in
  enable|disable) service_link "$operation" "$name"; [[ $operation == enable ]] && echo 1 > "$F/services/$name.enabled" || echo 0 > "$F/services/$name.enabled";;
  start|stop)
   [[ $operation == start ]] && echo 1 > "$F/services/$name.active" || echo 0 > "$F/services/$name.active"
   if [[ $name == firewalld && $operation == start ]]; then
    if [[ -f $F/require-start-port ]]; then
     [[ " $(cat "$R/etc/firewalld/fixture-ports") " == *" $(cat "$F/require-start-port")/tcp "* ]] || { echo 'UNSAFE: firewalld started before SSH protection' >&2; exit 95; }
    fi
    cp "$R/etc/firewalld/fixture-ports" "$F/fw-ports"; cp "$R/etc/firewalld/fixture-target" "$F/fw-target"
   fi
   if [[ $name == ufw ]]; then
    if [[ $operation == start ]] && grep -qx 'ENABLED=yes' "$R/etc/ufw/ufw.conf"; then echo 1 > "$F/ufw-active"; else echo 0 > "$F/ufw-active"; fi
   fi;;
 esac
}
case $cmd in
 tar)
  [[ $# -ge 5 && $1 == --selinux && $2 == -C && $3 == "$R" && $4 =~ ^-[cx]f$ && $5 == "$R/var/lib/server-guard/transactions/"*/config.tar ]] || bad "$@"
  archive=$5
  if [[ $4 == -cf ]]; then
   [[ ! -f $F/tar-save-fail ]] || exit 1
   command tar "$@"
   if [[ -f $F/config-labels ]]; then cp "$F/config-labels" "$archive.model-labels"; fi
  else
   [[ ! -f $F/tar-restore-fail ]] || exit 1
   command tar "$@"
   if [[ -f $archive.model-labels ]]; then
    : > "$F/config-labels"
    while IFS='|' read -r path context inode; do
     [[ -e $R/$path ]] || bad "missing extracted path: $path"
     printf '%s|%s|%s\n' "$path" "$context" "$(stat -c %i "$R/$path")" >> "$F/config-labels"
    done < "$archive.model-labels"
   fi
  fi;;
 systemctl)
  case "$*" in
   'is-system-running') [[ ! -f $F/systemd ]] || exit 1; echo running;;
   'is-active --quiet ssh.socket'|'is-enabled --quiet ssh.socket') [[ -f $F/socket ]] || exit 3;;
   'is-active --quiet sshd.socket'|'is-enabled --quiet sshd.socket') exit 3;;
   'is-active --quiet server-guard-rollback.timer') [[ ! -f $F/timer-fail ]] || exit 3; touch "$F/timer-ready";;
   'is-enabled --quiet server-guard-boot.service') [[ ! -f $F/timer-fail ]] || exit 1;;
   'show --property=NextElapseUSecRealtime --value server-guard-rollback.timer')
    if [[ -f $F/se-before-apply-conflict ]]; then printf 'http_port_t tcp 2299\n' >> "$F/se-local"; fi
    date -u -d '+180 seconds' '+%a %Y-%m-%d %H:%M:%S UTC';;
   'is-active --quiet firewalld'|'is-active --quiet ufw'|'is-active --quiet nftables'|'is-active --quiet netfilter-persistent'|'is-active --quiet iptables'|'is-active --quiet ip6tables')
    s=${*: -1}; [[ $(cat "$F/services/$s.active") == 1 || ($s == firewalld && -f $F/conflict) ]] || exit 3;;
   'is-active --quiet ssh'|'is-active --quiet sshd') :;;
   'is-active --quiet fail2ban') [[ $(cat "$F/services/fail2ban.active") == 1 ]] || exit 3;;
   'is-enabled --quiet fail2ban'|'is-enabled --quiet nftables'|'is-enabled --quiet netfilter-persistent'|'is-enabled --quiet iptables'|'is-enabled --quiet ip6tables'|'is-enabled --quiet ufw'|'is-enabled --quiet firewalld') s=${*: -1}; [[ $(cat "$F/services/$s.enabled") == 1 ]] || exit 1;;
   'daemon-reload') :;;
   'enable server-guard-boot.service'|'disable server-guard-boot.service') service_link "$1" "$2";;
   'enable --now server-guard-rollback.timer'|'disable --now server-guard-rollback.timer') service_link "$1" "$3"; if [[ $1 == disable ]]; then rm -f "$F/timer-ready"; fi;;
   'cat netfilter-persistent') [[ ! -f $F/missing-netfilter-persistent ]] || exit 1; echo '[Service]';;
   'cat nftables'|'cat iptables ip6tables') echo '[Service]';;
   'reload ssh'|'reload sshd'|'reload-or-restart fail2ban')
    mutation "$@"
    if [[ $* == 'reload-or-restart fail2ban' ]]; then echo 1 > "$F/services/fail2ban.active"; fi
    if [[ -f $F/ssh-reload-fail && ${GUARD_RECOVERING:-} != 1 ]]; then exit 1; fi
    if [[ -f $F/se-base ]]; then
     expected_context=system_u:object_r:sshd_config_t:s0
     [[ $(cat "$R/sys/fs/selinux/mls") != 0 ]] || expected_context=system_u:object_r:sshd_config_t
     [[ $(cat "$F/se-context") == "$expected_context" ]] || exit 1
     if grep -q '^Port 2299$' "$R/etc/ssh/sshd_config"; then
      awk '$1=="ssh_port_t" && $2=="tcp" {n=split($3,a,"-"); if((n==1 && a[1]==2299) || (n==2 && a[1]<=2299 && a[2]>=2299)) found=1} END {exit !found}' "$F/se-local" "$F/se-base" || exit 1
     fi
    fi;;
   'start firewalld'|'stop firewalld'|'enable firewalld'|'disable firewalld'|'start ufw'|'stop ufw'|'enable ufw'|'disable ufw'|'enable nftables'|'disable nftables'|'start nftables'|'stop nftables'|'enable netfilter-persistent'|'disable netfilter-persistent'|'start netfilter-persistent'|'stop netfilter-persistent'|'enable iptables'|'disable iptables'|'start iptables'|'stop iptables'|'enable ip6tables'|'disable ip6tables'|'start ip6tables'|'stop ip6tables'|'start fail2ban'|'stop fail2ban'|'enable fail2ban'|'disable fail2ban') service_change "$@";;
   *) bad "$@";;
  esac;;
 sshd)
  case ${1:-} in
   -T) [[ ! -f $F/sshd-T ]] || exit 1; printf 'port 2222\nport 2200\npasswordauthentication yes\n';;
   -t) [[ ! -f $F/sshd-t ]] || exit 1; if [[ -f $F/new-sshd-invalid ]] && grep -q '^Port 2299$' "$R/etc/ssh/sshd_config"; then exit 1; fi;;
   *) bad "$@";;
  esac;;
 ss)
  [[ ! -f $F/ss ]] || exit 1
  case "$*" in
   '-H -ltnp') printf 'LISTEN 0 128 [::]:2022 [::]:* users:(("sshd",pid=50,fd=3))\n';;
   '-H -tn state established') read -r cip cp sip sp <<< "${SSH_CONNECTION:?}"; printf '0 0 [%s]:%s [%s]:%s\n' "$sip" "$sp" "$cip" "$cp";;
   *) bad "$@";;
  esac;;
 getenforce) [[ $# == 0 ]] || bad "$@"; [[ ! -f $F/getenforce-fail ]] || exit 1; if [[ -f $F/selinux ]]; then cat "$F/selinux"; else echo Disabled; fi;;
 semanage)
  case "$*" in 'port -a '*|'port -d '*) mutation "$@";; esac
  bash "$(dirname "$0")/selinux_model.sh" "$@";;
 seinfo)
  [[ $# == 4 && $1 == --portcon && $2 == -x && $3 == --flat && $4 == "$R/sys/fs/selinux/policy" ]] || bad "$@"
  bash "$(dirname "$0")/selinux_model.sh" active;;
 stat)
  [[ $# == 3 && $1 == -c && $2 == %C && ($3 == "$R/etc/"* || $3 == "$R/var/lib/server-guard/firewalld.owned") ]] || bad "$@"
  [[ ! -f $F/context-read-fail ]] || exit 1
  cat "$F/se-context";;
 chcon)
  [[ $# == 3 && $1 == -- && ($3 == "$R/etc/"* || $3 == "$R/var/lib/server-guard/firewalld.owned") ]] || bad "$@"
  [[ ! -f $F/context-write-fail ]] || exit 1
  [[ $3 != "$R/etc/ssh/sshd_config" ]] || printf '%s\n' "$2" > "$F/se-context";;
 restorecon)
  [[ $# == 5 && $1 == -RF && $2 == "$R/var/lib/server-guard" && $3 == "$R/etc/systemd/system/server-guard-boot.service" && $4 == "$R/etc/systemd/system/server-guard-rollback.service" && $5 == "$R/etc/systemd/system/server-guard-rollback.timer" ]] || bad "$@"
  [[ ! -f $F/labels-fail ]] || exit 1
  touch "$F/labels-ready";;
 matchpathcon)
  [[ $# == 2 && $1 == -V && ($2 == "$R/var/lib/server-guard/"* || $2 == "$R/etc/systemd/system/server-guard-"*) ]] || bad "$@"
  [[ -f $F/labels-ready && ! -f $F/labels-verify-fail ]] || exit 1;;
 iptables-save|ip6tables-save)
  [[ $# == 0 ]] || bad "$@"
  if [[ $backend == nftables || $backend == firewalld ]]; then exit 0; fi
  [[ $cmd == iptables-save ]] && cat "$F/v4" || cat "$F/v6";;
 iptables-restore|ip6tables-restore)
  [[ $# == 0 ]] || bad "$@"
  mutation "$@"
  [[ ! -f $F/restore-fail ]] || exit 1
  [[ $cmd == iptables-restore ]] && target=$F/v4 || target=$F/v6
  cat > "$target"
  if [[ $cmd == ip6tables-restore && -f $F/mutate-fail ]]; then rm "$F/mutate-fail"; exit 1; fi;;
 nft)
  case "$*" in
   'list tables') if [[ $backend == nftables ]]; then echo 'table inet filter'; elif [[ $backend == firewalld && $(cat "$F/services/firewalld.active") == 1 ]]; then echo 'table inet firewalld'; fi; [[ ! -f $F/foreign-nft ]] || echo 'table inet f2b-table';;
   'list ruleset') cat "$F/nft";;
   '-f '*) [[ $# == 2 ]] || bad "$@"; mutation "$@"; [[ ! -f $F/restore-fail ]] || exit 1; sed '/^flush ruleset$/d' "$2" > "$F/nft";;
   *) bad "$@";;
  esac;;
 ufw)
  case "$*" in
   'status') [[ $backend == ufw && $(cat "$F/ufw-active") == 1 ]] && echo 'Status: active' || echo 'Status: inactive';;
   'status numbered')
    [[ ! -f $F/ufw-status-fail ]] || exit 1
    if [[ $backend == ufw && $(cat "$F/ufw-active") == 1 ]]; then
     printf 'Status: active\n\n     To                         Action      From\n[ 1] 8080/tcp                   ALLOW IN    Anywhere\n[ 2] 5353/udp (v6)              ALLOW IN    Anywhere (v6)\n'
    else echo 'Status: inactive'; fi;;
   'show raw') printf 'IPv4 runtime\n'; cat "$F/v4"; printf 'IPv6 runtime\n'; cat "$F/v6";;
   '--force disable') mutation "$@"; echo 0 > "$F/ufw-active"; echo ENABLED=no > "$R/etc/ufw/ufw.conf";;
   '--force enable'|'reload') mutation "$@"; echo 1 > "$F/ufw-active"; echo ENABLED=yes > "$R/etc/ufw/ufw.conf"; for family in v4 v6; do bash "$(dirname "$0")/ufw_model.sh" load "$R" "$family"; done;;
   'default allow incoming'|'default allow outgoing'|'default allow routed') mutation "$@";;
   '--force reset') mutation "$@"; echo 0 > "$F/ufw-active"; echo ENABLED=no > "$R/etc/ufw/ufw.conf"; printf '*filter\n:ufw-before-input - [0:0]\n:ufw-before-output - [0:0]\nCOMMIT\n' > "$R/etc/ufw/before.rules"; sed 's/ufw-/ufw6-/g' "$R/etc/ufw/before.rules" > "$R/etc/ufw/before6.rules";;
   *) bad "$@";;
  esac;;
 firewall-cmd)
  [[ $(cat "$F/services/firewalld.active") == 1 ]] || exit 252
  case "$*" in
   '--state') [[ $backend == firewalld ]] || exit 1; echo running;;
   '--get-zones') echo public;;
   '--get-active-zones') printf 'public\n  interfaces: eth0\n';;
   '--list-all-zones'|'--permanent --list-all-zones')
    ports=$F/fw-ports; [[ $1 != --permanent ]] || ports=$R/etc/firewalld/fixture-ports
    printf 'public\n  services: %s\n  ports: %s\n' "$(cat "$F/fw-services")" "$(cat "$ports")";;
   '--get-active-policies'|'--get-policies'|'--permanent --get-policies'|'--direct --get-all-rules'|'--permanent --direct --get-all-rules'|'--direct --get-all-passthroughs'|'--permanent --direct --get-all-passthroughs') :;;
   '--reload') mutation "$@"; cp "$R/etc/firewalld/fixture-ports" "$F/fw-ports"; cp "$R/etc/firewalld/fixture-target" "$F/fw-target";;
   *)
    perm=0; [[ ${1:-} != --permanent ]] || { perm=1; shift; }
    [[ ${1:-} == --zone=public && $# == 2 ]] || bad "$@"
    opt=$2; ports=$F/fw-ports; [[ $perm == 0 ]] || ports=$R/etc/firewalld/fixture-ports
    case $opt in
     --list-ports) cat "$ports";;
     --list-services) cat "$F/fw-services";;
     --list-interfaces) echo eth0;;
     --list-sources|--list-rich-rules|--list-forward-ports|--list-source-ports|--list-protocols|--list-icmp-blocks) :;;
     --get-target) [[ $perm == 1 ]] || bad 'get-target requires --permanent'; cat "$R/etc/firewalld/fixture-target";;
     --list-all) printf 'public (active)\n  target: %s\n' "$(cat "$F/fw-target")";;
     --set-target=ACCEPT) [[ $perm == 1 ]] || bad 'set-target requires --permanent'; mutation "$@"; echo ACCEPT > "$R/etc/firewalld/fixture-target";;
     --query-masquerade|--query-icmp-block-inversion|--query-forward) exit 1;;
     --add-port=*|--remove-port=*)
      mutation "$@"; value=${opt#*=}
      if [[ $opt == --add-* ]]; then printf '%s %s\n' "$(cat "$ports")" "$value" > "$ports"; else awk -v v="$value" '{for(i=1;i<=NF;i++)if($i!=v){printf "%s%s",sep,$i;sep=" "}} END{print ""}' "$ports" > "$ports.new"; mv "$ports.new" "$ports"; fi;;
     --add-service=*|--remove-service=*|--add-interface=*|--remove-interface=*|--add-source=*|--remove-source=*) mutation "$@";;
     *) bad "$@";;
    esac;;
  esac;;
 firewall-offline-cmd)
  [[ $(cat "$F/services/firewalld.active") == 0 ]] || bad 'offline command while daemon running'
  [[ ${1:-} == --system-config && ${2:-} == "$R/etc/firewalld" ]] || bad "$@"
  shift 2
  case "$*" in
   '--check-config') [[ ! -f $F/offline-invalid ]] || exit 1;;
   '--zone=public --add-port='*)
    [[ $# == 2 && $2 =~ ^--add-port=[0-9]+/tcp$ ]] || bad "$@"
    mutation "$@"; value=${2#*=}; ports=$R/etc/firewalld/fixture-ports
    if [[ " $(cat "$ports") " != *" $value "* ]]; then printf '%s %s\n' "$(cat "$ports")" "$value" > "$ports"; fi
    if [[ -f $F/offline-add-fail ]]; then rm "$F/offline-add-fail"; exit 1; fi;;
   *) bad "$@";;
  esac;;
 fail2ban-client)
  case "$*" in
   -t) [[ ! -f $F/fail2ban-t ]] || exit 1;;
   'status server-guard-sshd') [[ ! -f $F/fail2ban-jail-fail && $(cat "$F/services/fail2ban.active") == 1 && -f $R/etc/fail2ban/jail.d/server-guard.local ]] && grep -Eq '^enabled[[:space:]]*=[[:space:]]*true$' "$R/etc/fail2ban/jail.d/server-guard.local" || exit 1;;
   *) bad "$@";;
  esac;;
 command-exists) [[ $# == 1 ]] || bad "$@"; [[ ! -f $F/missing-$1 ]] || exit 1;;
 *) bad "$@";;
esac
