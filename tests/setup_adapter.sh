#!/usr/bin/env bash
set -euo pipefail
R=${GUARD_TEST_ROOT:?}; F=$R/fixture
[[ -f $R/.server-guard-test ]] || exit 98
cmd=$1; shift
log() { printf '%s' "$cmd" >> "$F/setup.log"; printf ' <%s>' "$@" >> "$F/setup.log"; printf '\n' >> "$F/setup.log"; }
case $cmd in
 command-exists)
  case $1 in ufw|firewall-cmd|firewall-offline-cmd) [[ -f $F/installed ]] && exit 0 || exit 1;; esac;;
 apt-get|dnf)
  log "$@"; [[ ! -f $F/package-fail ]] || exit 1
  [[ -f $F/masked ]] || exit 95
  touch "$F/installed"; exit 0;;
 systemctl)
  case "$*" in
   'is-enabled ufw'|'is-enabled firewalld') echo disabled; exit 1;;
   'mask --runtime ufw'|'mask --runtime firewalld') log "$@"; touch "$F/masked"; exit 0;;
   'unmask --runtime ufw'|'unmask --runtime firewalld') log "$@"; rm -f "$F/masked"; exit 0;;
   'enable ufw'|'enable firewalld'|'disable ufw'|'disable firewalld') log "$@"; exit 0;;
   'start firewalld')
    log "$@"
    for p in 2222 2200 2022; do grep -qx "$p/tcp" "$F/setup.ports" || exit 95; done
    [[ ! -f $F/masked ]] || exit 95
    echo 1 > "$F/services/firewalld.active"; exit 0;;
   'stop firewalld') log "$@"; echo 0 > "$F/services/firewalld.active"; exit 0;;
  esac;;
 ufw)
  case "$*" in
   'status') [[ $(cat "$F/ufw-active") == 0 ]] && echo 'Status: inactive' || echo 'Status: active'; exit 0;;
   '--force enable')
    log "$@"
    for p in 2222 2200 2022; do grep -q -- "--dport $p " "$R/etc/ufw/before.rules" || exit 95; grep -q -- "--dport $p " "$R/etc/ufw/before6.rules" || exit 95; done
    [[ ! -f $F/masked ]] || exit 95
    echo 1 > "$F/ufw-active"
    [[ ! -f $F/setup-enable-fail ]] || exit 1
    exit 0;;
   '--force disable') log "$@"; echo 0 > "$F/ufw-active"; exit 0;;
   'allow '*'/tcp') log "$@"; exit 0;;
  esac;;
 firewall-offline-cmd)
  log "$@"
  case "$*" in
   *--get-zones) echo 'public internal';;
   *--get-policies) echo allow-host-ipv6;;
   *--get-target) echo CONTINUE;;
   *--list-rich-rules) [[ ! -f $F/rich-fail ]] || exit 1;;
   *--list-forward-ports|*--check-config) :;;
   *--add-port=*) printf '%s\n' "${*: -1}" | sed 's/--add-port=//' >> "$F/setup.ports";;
   *) exit 97;;
  esac; exit 0;;
 firewall-cmd)
  log "$@"
  case "$*" in --state) echo running;; *--query-port=*) [[ ! -f $F/query-fail ]] || exit 1; grep -qx -- "${*: -1}" <(sed 's/^/--query-port=/' "$F/setup.ports");; *) exit 97;; esac; exit;;
esac
exec bash "$(dirname "$0")/adapter.sh" "$cmd" "$@"
