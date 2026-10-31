#!/usr/bin/env bash
# shellcheck disable=SC2154 # Sourced by guard_test.sh with fixture state.
without_firewall() {
 local service
 for service in nftables netfilter-persistent iptables ip6tables ufw firewalld; do
  printf '0\n' > "$GUARD_TEST_ROOT/fixture/services/$service.active"
 done
 : > "$GUARD_TEST_ROOT/fixture/v4"
 : > "$GUARD_TEST_ROOT/fixture/v6"
 : > "$GUARD_TEST_ROOT/fixture/nft"
}

for family in ubuntu rocky; do
 reset_fixture
 printf 'ID=%s\nVERSION_ID="%s"\n' "$family" "$([[ $family == ubuntu ]] && echo 24 || echo 9)" > "$GUARD_TEST_ROOT/etc/os-release"
 without_firewall
 original_rules=$(sha256sum "$GUARD_TEST_ROOT/etc/iptables/rules.v4" "$GUARD_TEST_ROOT/etc/iptables/rules.v6")
 run plan fail2ban-enable > "$work/fail2ban-plan"
 [[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard ]]
 run apply fail2ban-enable --apply > "$work/fail2ban-apply"
 [[ $(sed -n '2p' "$GUARD_TEST_ROOT/var/lib/server-guard/transactions/$(id_of)/meta") == none ]]
 grep -q 'enabled = true' "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local"
 [[ $original_rules == "$(sha256sum "$GUARD_TEST_ROOT/etc/iptables/rules.v4" "$GUARD_TEST_ROOT/etc/iptables/rules.v6")" ]]
 rollback
 [[ ! -e $GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local ]]
 [[ $original_rules == "$(sha256sum "$GUARD_TEST_ROOT/etc/iptables/rules.v4" "$GUARD_TEST_ROOT/etc/iptables/rules.v6")" ]]
 ok "$family Fail2ban enables and rolls back without a firewall manager"
done

reset_fixture
without_firewall
printf '[server-guard-sshd]\nenabled = false\n' > "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local"
run apply fail2ban-enable --apply >/dev/null
rollback
grep -q 'enabled = false' "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local"
[[ $(cat "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/user.local") == $'[other-jail]\nenabled=true' ]]
run apply fail2ban-disable --apply >/dev/null
rollback
grep -q 'enabled = false' "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local"
ok 'Rollback restores only this tool jail while preserving other Fail2ban jails'

