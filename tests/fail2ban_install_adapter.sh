#!/usr/bin/env bash
set -euo pipefail
R=${GUARD_TEST_ROOT:?}; F=$R/fixture
[[ -f $R/.server-guard-test && $R != / ]] || exit 98
cmd=$1; shift
log() { printf '%s' "$cmd" >> "$F/install.log"; printf ' <%s>' "$@" >> "$F/install.log"; printf '\n' >> "$F/install.log"; }
case $cmd in
 apt-get|dnf)
  log "$@"
  [[ -f $F/fail2ban-masked && -f $R/var/lib/server-guard/lock && ! -f $R/var/lib/server-guard/pending ]] || exit 95
  [[ $(cat "$F/services/fail2ban.active") == 0 ]] || exit 95
  [[ ! -f $F/package-fail ]] || exit 1
  case "$cmd $*" in
   'apt-get update') exit 0;;
   'apt-get -y install fail2ban python3-systemd'|'dnf -y install fail2ban-server python3-systemd')
    rm -f "$F/missing-fail2ban-client"
    echo 1 > "$F/services/fail2ban.enabled"
    [[ ! -f $F/package-partial-fail ]] || exit 1
    exit 0;;
   *) exit 97;;
  esac;;
 systemctl)
  case "$*" in
   'is-enabled fail2ban')
    if [[ -f $F/admin-masked ]]; then echo masked; exit 1; fi
    if [[ $(cat "$F/services/fail2ban.enabled") == 1 ]]; then echo enabled; exit 0; else echo disabled; exit 1; fi;;
   'mask --runtime fail2ban') log "$@"; touch "$F/fail2ban-masked"; exit 0;;
   'unmask --runtime fail2ban') log "$@"; rm -f "$F/fail2ban-masked"; exit 0;;
   'disable fail2ban')
    if [[ -f $F/fail2ban-masked ]]; then log "$@"; echo 0 > "$F/services/fail2ban.enabled"; exit 0; fi;;
  esac;;
esac
exec bash "$(dirname "$0")/adapter.sh" "$cmd" "$@"
