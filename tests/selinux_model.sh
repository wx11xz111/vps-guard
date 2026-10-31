#!/usr/bin/env bash
# Model stores BASE and LOCAL independently; exact local keys shadow base keys.
set -euo pipefail
F=${GUARD_TEST_ROOT:?}/fixture
bad() { echo "UNEXPECTED semanage arguments: $*" >&2; exit 97; }
flatten() {
 awk '{type=$1; proto=$2; $1="";$2=""; n=split($0,a,","); for(i=1;i<=n;i++) {gsub(/ /,"",a[i]); print type,proto,a[i]}}' "$@"
}
case "$*" in
 active)
  [[ ! -f $F/se-active-fail ]] || exit 1
  if [[ -f $F/se-active-invalid ]]; then cat "$F/se-active-invalid"; exit; fi
  while read -r type proto ports origin; do
   range=s0; range_file=$F/se-range-$ports
   [[ $origin != base ]] || range_file=$F/se-base-range-$ports
   [[ ! -f $range_file ]] || range=$(cat "$range_file")
   context=system_u:object_r:$type
   [[ $(cat "$GUARD_TEST_ROOT/sys/fs/selinux/mls") == 0 ]] || context+=:$range
   printf 'portcon %s %s %s\n' "$proto" "$ports" "$context"
  done < <({ flatten "$F/se-base" | sed 's/$/ base/'; flatten "$F/se-local" | sed 's/$/ local/'; } | awk '{r[$2 FS $3]=$0} END {for(k in r) print r[k]}' | sort);;
 'port -l -n')
  [[ ! -f $F/se-query-fail ]] || exit 1
  if [[ -f $F/se-invalid ]]; then cat "$F/se-invalid"; exit; fi
  flatten "$F/se-base" "$F/se-local" | awk '{r[$2 FS $3]=$0} END {for(k in r) print r[k]}' | sort;;
 'port -l -n -C')
  [[ ! -f $F/se-local-fail ]] || exit 1
  flatten "$F/se-local" | sort;;
 'port -E')
  [[ ! -f $F/se-export-fail ]] || exit 1
  while read -r type proto ports; do
   [[ -n $type ]] || continue
   range=s0; [[ ! -f $F/se-range-$ports ]] || range=$(cat "$F/se-range-$ports")
   if [[ $(cat "$GUARD_TEST_ROOT/sys/fs/selinux/mls") == 0 ]]; then
    printf -- 'port -a -t %s -p %s %s\n' "$type" "$proto" "$ports"
   else printf -- "port -a -t %s -r '%s' -p %s %s\n" "$type" "$range" "$proto" "$ports"; fi
  done < <(flatten "$F/se-local");;
 'port -a -t ssh_port_t -p tcp -r s0 2299')
  [[ ! -f $F/se-add-before-fail ]] || exit 1
  ! flatten "$F/se-base" "$F/se-local" | grep -Eq '^[^ ]+ tcp 2299$' || exit 1
  printf 'ssh_port_t tcp 2299\n' >> "$F/se-local"
  if [[ -f $F/se-add-after-fail ]]; then exit 1; fi
  if [[ -f $F/se-after-query-fail ]]; then touch "$F/se-query-fail"; fi
  if [[ -f $F/se-add-wrong ]]; then sed -i 's/ssh_port_t tcp 2299/http_port_t tcp 2299/' "$F/se-local"; fi;;
 'port -d -p tcp 2299')
  [[ ! -f $F/se-delete-fail ]] || exit 1
  grep -qx 'ssh_port_t tcp 2299' "$F/se-local" || exit 1
  sed -i '/^ssh_port_t tcp 2299$/d' "$F/se-local"
  [[ ! -f $F/se-delete-after-fail ]] || exit 1;;
 *) bad "$@";;
esac
