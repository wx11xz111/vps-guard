#!/usr/bin/env bash
# Sourced by guard_test.sh: privileged commands always use the strict adapter.
# shellcheck disable=SC2154 # work and fixture helpers are supplied by guard_test.sh.
reset_selinux() {
 reset_fixture
 printf 'Enforcing\n' > "$GUARD_TEST_ROOT/fixture/selinux"
 mkdir -p "$GUARD_TEST_ROOT/sys/fs/selinux"
 echo 1 > "$GUARD_TEST_ROOT/sys/fs/selinux/mls"
 touch "$GUARD_TEST_ROOT/sys/fs/selinux/policy"
 printf 'ssh_port_t tcp 22, 2022, 2200, 2222\nunreserved_port_t tcp 1024-65535\nport_t tcp 1-65535\nhttp_port_t tcp 80, 443\n' > "$GUARD_TEST_ROOT/fixture/se-base"
 printf 'http_port_t udp 2299\nhttp_port_t tcp 8443\n' > "$GUARD_TEST_ROOT/fixture/se-local"
 cp "$GUARD_TEST_ROOT/fixture/se-local" "$work/se-local.original"
 printf 'system_u:object_r:sshd_config_t:s0\n' > "$GUARD_TEST_ROOT/fixture/se-context"
}
review_base_ranges() {
 local range kind
 for range in s1 s0:c1; do
  for kind in generic ssh; do
   reset_selinux
   if [[ $kind == generic ]]; then echo "$range" > "$GUARD_TEST_ROOT/fixture/se-base-range-1024-65535"
   else printf 'ssh_port_t tcp 2299\n' >> "$GUARD_TEST_ROOT/fixture/se-base"; echo "$range" > "$GUARD_TEST_ROOT/fixture/se-base-range-2299"; fi
   reject apply ssh-port --port 2299 --apply
   ! grep -q '^MUTATE' "$GUARD_TEST_ROOT/fixture/log"
  done
 done
 ok 'I1 base generic and SSH mappings with non-default MLS/MCS reject before writes'
}
review_config_labels() {
 local backend path saved before after
 for backend in iptables nftables ufw firewalld; do
  reset_selinux
  echo "$backend" > "$GUARD_TEST_ROOT/fixture/backend"
  for svc in netfilter-persistent nftables ufw firewalld; do echo 0 > "$GUARD_TEST_ROOT/fixture/services/$svc.active"; done
  svc=$backend; [[ $svc != iptables ]] || svc=netfilter-persistent
  echo 1 > "$GUARD_TEST_ROOT/fixture/services/$svc.active"
  : > "$GUARD_TEST_ROOT/fixture/config-labels"
  for path in etc/firewalld etc/firewalld/zones/public.xml etc/iptables/rules.v4 etc/ufw/before.rules etc/nftables.conf; do
   printf '%s|system_u:object_r:custom_config_t:s0:c1|%s\n' "$path" "$(stat -c %i "$GUARD_TEST_ROOT/$path")" >> "$GUARD_TEST_ROOT/fixture/config-labels"
  done
  cut -d'|' -f1,2 "$GUARD_TEST_ROOT/fixture/config-labels" > "$work/labels.original"
  before=$(stat -c %i "$GUARD_TEST_ROOT/etc/firewalld")
  run apply ssh-port --port 2299 --apply >/dev/null
  saved=$GUARD_TEST_ROOT/var/lib/server-guard/transactions/$(id_of)
  [[ -f $saved/config.tar.model-labels ]]
  rollback
  after=$(stat -c %i "$GUARD_TEST_ROOT/etc/firewalld")
  [[ $before != "$after" ]]
  cut -d'|' -f1,2 "$GUARD_TEST_ROOT/fixture/config-labels" > "$work/labels.restored"
  cmp "$work/labels.original" "$work/labels.restored"
  grep -q '^tar <--selinux> .* <-xf>' "$GUARD_TEST_ROOT/fixture/log"
 done
 ok 'I2 GNU tar SELinux save/restore flags preserve modeled custom directory/file contexts before all backend service starts'
 reset_selinux; touch "$GUARD_TEST_ROOT/fixture/tar-save-fail"
 reject apply ssh-port --port 2299 --apply
 ! grep -q '^MUTATE' "$GUARD_TEST_ROOT/fixture/log"
 reset_selinux; run apply ssh-port --port 2299 --apply >/dev/null
 touch "$GUARD_TEST_ROOT/fixture/tar-restore-fail"
 reject rollback --id "$(id_of)" --apply
 [[ -f $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
 ! grep -q '^semanage <port> <-d>' "$GUARD_TEST_ROOT/fixture/log"
 rm "$GUARD_TEST_ROOT/fixture/tar-restore-fail"; rollback
 ok 'Archive save failure writes no network state; restore failure retains pending and policy until retry'
}
schema2_snapshot() {
 local saved
 saved=$GUARD_TEST_ROOT/var/lib/server-guard/transactions/$(id_of)
 sed -i '5s/schema-3/schema-2/' "$saved/meta"
 rm "$saved/selinux.active" "$saved/selinux.target-active"
 (cd "$saved" && sha256sum meta family config.tar paths services selinux.meta selinux.full selinux.local selinux.export selinux.target selinux.target-local ipv4.runtime ipv6.runtime > checksums)
}
review_schema2_compat() {
 local transaction
 reset_selinux; run apply ssh-port --port 2299 --apply >/dev/null
 transaction=$(id_of); schema2_snapshot
 SSH_CONNECTION='2001:db8::20 45002 2001:db8::1 2299' run confirm --id "$transaction" --apply >/dev/null
 grep -qx 'ssh_port_t tcp 2299' "$GUARD_TEST_ROOT/fixture/se-local"
 reset_selinux; run apply ssh-port --port 2299 --apply >/dev/null
 schema2_snapshot; rollback
 cmp "$work/se-local.original" "$GUARD_TEST_ROOT/fixture/se-local"
 reset_selinux; run apply ssh-port --port 2299 --apply >/dev/null
 schema2_snapshot
 bash "$GUARD_TEST_ROOT/var/lib/server-guard/runner/server-guard.sh" recover --apply >/dev/null
 cmp "$work/se-local.original" "$GUARD_TEST_ROOT/fixture/se-local"
 [[ ! -f $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
 reset_selinux; run apply ssh-port --port 2299 --apply >/dev/null
 schema2_snapshot; touch "$GUARD_TEST_ROOT/fixture/se-delete-after-fail"
 reject rollback --id "$(id_of)" --apply
 cmp "$work/se-local.original" "$GUARD_TEST_ROOT/fixture/se-local"
 rm "$GUARD_TEST_ROOT/fixture/se-delete-after-fail"; rollback
 [[ ! -f $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
 reset_selinux; printf 'ssh_port_t tcp 2299\n' >> "$GUARD_TEST_ROOT/fixture/se-base"
 run apply ssh-port --port 2299 --apply >/dev/null
 transaction=$(id_of); schema2_snapshot
 SSH_CONNECTION='2001:db8::20 45002 2001:db8::1 2299' run confirm --id "$transaction" --apply >/dev/null
 cmp "$work/se-local.original" "$GUARD_TEST_ROOT/fixture/se-local"
 reset_selinux; printf 'ssh_port_t tcp 2299\n' >> "$GUARD_TEST_ROOT/fixture/se-base"
 run apply ssh-port --port 2299 --apply >/dev/null
 schema2_snapshot; rollback
 grep -qx 'ssh_port_t tcp 2299' "$GUARD_TEST_ROOT/fixture/se-base"
 cmp "$work/se-local.original" "$GUARD_TEST_ROOT/fixture/se-local"
 reset_selinux; run apply ssh-port --port 2299 --apply >/dev/null
 schema2_snapshot
 sed -i 's/ssh_port_t tcp 2299/http_port_t tcp 2299/' "$GUARD_TEST_ROOT/fixture/se-local"
 reject rollback --id "$(id_of)" --apply
 [[ -f $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
 grep -qx 'http_port_t tcp 2299' "$GUARD_TEST_ROOT/fixture/se-local"
 ! grep -q '^semanage <port> <-d>' "$GUARD_TEST_ROOT/fixture/log"
 ok 'Schema-2 add/reuse confirm, rollback, detached recover and deleted retry work; changed ownership is never deleted'
}
if [[ ${GUARD_TEST_FOCUS:-} == selinux-review-base ]]; then review_base_ranges; exit; fi
if [[ ${GUARD_TEST_FOCUS:-} == selinux-review-labels ]]; then review_config_labels; exit; fi
if [[ ${GUARD_TEST_FOCUS:-} == selinux-schema2 ]]; then review_schema2_compat; exit; fi
review_base_ranges
review_config_labels
review_schema2_compat
reset_selinux
run apply ssh-port --port 2299 --apply > "$work/apply"
transaction=$(id_of)
grep -qx 'ssh_port_t tcp 2299' "$GUARD_TEST_ROOT/fixture/se-local"
grep -q '^Port 2222$' "$GUARD_TEST_ROOT/etc/ssh/sshd_config"
SSH_CONNECTION='2001:db8::20 45002 2001:db8::1 2299' run confirm --id "$transaction" --apply
grep -qx 'ssh_port_t tcp 2299' "$GUARD_TEST_ROOT/fixture/se-local"
ok 'Enforcing new SSH port becomes pending and confirmed authorization survives'
reset_selinux
echo 0 > "$GUARD_TEST_ROOT/sys/fs/selinux/mls"
printf 'system_u:object_r:sshd_config_t\n' > "$GUARD_TEST_ROOT/fixture/se-context"
run apply ssh-port --port 2299 --apply >/dev/null; rollback
cmp "$work/se-local.original" "$GUARD_TEST_ROOT/fixture/se-local"
ok 'Non-MLS policy preserves its three-component SSH file context'
for family in ubuntu rocky; do
 for mode in Enforcing Permissive; do
  reset_selinux
  printf 'ID=%s\nVERSION_ID="24"\n' "$family" > "$GUARD_TEST_ROOT/etc/os-release"
  echo "$mode" > "$GUARD_TEST_ROOT/fixture/selinux"
  run plan ssh-port --port 2299 > "$work/plan"
  [[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard ]]
  ! grep -q '^MUTATE' "$GUARD_TEST_ROOT/fixture/log"
  run apply ssh-port --port 2299 --apply >/dev/null
  transaction=$(id_of)
  saved=$GUARD_TEST_ROOT/var/lib/server-guard/transactions/$transaction
  [[ -f $saved/selinux.intent && $(stat -c %a "$saved/selinux.meta") == 600 ]]
  grep -q 'selinux.meta$' "$saved/checksums"
  add_line=$(grep -n '^semanage <port> <-a>' "$GUARD_TEST_ROOT/fixture/log" | head -n1 | cut -d: -f1)
  reload_line=$(grep -n '^systemctl <reload> <ssh>' "$GUARD_TEST_ROOT/fixture/log" | head -n1 | cut -d: -f1)
  ((add_line<reload_line))
  reject confirm --id "$transaction" --apply
  SSH_CONNECTION='2001:db8::20 45002 2001:db8::1 2222' reject confirm --id "$transaction" --apply
  bash "$GUARD_TEST_ROOT/var/lib/server-guard/runner/server-guard.sh" recover --apply >/dev/null
  cmp "$work/se-local.original" "$GUARD_TEST_ROOT/fixture/se-local"
  ! grep -q '^Port 2299$' "$GUARD_TEST_ROOT/etc/ssh/sshd_config"
  [[ $(cat "$GUARD_TEST_ROOT/fixture/se-context") == system_u:object_r:sshd_config_t:s0 ]]
  delete_line=$(grep -n '^semanage <port> <-d>' "$GUARD_TEST_ROOT/fixture/log" | head -n1 | cut -d: -f1)
  reload_line=$(grep -n '^systemctl <reload> <ssh>' "$GUARD_TEST_ROOT/fixture/log" | tail -n1 | cut -d: -f1)
  ((reload_line<delete_line))
 done
done
ok 'Debian/RHEL Enforcing/Permissive: read-only preview, durable runner, authorization/reload/delete order, labels and exact recovery'
for source in se-base se-local; do
 for ports in 2299 2290-2300; do
  reset_selinux
  printf 'ssh_port_t tcp %s\n' "$ports" >> "$GUARD_TEST_ROOT/fixture/$source"
  cp "$GUARD_TEST_ROOT/fixture/se-local" "$work/reuse.original"
  run apply ssh-port --port 2299 --apply >/dev/null
  rollback
  cmp "$work/reuse.original" "$GUARD_TEST_ROOT/fixture/se-local"
  ! grep -Eq '^semanage <port> <-(a|d)>' "$GUARD_TEST_ROOT/fixture/log"
  reset_selinux
  printf 'http_port_t tcp %s\n' "$ports" >> "$GUARD_TEST_ROOT/fixture/$source"
  reject apply ssh-port --port 2299 --apply
  ! grep -q '^MUTATE' "$GUARD_TEST_ROOT/fixture/log"
 done
done
ok 'Existing base/local SSH singletons/ranges reused; other-service singletons/ranges refused'
for fault in getenforce-fail missing-semanage missing-seinfo missing-restorecon missing-matchpathcon missing-chcon se-query-fail se-local-fail se-export-fail se-active-fail context-read-fail; do
 reset_selinux; touch "$GUARD_TEST_ROOT/fixture/$fault"
 reject apply ssh-port --port 2299 --apply
 ! grep -q '^MUTATE' "$GUARD_TEST_ROOT/fixture/log"
done
for invalid in 'portcon tcp 2299 system_u:object_r:ssh_port_t:s0 extra' 'Portcon: 40' 'portcon tcp 2299 system_u:object_r:ssh_port_t:s0:c1;id'; do
 reset_selinux; echo "$invalid" > "$GUARD_TEST_ROOT/fixture/se-active-invalid"
 reject apply ssh-port --port 2299 --apply
 ! grep -q '^MUTATE' "$GUARD_TEST_ROOT/fixture/log"
done
for invalid in 'ssh_port_t tcp 2299,' 'ssh_port_t tcp 2300-2299' 'ssh_port_t tcp 65536' 'ssh_port_t tcp 2299 2300' 'ssh_port_t tcp 2299 s0'; do
 reset_selinux; printf '%s\n' "$invalid" > "$GUARD_TEST_ROOT/fixture/se-invalid"
 reject apply ssh-port --port 2299 --apply
 ! grep -q '^MUTATE' "$GUARD_TEST_ROOT/fixture/log"
done
reset_selinux
printf 'ssh_port_t tcp 2290-2300\nssh_port_t tcp 2299\n' >> "$GUARD_TEST_ROOT/fixture/se-base"
reject apply ssh-port --port 2299 --apply
reset_selinux
printf 'unreserved_port_t tcp 1024-65535\n' >> "$GUARD_TEST_ROOT/fixture/se-local"
reject apply ssh-port --port 2299 --apply
reset_selinux
printf 'ssh_port_t tcp 2299\n' >> "$GUARD_TEST_ROOT/fixture/se-local"
printf 's0:c1\n' > "$GUARD_TEST_ROOT/fixture/se-range-2299"
reject apply ssh-port --port 2299 --apply
ok 'Missing/failing tools, malformed/ambiguous policy, local generic overrides and non-s0 local contexts fail closed'
reset_selinux
rm "$GUARD_TEST_ROOT/sys/fs/selinux/mls"
reject apply ssh-port --port 2299 --apply
! grep -q '^MUTATE' "$GUARD_TEST_ROOT/fixture/log"
reset_selinux; run apply ssh-port --port 2299 --apply >/dev/null
echo 0 > "$GUARD_TEST_ROOT/sys/fs/selinux/mls"
reject rollback --id "$(id_of)" --apply
grep -qx 'ssh_port_t tcp 2299' "$GUARD_TEST_ROOT/fixture/se-local"
ok 'Non-MLS policies use range-free ownership; missing/changed kernel MLS mode fails closed'
reset_fixture
touch "$GUARD_TEST_ROOT/fixture/missing-semanage"
run apply ssh-port --port 2299 --apply >/dev/null; rollback
reset_fixture
touch "$GUARD_TEST_ROOT/fixture/missing-getenforce"
mkdir -p "$GUARD_TEST_ROOT/proc/self"
printf 'nodev tmpfs\n' > "$GUARD_TEST_ROOT/proc/filesystems"
: > "$GUARD_TEST_ROOT/proc/self/mountinfo"
run apply ssh-port --port 2299 --apply >/dev/null; rollback
printf 'nodev selinuxfs\n' >> "$GUARD_TEST_ROOT/proc/filesystems"
reject apply ssh-port --port 2299 --apply
ok 'Disabled needs no semanage; absent getenforce requires live-kernel evidence of inactivity'
for fault in timer-fail labels-fail labels-verify-fail; do
 reset_selinux; touch "$GUARD_TEST_ROOT/fixture/$fault"
 reject apply ssh-port --port 2299 --apply
 cmp "$work/se-local.original" "$GUARD_TEST_ROOT/fixture/se-local"
 ! grep -q '^semanage <port> <-a>' "$GUARD_TEST_ROOT/fixture/log"
done
for fault in se-add-before-fail se-add-after-fail new-sshd-invalid ssh-reload-fail; do
 reset_selinux; touch "$GUARD_TEST_ROOT/fixture/$fault"
 reject apply ssh-port --port 2299 --apply
 cmp "$work/se-local.original" "$GUARD_TEST_ROOT/fixture/se-local"
 [[ ! -f $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
 ! grep -q '^Port 2299$' "$GUARD_TEST_ROOT/etc/ssh/sshd_config"
done
ok 'Timer/labels failure writes no policy; failures before/after add and SSH validation/reload compensate'
reset_selinux; touch "$GUARD_TEST_ROOT/fixture/se-before-apply-conflict"
reject apply ssh-port --port 2299 --apply
grep -qx 'http_port_t tcp 2299' "$GUARD_TEST_ROOT/fixture/se-local"
! grep -Eq '^semanage <port> <-(a|d)>' "$GUARD_TEST_ROOT/fixture/log"
reset_selinux; run apply ssh-port --port 2299 --apply >/dev/null
printf 'http_port_t tcp 9443\n' >> "$GUARD_TEST_ROOT/fixture/se-local"
rollback
grep -qx 'http_port_t tcp 9443' "$GUARD_TEST_ROOT/fixture/se-local"
! grep -qx 'ssh_port_t tcp 2299' "$GUARD_TEST_ROOT/fixture/se-local"
ok 'Apply rechecks preflight policy; recovery preserves unrelated external policy changes'
for fault in se-after-query-fail se-add-wrong context-write-fail; do
 reset_selinux; touch "$GUARD_TEST_ROOT/fixture/$fault"
 reject apply ssh-port --port 2299 --apply
 [[ -f $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
 rm -f "$GUARD_TEST_ROOT/fixture/$fault" "$GUARD_TEST_ROOT/fixture/se-query-fail"
 sed -i 's/http_port_t tcp 2299/ssh_port_t tcp 2299/' "$GUARD_TEST_ROOT/fixture/se-local"
 rollback
 cmp "$work/se-local.original" "$GUARD_TEST_ROOT/fixture/se-local"
done
for fault in se-delete-fail se-delete-after-fail; do
 reset_selinux; run apply ssh-port --port 2299 --apply >/dev/null
 touch "$GUARD_TEST_ROOT/fixture/$fault"
 reject rollback --id "$(id_of)" --apply
 [[ -f $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
 rm "$GUARD_TEST_ROOT/fixture/$fault"
 rollback
 cmp "$work/se-local.original" "$GUARD_TEST_ROOT/fixture/se-local"
 run recover --apply >/dev/null
done
ok 'Read-back, context and deletion failures retain pending; committed-delete retry and repeated recovery are idempotent'
for conflict in type range mls; do
 reset_selinux; run apply ssh-port --port 2299 --apply >/dev/null
 case $conflict in
  type) sed -i 's/ssh_port_t tcp 2299/http_port_t tcp 2299/' "$GUARD_TEST_ROOT/fixture/se-local";;
  range) sed -i 's/ssh_port_t tcp 2299/ssh_port_t tcp 2290-2300/' "$GUARD_TEST_ROOT/fixture/se-local";;
  mls) echo s0:c1 > "$GUARD_TEST_ROOT/fixture/se-range-2299";;
 esac
 cp "$GUARD_TEST_ROOT/fixture/se-local" "$work/conflict.original"
 SSH_CONNECTION='2001:db8::20 45002 2001:db8::1 2299' reject confirm --id "$(id_of)" --apply
 reject rollback --id "$(id_of)" --apply
 cmp "$work/conflict.original" "$GUARD_TEST_ROOT/fixture/se-local"
 [[ -f $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
 ! grep -q '^semanage <port> <-d>' "$GUARD_TEST_ROOT/fixture/log"
done
ok 'External type/range/MLS changes block confirm/delete without overwriting policy'
reset_selinux; run apply ssh-port --port 2299 --apply >/dev/null
saved=$GUARD_TEST_ROOT/var/lib/server-guard/transactions/$(id_of)
printf 'tamper\n' >> "$saved/selinux.export"
reject rollback --id "$(id_of)" --apply
grep -qx 'ssh_port_t tcp 2299' "$GUARD_TEST_ROOT/fixture/se-local"
reset_selinux; run apply ssh-port --port 2299 --apply >/dev/null
saved=$GUARD_TEST_ROOT/var/lib/server-guard/transactions/$(id_of)
sed -i '5d' "$saved/meta"
rm "$saved"/selinux.*
(cd "$saved" || exit; sha256sum meta family config.tar paths services ipv4.runtime ipv6.runtime > checksums)
rollback
grep -qx 'ssh_port_t tcp 2299' "$GUARD_TEST_ROOT/fixture/se-local"
ok 'Snapshot tampering refused; legacy transactions never acquire SELinux ownership'
echo 'PASS: SELinux transaction suite complete (controlled model; no Enforcing kernel claim)'
