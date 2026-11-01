#!/usr/bin/env bash
# shellcheck disable=SC2154 # Sourced by guard_test.sh.
without_firewall() {
 local service
 for service in nftables netfilter-persistent iptables ip6tables ufw firewalld; do echo 0 > "$GUARD_TEST_ROOT/fixture/services/$service.active"; done
 : > "$GUARD_TEST_ROOT/fixture/v4"; : > "$GUARD_TEST_ROOT/fixture/v6"; : > "$GUARD_TEST_ROOT/fixture/nft"
}
for family in ubuntu rocky; do
 reset_fixture
 printf 'ID=%s\nVERSION_ID="%s"\n' "$family" "$([[ $family == ubuntu ]] && echo 24 || echo 9)" > "$GUARD_TEST_ROOT/etc/os-release"
 without_firewall
 before=$(sha256sum "$GUARD_TEST_ROOT/etc/iptables/rules.v4" "$GUARD_TEST_ROOT/etc/iptables/rules.v6")
 run apply fail2ban-enable --apply >/dev/null
 run apply fail2ban-disable --apply >/dev/null
 run apply fail2ban-enable --maxretry 4 --apply >/dev/null
 [[ $before == "$(sha256sum "$GUARD_TEST_ROOT/etc/iptables/rules.v4" "$GUARD_TEST_ROOT/etc/iptables/rules.v6")" ]]
 grep -qx 'maxretry = 4' "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local"
 [[ $(cat "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/user.local") == $'[other-jail]\nenabled=true' ]]
 no_recovery
 ok "$family Fail2ban enables/disables repeatedly without a firewall or a pending workflow"
done
original_adapter=$GUARD_TEST_ADAPTER
export GUARD_TEST_ADAPTER=$HERE/fail2ban_install_adapter.sh
missing_fail2ban() {
 reset_fixture; without_firewall
 touch "$GUARD_TEST_ROOT/fixture/missing-fail2ban-client"
 echo 0 > "$GUARD_TEST_ROOT/fixture/services/fail2ban.active"
 echo 0 > "$GUARD_TEST_ROOT/fixture/services/fail2ban.enabled"
}
for family in ubuntu rocky; do
 missing_fail2ban
 printf 'ID=%s\nVERSION_ID="%s"\n' "$family" "$([[ $family == ubuntu ]] && echo 24 || echo 9)" > "$GUARD_TEST_ROOT/etc/os-release"
 run plan fail2ban-enable > "$work/plan"
 [[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard && ! -f $GUARD_TEST_ROOT/fixture/install.log ]]
 reject apply fail2ban-enable
 printf '10\nN\n0\n' | run menu > "$work/cancel"
 [[ ! -f $GUARD_TEST_ROOT/fixture/install.log ]]
 printf '10\ny\n0\n' | run menu > "$work/install"
 grep -q '已生效' "$work/install"
 [[ ! -f $GUARD_TEST_ROOT/fixture/missing-fail2ban-client && ! -f $GUARD_TEST_ROOT/fixture/fail2ban-masked ]]
 [[ $(cat "$GUARD_TEST_ROOT/fixture/services/fail2ban.active") == 1 && $(cat "$GUARD_TEST_ROOT/fixture/services/fail2ban.enabled") == 1 ]]
 if [[ $family == ubuntu ]]; then grep -q 'apt-get <-y> <install> <fail2ban> <python3-systemd>' "$GUARD_TEST_ROOT/fixture/install.log"
 else grep -q 'dnf <-y> <install> <fail2ban-server> <python3-systemd>' "$GUARD_TEST_ROOT/fixture/install.log"; fi
 run apply fail2ban-enable --maxretry 8 --apply >/dev/null
 grep -qx 'maxretry = 8' "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local"
 no_recovery
 ok "$family missing dependency is installed after Y, then applies without another confirmation"
done
for failure in package-fail package-partial-fail admin-masked; do
 missing_fail2ban; touch "$GUARD_TEST_ROOT/fixture/$failure"
 reject apply fail2ban-enable --apply
 [[ ! -f $GUARD_TEST_ROOT/fixture/fail2ban-masked && ! -f $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
 [[ $(cat "$GUARD_TEST_ROOT/fixture/services/fail2ban.active") == 0 && $(cat "$GUARD_TEST_ROOT/fixture/services/fail2ban.enabled") == 0 ]]
 if [[ $failure == admin-masked ]]; then [[ ! -f $GUARD_TEST_ROOT/fixture/install.log ]]; fi
done
ok 'Installation failures clean temporary masks without starting the daemon'
reset_fixture
echo 0 > "$GUARD_TEST_ROOT/fixture/services/fail2ban.active"
echo 0 > "$GUARD_TEST_ROOT/fixture/services/fail2ban.enabled"
touch "$GUARD_TEST_ROOT/fixture/fail2ban-jail-fail"
reject apply fail2ban-enable --apply
grep -q 'SSH jail did not start' "$work/reject.log"
[[ $(cat "$(backup_dir)/result") == failed ]]
[[ -f $GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local && $(cat "$GUARD_TEST_ROOT/fixture/services/fail2ban.enabled") == 1 ]]
no_recovery
ok 'Jail readiness failure is reported and backed up without automatic rollback'
export GUARD_TEST_ADAPTER=$original_adapter
