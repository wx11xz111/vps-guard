#!/usr/bin/env bash
# Sourced by server-guard.sh. Never evaluate semanage output as shell code.
se_error() { printf 'SELinux: %s / 策略校验失败，操作停止\n' "$*" >&2; return 1; }
se_mode() {
 if has getenforce; then
  SE_MODE=$(os getenforce) || { se_error 'getenforce failed'; return 1; }
 else
  # selinuxfs is registered only when SELinux initializes. Inspect the live
  # kernel, not /etc/selinux/config (which describes the next boot).
  [[ -r $ROOT/proc/filesystems && -r $ROOT/proc/self/mountinfo ]] || { se_error 'cannot prove SELinux inactive; install selinux-utils / libselinux-utils'; return 1; }
  if grep -qw selinuxfs "$ROOT/proc/filesystems" "$ROOT/proc/self/mountinfo" || [[ -e $ROOT/sys/fs/selinux/enforce || -e $ROOT/selinux/enforce ]]; then
   se_error 'getenforce missing with possible active SELinux'; return 1
  fi
  SE_MODE=Disabled
 fi
 case $SE_MODE in Disabled|Enforcing|Permissive) :;; *) se_error 'unknown enforcement mode'; return 1;; esac
}
se_list_parse() {
 awk '
 NF==0 {next}
 {
  if ($1 !~ /^[a-zA-Z_][a-zA-Z0-9_]*_t$/ || $2 !~ /^(tcp|udp|dccp|sctp)$/) exit 1
  type=$1; proto=$2; $1=""; $2=""; sub(/^[ \t]+/, ""); n=split($0, ports, ",")
  for(i=1;i<=n;i++) {
   gsub(/^[ \t]+|[ \t]+$/, "", ports[i]); v=ports[i]
   if(v !~ /^[0-9]+(-[0-9]+)?$/) exit 1
   m=split(v, ends, "-"); lo=ends[1]+0; hi=(m==2?ends[2]+0:lo)
   if(lo<1 || hi>65535 || lo>hi || (lo==hi && m==2)) exit 1
   key=proto SUBSEP lo SUBSEP hi; if(seen[key]++) exit 1
   print proto, lo, hi, type
  }
 }' | LC_ALL=C sort
}
se_extract_parse() {
 # Official CLI adds "port " to portRecords.customized() output.
 # Accept only canonical raw ranges; quoting is data, never shell syntax.
 awk '
 NF==0 {next}
 {
  if($1!="port") exit 1
  sub(/^[ \t]*port[ \t]+/, "", $0)
  if($1!="-a" || $2!="-t" || $3 !~ /^[a-zA-Z_][a-zA-Z0-9_]*_t$/) exit 1
  type=$3; range="none"; pos=4
  if($4=="-r") {range=$5; q=sprintf("%c",39); if(substr(range,1,1)!=q || substr(range,length(range),1)!=q) exit 1; range=substr(range,2,length(range)-2); if(range !~ /^s[0-9]+(:c[0-9]+([.,]c?[0-9]+)*)?(-s[0-9]+(:c[0-9]+([.,]c?[0-9]+)*)?)?$/) exit 1; pos=6}
  if(NF!=pos+2 || $pos!="-p" || $(pos+1) !~ /^(tcp|udp|dccp|sctp)$/ || $(pos+2) !~ /^[0-9]+(-[0-9]+)?$/) exit 1
  proto=$(pos+1); m=split($(pos+2),ends,"-"); lo=ends[1]+0; hi=(m==2?ends[2]+0:lo)
  if(lo<1 || hi>65535 || lo>hi || (lo==hi && m==2)) exit 1
  key=proto SUBSEP lo SUBSEP hi; if(seen[key]++) exit 1
  print proto,lo,hi,type,range
 }' | LC_ALL=C sort
}
se_active_parse() {
 awk '
 NF==0 {next}
 {
  if(NF!=4 || $1!="portcon" || $2 !~ /^(tcp|udp|dccp|sctp)$/ || $3 !~ /^[0-9]+(-[0-9]+)?$/) exit 1
  proto=$2; m=split($3,p,"-"); lo=p[1]+0; hi=(m==2?p[2]+0:lo)
  if(lo<1 || hi>65535 || lo>hi || (m==2 && lo==hi)) exit 1
  context=$4; n=split(context,c,":")
  if(n<3 || c[1] !~ /^[a-zA-Z0-9_]+$/ || c[2] !~ /^[a-zA-Z0-9_]+$/ || c[3] !~ /^[a-zA-Z_][a-zA-Z0-9_]*_t$/) exit 1
  range="none"
  if(n>3) {range=context; sub(/^[^:]+:[^:]+:[^:]+:/,"",range); if(range !~ /^s[0-9]+(:c[0-9]+([.,]c?[0-9]+)*)?(-s[0-9]+(:c[0-9]+([.,]c?[0-9]+)*)?)?$/) exit 1}
  key=proto SUBSEP lo SUBSEP hi; if(seen[key]++) exit 1
  print proto,lo,hi,c[3],range,context
 }' | LC_ALL=C sort
}
se_read() {
 local raw projected
 [[ -r $ROOT/sys/fs/selinux/mls ]] || { se_error 'cannot read mounted SELinux MLS mode'; return 1; }
 raw=$(cat "$ROOT/sys/fs/selinux/mls") || return
 case $raw in 1) SE_LEVEL=s0;; 0) SE_LEVEL=none;; *) se_error 'unknown kernel MLS mode'; return 1;; esac
 raw=$(os semanage port -l -n) || { se_error 'full policy query failed'; return 1; }
 SE_FULL=$(se_list_parse <<< "$raw") || { se_error 'invalid full policy'; return 1; }
 [[ -n $SE_FULL ]] || { se_error 'empty full policy'; return 1; }
 raw=$(os semanage port -l -n -C) || { se_error 'local policy query failed'; return 1; }
 SE_LOCAL=$(se_list_parse <<< "$raw") || { se_error 'invalid local policy'; return 1; }
 raw=$(os semanage port -E) || { se_error 'MLS/MCS export unavailable'; return 1; }
 SE_EXPORT=$(se_extract_parse <<< "$raw") || { se_error 'unsupported MLS/MCS export'; return 1; }
 projected=$(awk 'NF {print $1,$2,$3,$4}' <<< "$SE_EXPORT")
 [[ $projected == "$SE_LOCAL" ]] || { se_error 'local list/export disagreement'; return 1; }
 [[ -r $ROOT/sys/fs/selinux/policy ]] || { se_error 'cannot read active kernel policy'; return 1; }
 raw=$(os seinfo --portcon -x --flat "$ROOT/sys/fs/selinux/policy") || { se_error 'complete active contexts unavailable; seinfo --flat support required'; return 1; }
 SE_ACTIVE=$(se_active_parse <<< "$raw") || { se_error 'invalid active policy contexts'; return 1; }
 projected=$(awk 'NF {print $1,$2,$3,$4}' <<< "$SE_ACTIVE")
 [[ $projected == "$SE_FULL" ]] || { se_error 'active kernel/store disagreement'; return 1; }
 projected=$(awk 'NF {print $1,$2,$3,$4,$5}' <<< "$SE_ACTIVE")
 while IFS= read -r raw; do [[ -z $raw ]] || grep -Fxq -- "$raw" <<< "$projected" || { se_error 'active/local MLS disagreement'; return 1; }; done <<< "$SE_EXPORT"
 # Every local record must be visible in the merged policy at the same key.
 while IFS= read -r raw; do [[ -z $raw ]] || grep -Fxq -- "$raw" <<< "$SE_FULL" || { se_error 'merged/local disagreement'; return 1; }; done <<< "$SE_LOCAL"
 SE_TARGET=$(awk -v p="$PORT" '$1=="tcp" && $2<=p && $3>=p' <<< "$SE_FULL")
 SE_TARGET_LOCAL=$(awk -v p="$PORT" '$1=="tcp" && $2<=p && $3>=p' <<< "$SE_EXPORT")
 SE_TARGET_ACTIVE=$(awk -v p="$PORT" '$1=="tcp" && $2<=p && $3>=p' <<< "$SE_ACTIVE")
}
se_classify() {
 local proto lo hi type range context expected count=0
 while read -r proto lo hi type range context; do
  [[ -n $proto ]] || continue
  expected=system_u:object_r:$type
  [[ $SE_LEVEL == none ]] || expected+=:s0
  [[ $range == "$SE_LEVEL" && $context == "$expected" ]] || { se_error 'non-default active base/local port context'; return 1; }
 done <<< "$SE_TARGET_ACTIVE"
 SE_ACTION=add
 while read -r proto lo hi type; do
  [[ -n $proto ]] || continue
  case "$type:$lo:$hi" in
   port_t:1:65535|unreserved_port_t:1024:65535|reserved_port_t:1:511|reserved_port_t:1:1023|hi_reserved_port_t:512:1023)
    # Only base defaults may overlap. A customized generic range is ambiguous.
    if awk -v l="$lo" -v h="$hi" '$2==l && $3==h {found=1} END {exit !found}' <<< "$SE_TARGET_LOCAL"; then se_error 'customized generic range'; return 1; fi;;
   *) [[ $type == ssh_port_t ]] || { se_error 'port belongs to another service'; return 1; }; count=$((count+1)); SE_ACTION=reuse;;
  esac
 done <<< "$SE_TARGET"
 ((count<=1)) || { se_error 'overlapping SSH ranges'; return 1; }
 while read -r proto lo hi type range; do
  [[ -n $proto ]] || continue
  [[ $type == ssh_port_t && $range == "$SE_LEVEL" ]] || { se_error 'unsupported local context'; return 1; }
 done <<< "$SE_TARGET_LOCAL"
}
se_context() {
 SE_CONTEXT=$(os stat -c %C "$ROOT/etc/ssh/sshd_config") || return 1
 if [[ $SE_LEVEL == none ]]; then
  [[ $SE_CONTEXT =~ ^[a-zA-Z0-9_]+:[a-zA-Z0-9_]+:[a-zA-Z0-9_]+$ ]] || { se_error 'unsupported non-MLS SSH file context'; return 1; }
 else
  [[ $SE_CONTEXT =~ ^[a-zA-Z0-9_]+:[a-zA-Z0-9_]+:[a-zA-Z0-9_]+:s[0-9]+(:[a-zA-Z0-9_,.:-]+)?$ ]] || { se_error 'unsupported SSH file context'; return 1; }
 fi
}
se_preflight() {
 se_mode || return
 SE_ACTION=disabled SE_FULL='' SE_LOCAL='' SE_EXPORT='' SE_TARGET='' SE_TARGET_LOCAL='' SE_CONTEXT='' SE_LEVEL='' SE_ACTIVE='' SE_TARGET_ACTIVE=''
 [[ $SE_MODE != Disabled ]] || return 0
 need semanage policycoreutils-python-utils policycoreutils-python-utils
 need seinfo setools setools-console
 need restorecon policycoreutils policycoreutils
 need matchpathcon selinux-utils libselinux-utils
 need chcon coreutils coreutils
 se_read && se_classify && se_context
}
se_snapshot() {
 [[ $ACTION == ssh-port ]] || return 0
 printf '%s\n' "$SE_MODE" "$SE_ACTION" "$PORT" "$SE_CONTEXT" "$SE_LEVEL" > "$TX/selinux.meta"
 printf '%s\n' "$SE_FULL" > "$TX/selinux.full"
 printf '%s\n' "$SE_LOCAL" > "$TX/selinux.local"
 printf '%s\n' "$SE_EXPORT" > "$TX/selinux.export"
 printf '%s\n' "$SE_TARGET" > "$TX/selinux.target"
 printf '%s\n' "$SE_TARGET_LOCAL" > "$TX/selinux.target-local"
 printf '%s\n' "$SE_ACTIVE" > "$TX/selinux.active"
 printf '%s\n' "$SE_TARGET_ACTIVE" > "$TX/selinux.target-active"
}
se_labels() {
 [[ ${SE_MODE:-Disabled} != Disabled ]] || return 0
 os restorecon -RF "$STATE" || return
 local p
 while IFS= read -r p; do os matchpathcon -V "$p" || return; done < <(find "$STATE" -type f)
}
se_restore_context() {
 [[ -f $TX/selinux.meta ]] || return 0 # Backups without SELinux metadata need no context handling.
 local context; context=$(sed -n '4p' "$TX/selinux.meta")
 [[ -n $context ]] || return 0
 os chcon -- "$context" "$ROOT/etc/ssh/sshd_config" || return
 [[ $(os stat -c %C "$ROOT/etc/ssh/sshd_config") == "$context" ]] || { se_error 'SSH context restore failed'; return 1; }
}
se_expected_added() {
 [[ $SE_LEVEL == "$(sed -n '5p' "$TX/selinux.meta")" && $SE_TARGET_LOCAL == "tcp $PORT $PORT ssh_port_t $SE_LEVEL" ]] || { se_error 'new local context changed or missing'; return 1; }
 local without; without=$(awk -v p="$PORT" '!($2==p && $3==p && $4=="ssh_port_t")' <<< "$SE_TARGET")
 [[ $without == "$(cat "$TX/selinux.target")" ]] || { se_error 'target policy changed'; return 1; }
 local expected=system_u:object_r:ssh_port_t
 [[ $SE_LEVEL == none ]] || expected+=:s0
 grep -Fxq "tcp $PORT $PORT ssh_port_t $SE_LEVEL $expected" <<< "$SE_TARGET_ACTIVE" || { se_error 'active added context changed'; return 1; }
 if [[ $(sed -n '5p' "$TX/meta") =~ ^schema-[34]$ ]]; then
  without=$(awk -v p="$PORT" '!($2==p && $3==p && $4=="ssh_port_t")' <<< "$SE_TARGET_ACTIVE")
  [[ $without == "$(cat "$TX/selinux.target-active")" ]] || { se_error 'active base contexts changed'; return 1; }
 fi
}
se_original_target() {
 [[ $SE_TARGET == "$(cat "$TX/selinux.target")" && $SE_TARGET_LOCAL == "$(cat "$TX/selinux.target-local")" ]] || return 1
 [[ $(sed -n '5p' "$TX/meta") == schema-2 ]] || [[ $SE_TARGET_ACTIVE == "$(cat "$TX/selinux.target-active")" ]]
}
se_apply() {
 local saved_mode; saved_mode=$(sed -n '1p' "$TX/selinux.meta")
 se_mode || return
 [[ $SE_MODE == "$saved_mode" ]] || { se_error 'enforcement mode changed'; return 1; }
 [[ $SE_MODE != Disabled ]] || return 0
 se_read || return
 [[ $SE_LEVEL == "$(sed -n '5p' "$TX/selinux.meta")" ]] && se_original_target || { se_error 'policy changed since preflight'; return 1; }
 [[ $(sed -n '2p' "$TX/selinux.meta") == add ]] || return 0
 # The digest-bound intent is durable BEFORE semanage: a failed command may
 # have committed; retain the exact intent in the backup for inspection.
 sha256sum "$TX/selinux.meta" | cut -d ' ' -f 1 > "$TX/selinux.intent.new"
 sync -f "$TX/selinux.intent.new"
 mv -- "$TX/selinux.intent.new" "$TX/selinux.intent"
 sync -f "$TX"
 os semanage port -a -t ssh_port_t -p tcp -r s0 "$PORT" || return
 se_read && se_expected_added
}
se_verify() {
 [[ -f $TX/selinux.meta ]] || return 0
 PORT=$(sed -n '3p' "$TX/selinux.meta")
 se_mode || return
 [[ $SE_MODE == "$(sed -n '1p' "$TX/selinux.meta")" ]] || { se_error 'enforcement mode changed'; return 1; }
 [[ $SE_MODE != Disabled ]] || return 0
 se_read || return
 [[ $SE_LEVEL == "$(sed -n '5p' "$TX/selinux.meta")" ]] || { se_error 'kernel MLS mode changed'; return 1; }
 if [[ $(sed -n '2p' "$TX/selinux.meta") == add ]]; then se_expected_added
 else se_original_target || { se_error 'reused authorization changed'; return 1; }; fi
}