reset_fixture
without_firewall
run apply fail2ban-enable --apply >/dev/null
env -u SSH_CONNECTION bash "$GUARD_TEST_ROOT/var/lib/server-guard/runner/server-guard.sh" recover --apply >/dev/null
[[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
[[ ! -e $GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local ]]
ok 'Detached recovery restores Fail2ban without a firewall manager or SSH session'

reset_fixture
without_firewall
printf '7\ny\n0\n' | run menu > "$work/fail2ban-menu"
grep -q 'pending / 待确认' "$work/fail2ban-menu"
rollback
ok 'Chinese menu enables Fail2ban without a firewall manager'

reset_fixture
without_firewall
if run plan firewall-allow --port 8443 > "$work/firewall-guidance" 2>&1; then echo 'FAIL: firewall action accepted without manager'; exit 1; fi
grep -q 'SSH' "$work/firewall-guidance"
grep -q 'firewalld' "$work/firewall-guidance"
grep -q '2222/tcp' "$work/firewall-guidance"
grep -q '菜单7/8无需防火墙' "$work/firewall-guidance"
ok 'Firewall actions explain how to prepare a supported manager and preserve SSH'

original_adapter=$GUARD_TEST_ADAPTER
export GUARD_TEST_ADAPTER=$HERE/fail2ban_install_adapter.sh
missing_fail2ban() {
 reset_fixture
 without_firewall
 touch "$GUARD_TEST_ROOT/fixture/missing-fail2ban-client"
 echo 0 > "$GUARD_TEST_ROOT/fixture/services/fail2ban.active"
 echo 0 > "$GUARD_TEST_ROOT/fixture/services/fail2ban.enabled"
}
for family in ubuntu rocky; do
 missing_fail2ban
 printf 'ID=%s\nVERSION_ID="%s"\n' "$family" "$([[ $family == ubuntu ]] && echo 24 || echo 9)" > "$GUARD_TEST_ROOT/etc/os-release"
 run plan fail2ban-enable > "$work/install-plan"
 grep -q '确认后将安装' "$work/install-plan"
 [[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard && ! -f $GUARD_TEST_ROOT/fixture/install.log ]]
 run apply fail2ban-enable --dry-run > "$work/install-dry"
 reject apply fail2ban-enable
 printf '7\nN\n0\n' | run menu > "$work/install-cancel"
 [[ ! -f $GUARD_TEST_ROOT/fixture/install.log ]]
 printf '7\ny\n0\n' | run menu > "$work/install-menu"
 grep -q 'pending / 待确认' "$work/install-menu"
 if [[ $family == ubuntu ]]; then grep -q 'apt-get <-y> <install> <fail2ban> <python3-systemd>' "$GUARD_TEST_ROOT/fixture/install.log"
 else grep -q 'dnf <-y> <install> <fail2ban-server> <python3-systemd>' "$GUARD_TEST_ROOT/fixture/install.log"; fi
 [[ ! -f $GUARD_TEST_ROOT/fixture/fail2ban-masked && ! -f $GUARD_TEST_ROOT/fixture/missing-fail2ban-client ]]
 [[ $(cat "$GUARD_TEST_ROOT/fixture/services/fail2ban.active") == 1 && $(cat "$GUARD_TEST_ROOT/fixture/services/fail2ban.enabled") == 1 ]]
 grep -q 'fail2ban-client <status> <server-guard-sshd>' "$GUARD_TEST_ROOT/fixture/log"
 rollback
 [[ $(cat "$GUARD_TEST_ROOT/fixture/services/fail2ban.active") == 0 && $(cat "$GUARD_TEST_ROOT/fixture/services/fail2ban.enabled") == 0 ]]
 [[ ! -e $GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local && ! -f $GUARD_TEST_ROOT/fixture/missing-fail2ban-client ]]
 ok "$family menu installs missing Fail2ban only after Y, then validates/arms/enables; rollback keeps package but restores inactive state"
done
for failure in package-fail package-partial-fail admin-masked; do
 missing_fail2ban
 touch "$GUARD_TEST_ROOT/fixture/$failure"
 reject apply fail2ban-enable --apply
 [[ ! -f $GUARD_TEST_ROOT/fixture/fail2ban-masked && ! -f $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
 [[ $(cat "$GUARD_TEST_ROOT/fixture/services/fail2ban.active") == 0 && $(cat "$GUARD_TEST_ROOT/fixture/services/fail2ban.enabled") == 0 ]]
 ! grep -q '^MUTATE' "$GUARD_TEST_ROOT/fixture/log"
 if [[ $failure == admin-masked ]]; then [[ ! -f $GUARD_TEST_ROOT/fixture/install.log ]]; fi
done
ok 'Package and partial-install failures remove temporary masks without starting services; administrator masks are respected'
missing_fail2ban
mkdir -p "$GUARD_TEST_ROOT/var/lib/server-guard"
chmod 700 "$GUARD_TEST_ROOT/var/lib/server-guard"
echo 20261031000000-0123456789abcdef > "$GUARD_TEST_ROOT/var/lib/server-guard/pending"
reject apply fail2ban-enable --apply
[[ ! -f $GUARD_TEST_ROOT/fixture/install.log ]]
ok 'A pending transaction prevents package installation'
reset_fixture
echo 0 > "$GUARD_TEST_ROOT/fixture/services/fail2ban.active"
echo 0 > "$GUARD_TEST_ROOT/fixture/services/fail2ban.enabled"
touch "$GUARD_TEST_ROOT/fixture/fail2ban-jail-fail"
reject apply fail2ban-enable --apply
grep -q 'SSH jail did not start' "$work/reject.log"
[[ ! -f $GUARD_TEST_ROOT/var/lib/server-guard/pending && $(cat "$GUARD_TEST_ROOT/fixture/services/fail2ban.active") == 0 && $(cat "$GUARD_TEST_ROOT/fixture/services/fail2ban.enabled") == 0 ]]
ok 'A jail that never becomes ready triggers transaction rollback'
export GUARD_TEST_ADAPTER=$original_adapter
echo 'PASS: independent Fail2ban suite complete'
