#!/usr/bin/env bash
# shellcheck disable=SC2154 # Sourced by guard_test.sh.
reset_fixture
run plan firewall-allow --port 8443 > "$work/plan"
[[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard ]]
for port in 2222 2200 2022; do grep -q "$port" "$work/plan"; done
reject apply firewall-allow --port 8443
reject apply firewall-allow --port 99999 --apply
reject apply firewall-allow --port '22;id' --apply
SSH_CONNECTION='' reject apply firewall-allow --port 8443 --apply
GUARD_TEST_ROOT=/./ GUARD_TEST_ADAPTER=$HERE/adapter.sh reject status
GUARD_TEST_ROOT=// GUARD_TEST_ADAPTER=$HERE/adapter.sh reject status
reject confirm
reject rollback
reject apply firewall-restore --apply
reject plan firewall-allow --port 8443 --timeout 180
ok 'Preview, arguments, SSH context and removed workflow commands are checked without writes'
for backend in iptables nftables ufw firewalld; do
 reset_fixture "$backend"
 run apply firewall-allow --port 8443 --apply > "$work/apply"
 first=$(backup_of)
 grep -q '已生效' "$work/apply"
 [[ $(cat "$(backup_dir)/result") == applied ]]
 [[ $(stat -c %a "$GUARD_TEST_ROOT/var/lib/server-guard") == 700 ]]
 [[ $(stat -c %a "$(backup_dir)/meta") == 600 ]]
 run apply firewall-allow --port 9443 --apply > "$work/apply-second"
 [[ $(backup_of) != "$first" ]]
 grep -q 8443 "$(runtime_file "$backend")"; grep -q 9443 "$(runtime_file "$backend")"
 run backups > "$work/backups"
 grep -q 'status=applied integrity=ok' "$work/backups"
 no_recovery
 ! grep -Eq 'enable.*server-guard-(rollback|boot)' "$GUARD_TEST_ROOT/fixture/log"
 ok "$backend changes apply immediately, preserve previous ports, and retain verified backups without recovery jobs"
done
reset_fixture
printf '*raw\n:PREROUTING ACCEPT [0:0]\nCOMMIT\n' >> "$GUARD_TEST_ROOT/fixture/v4"
reject apply firewall-clear --scope all --apply
[[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard ]]
reset_fixture
mkdir -p "$GUARD_TEST_ROOT/var/lib/server-guard"; chmod 755 "$GUARD_TEST_ROOT/var/lib/server-guard"
reject status
ok 'Unsupported rule layouts and insecure state paths remain rejected'
reset_fixture
touch "$GUARD_TEST_ROOT/fixture/mutate-fail"
reject apply firewall-allow --port 8443 --apply
[[ $(cat "$(backup_dir)/result") == failed ]]
grep -q 8443 "$GUARD_TEST_ROOT/fixture/v4"
grep -q '未自动回退' "$work/reject.log"
no_recovery
run apply firewall-allow --port 9443 --apply >/dev/null
[[ $(cat "$(backup_dir)/result") == applied ]]
ok 'Partial failure records a backup and leaves current state; the next operation is not blocked'
reset_fixture
touch "$GUARD_TEST_ROOT/fixture/new-sshd-invalid"
before=$(sha256sum "$GUARD_TEST_ROOT/etc/ssh/sshd_config" "$GUARD_TEST_ROOT/fixture/v4")
reject apply ssh-port --port 2299 --apply
[[ $before == "$(sha256sum "$GUARD_TEST_ROOT/etc/ssh/sshd_config" "$GUARD_TEST_ROOT/fixture/v4")" ]]
ok 'Invalid SSH candidate is rejected before changing the configuration or firewall'
reset_fixture
run apply ssh-port --port 2299 --apply >/dev/null
grep -q '^Port 2299$' "$GUARD_TEST_ROOT/etc/ssh/sshd_config"
grep -q '^Port 2222$' "$GUARD_TEST_ROOT/etc/ssh/sshd_config"
no_recovery
run apply fail2ban-enable --apply >/dev/null
no_recovery
ok 'SSH and Fail2ban changes can run consecutively in the same SSH session'
reset_fixture
mkdir -p "$GUARD_TEST_ROOT/var/lib/server-guard/transactions"
chmod 700 "$GUARD_TEST_ROOT/var/lib/server-guard" "$GUARD_TEST_ROOT/var/lib/server-guard/transactions"
legacy=20261031000000-0123456789abcdef
echo "$legacy" > "$GUARD_TEST_ROOT/var/lib/server-guard/pending"
for unit in server-guard-rollback.timer server-guard-rollback.service server-guard-boot.service; do echo legacy > "$GUARD_TEST_ROOT/etc/systemd/system/$unit"; done
before=$(sha256sum "$GUARD_TEST_ROOT/fixture/v4" "$GUARD_TEST_ROOT/etc/ssh/sshd_config")
run status > "$work/status"
[[ -f $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
printf '0\n' | run menu > "$work/migrate"
[[ $before == "$(sha256sum "$GUARD_TEST_ROOT/fixture/v4" "$GUARD_TEST_ROOT/etc/ssh/sshd_config")" ]]
[[ ! -f $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
grep -q "$legacy" "$GUARD_TEST_ROOT"/var/lib/server-guard/legacy-pending.*
grep -q 'LEGACY disable --now server-guard-rollback.timer' "$GUARD_TEST_ROOT/fixture/log"
grep -q 'LEGACY stop server-guard-rollback.service' "$GUARD_TEST_ROOT/fixture/log"
grep -q 'LEGACY disable --now server-guard-boot.service' "$GUARD_TEST_ROOT/fixture/log"
! grep -q '^MUTATE' "$GUARD_TEST_ROOT/fixture/log"
run apply fail2ban-enable --apply >/dev/null
[[ $(cat "$(backup_dir)/result") == applied ]]
ok 'Legacy pending state is archived, old jobs are stopped, and current settings are retained'
reset_fixture
mkdir -p "$GUARD_TEST_ROOT/var/lib/server-guard"
chmod 700 "$GUARD_TEST_ROOT/var/lib/server-guard"
echo "$legacy" > "$GUARD_TEST_ROOT/var/lib/server-guard/pending"
echo legacy > "$GUARD_TEST_ROOT/etc/systemd/system/server-guard-rollback.timer"
touch "$GUARD_TEST_ROOT/fixture/legacy-disable-fail"
reject apply fail2ban-enable --apply
[[ -f $GUARD_TEST_ROOT/var/lib/server-guard/pending && ! -f $GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local ]]
ok 'Failed legacy job cancellation stops the new operation and retains the old record'
