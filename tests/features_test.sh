#!/usr/bin/env bash
# shellcheck disable=SC2154 # Sourced by guard_test.sh with fixture state.
for backend in ufw iptables nftables firewalld; do
 reset_fixture "$backend"
 touch "$GUARD_TEST_ROOT/fixture/missing-netfilter-persistent"
 # Inspection does not need restore commands, SSH discovery or safe-to-write rules.
 touch "$GUARD_TEST_ROOT/fixture/missing-iptables-restore" "$GUARD_TEST_ROOT/fixture/missing-ip6tables-restore" "$GUARD_TEST_ROOT/fixture/sshd-T"
 if [[ $backend == iptables ]]; then printf '*mangle\n:POSTROUTING ACCEPT [0:0]\nCOMMIT\n' >> "$GUARD_TEST_ROOT/fixture/v4"; fi
 SSH_CONNECTION='' run rules > "$work/rules"
 grep -qx "backend=$backend" "$work/rules"
 case $backend in
  ufw) grep -q '8080/tcp' "$work/rules"; grep -q '5353/udp (v6)' "$work/rules"; grep -q 'IPv6 runtime' "$work/rules";;
  iptables) grep -q '^\*mangle' "$work/rules"; grep -q 'IPv6' "$work/rules";;
  nftables) grep -q '^table inet filter' "$work/rules";;
  firewalld) grep -q '8080/tcp' "$work/rules"; grep -q '永久区域规则' "$work/rules";;
 esac
 ! grep -q '^MUTATE' "$GUARD_TEST_ROOT/fixture/log"
 [[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard ]]
done
ok 'Native firewall inspection shows external, UDP and IPv6 rules without mutation prerequisites or SSH'

reset_fixture ufw
echo 0 > "$GUARD_TEST_ROOT/fixture/ufw-active"
echo 0 > "$GUARD_TEST_ROOT/fixture/services/ufw.active"
run rules --backend ufw > "$work/rules"
grep -q 'Status: inactive' "$work/rules"
touch "$GUARD_TEST_ROOT/fixture/ufw-status-fail"
reject rules --backend ufw
grep -q 'cannot read firewall rules' "$work/reject.log"
reject rules --apply
reject backups --apply
reject backups --backend ufw
ok 'Inactive UFW can be explicitly inspected; query failures and mutation options are rejected'

reset_fixture
run plan fail2ban-enable --maxretry 4 --findtime 900 --bantime 7200 > "$work/plan"
grep -q 'maxretry=4 findtime=900 bantime=7200' "$work/plan"
[[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard ]]
run apply fail2ban-enable --maxretry 4 --findtime 900 --bantime 7200 --apply >/dev/null
grep -qx 'maxretry = 4' "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local"
grep -qx 'findtime = 900' "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local"
grep -qx 'bantime = 7200' "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local"
grep -q '2001:db8::20' "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local"
[[ $(cat "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/user.local") == $'[other-jail]\nenabled=true' ]]
saved=$(id_of)
SSH_CONNECTION='' run backups > "$work/backups"
grep -q "id=$saved .*status=pending integrity=ok" "$work/backups"
! grep -q '2001:db8' "$work/backups"
confirmed
run apply fail2ban-disable --apply >/dev/null
grep -qx 'maxretry = 4' "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local"
grep -qx 'bantime = 7200' "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local"
rollback
run apply fail2ban-enable --maxretry 6 --apply >/dev/null
grep -qx 'maxretry = 6' "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local"
grep -qx 'bantime = 7200' "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local"
rollback
run backups > "$work/backups"
grep -q "id=$saved .*status=confirmed integrity=ok" "$work/backups"
grep -q 'status=rolled-back integrity=ok' "$work/backups"
grep -qx 'maxretry = 4' "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local"
echo corrupt >> "$GUARD_TEST_ROOT/var/lib/server-guard/transactions/$saved/meta"
run backups > "$work/backups"
grep -qx "id=$saved integrity=invalid" "$work/backups"
! grep -q "id=$saved .*integrity=ok" "$work/backups"
ok 'Custom Fail2ban policy preserves management source and other jails; backup listing validates integrity and tracks rollback'

reset_fixture
for setting in '--maxretry 0' '--maxretry 101' '--findtime 604801' '--bantime 31536001' '--bantime -1' '--findtime 1h' '--maxretry 01' '--maxretry 999999999999999999999'; do
 read -r option value <<< "$setting"
 reject plan fail2ban-enable "$option" "$value"
done
reject plan fail2ban-enable --bantime ''
reject plan fail2ban-disable --maxretry 3
reject plan ssh-port --port 2299 --bantime 600
reject rules --bantime 600
[[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard ]]
ok 'Out-of-range, malformed and misplaced Fail2ban options are rejected before creating state'

reset_fixture
printf '17\n3\n600\n3600\nN\n0\n' | run menu > "$work/menu-policy"
grep -q 'maxretry=3 findtime=600 bantime=3600' "$work/menu-policy"
[[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard ]]
printf '17\n\n\n\ny\n0\n' | run menu > "$work/menu-policy"
grep -qx 'maxretry = 5' "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local"
grep -qx 'bantime = 3600' "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local"
rollback
printf '18\n0\n' | run menu > "$work/menu-backups"
grep -q 'integrity=ok' "$work/menu-backups"
reset_fixture ufw
printf '16\n0\n' | run menu > "$work/menu-rules"
grep -q '8080/tcp' "$work/menu-rules"
ok 'New menu entries inspect native rules/backups and preview/confirm a custom Fail2ban policy'
echo 'PASS: reference-inspired features suite complete'
