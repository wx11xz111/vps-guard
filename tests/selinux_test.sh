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
for mode in Enforcing Permissive; do
 reset_selinux
 echo "$mode" > "$GUARD_TEST_ROOT/fixture/selinux"
 run apply ssh-port --port 2299 --apply >/dev/null
 grep -qx 'ssh_port_t tcp 2299' "$GUARD_TEST_ROOT/fixture/se-local"
 grep -qx 'Port 2299' "$GUARD_TEST_ROOT/etc/ssh/sshd_config"
 [[ $(cat "$GUARD_TEST_ROOT/fixture/se-context") == system_u:object_r:sshd_config_t:s0 ]]
 [[ -f $(backup_dir)/selinux.intent && $(cat "$(backup_dir)/result") == applied ]]
 run apply ssh-port --port 2299 --apply >/dev/null
 [[ $(grep -c '^ssh_port_t tcp 2299$' "$GUARD_TEST_ROOT/fixture/se-local") == 1 ]]
 ! grep -q 'semanage <port> <-d>' "$GUARD_TEST_ROOT/fixture/log"
 no_recovery
 ok "$mode adds/validates SSH authorization immediately and reuses it without deletion or rollback jobs"
done
reset_selinux
printf 'http_port_t tcp 2299\n' >> "$GUARD_TEST_ROOT/fixture/se-local"
reject apply ssh-port --port 2299 --apply
! grep -q '^MUTATE' "$GUARD_TEST_ROOT/fixture/log"
for level in s1 s0:c1; do
 reset_selinux
 echo "$level" > "$GUARD_TEST_ROOT/fixture/se-base-range-1024-65535"
 reject apply ssh-port --port 2299 --apply
 ! grep -q '^MUTATE' "$GUARD_TEST_ROOT/fixture/log"
done
ok 'Foreign service ports and nondefault MLS/MCS context are still rejected'
reset_selinux
touch "$GUARD_TEST_ROOT/fixture/ssh-reload-fail"
reject apply ssh-port --port 2299 --apply
[[ $(cat "$(backup_dir)/result") == failed ]]
grep -qx 'ssh_port_t tcp 2299' "$GUARD_TEST_ROOT/fixture/se-local"
grep -qx 'Port 2299' "$GUARD_TEST_ROOT/etc/ssh/sshd_config"
! grep -q 'semanage <port> <-d>' "$GUARD_TEST_ROOT/fixture/log"
no_recovery
ok 'Failed SSH reload retains backup and current authorization without an automatic policy deletion'
