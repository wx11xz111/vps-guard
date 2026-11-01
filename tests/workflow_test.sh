#!/usr/bin/env bash
# Sourced by guard_test.sh: lifecycle and SSH/Fail2ban integration contracts.
for backend in ufw firewalld iptables nftables; do
 reset_fixture "$backend"
 run apply firewall-allow --port 8443 --apply >/dev/null
 saved=$(sha256sum "$(persistent_file "$backend")")
 run plan firewall-disable > "$work/stop-plan"
 [[ $saved == "$(sha256sum "$(persistent_file "$backend")")" ]]
 run apply firewall-disable --apply >/dev/null
 [[ $saved == "$(sha256sum "$(persistent_file "$backend")")" ]]
 [[ $(cat "$GUARD_TEST_ROOT/var/lib/server-guard/firewall.backend") == "$backend" ]]
 run apply firewall-start --apply >/dev/null
 run ports > "$work/restarted-ports"
 grep -qx 'owned tcp 8443' "$work/restarted-ports"
 run apply firewall-restart --apply >/dev/null
 run ports > "$work/reloaded-ports"
 grep -qx 'owned tcp 8443' "$work/reloaded-ports"
 [[ $(cat "$(backup_dir)/result") == applied ]]
 no_recovery
 ok "$backend stop retains saved ports; start/reload restores them after preparing SSH protection"
done
reset_fixture ufw
run apply firewall-allow --port 8443 --apply >/dev/null
touch "$GUARD_TEST_ROOT/fixture/firewall-masked"
reject apply firewall-start --apply
reject apply firewall-restart --apply
run apply firewall-disable --apply >/dev/null
ok 'Administrative masks prevent start/reload; stopping retains configuration'
for backend in ufw firewalld nftables iptables; do
 reset_fixture "$backend"
 touch "$GUARD_TEST_ROOT/fixture/foreign-nft"
 run apply fail2ban-enable --maxretry 4 --findtime 900 --bantime 7200 --apply >/dev/null
 run apply firewall-allow --port 8443 --apply >/dev/null
 run apply ssh-port --port 2299 --apply >/dev/null
 jail=$GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local
 grep -qx 'port = 2022,2200,2222,2299' "$jail"
 grep -qx 'maxretry = 4' "$jail"
 grep -qx 'findtime = 900' "$jail"
 grep -qx 'bantime = 7200' "$jail"
 grep -q 'fail2ban-client <reload> <server-guard-sshd>' "$GUARD_TEST_ROOT/fixture/log"
 [[ -f $GUARD_TEST_ROOT/fixture/foreign-nft ]]
 ! grep -q '^flush ruleset$' "$(backup_dir)"/nft.apply 2>/dev/null
 ok "$backend port management and SSH synchronization coexist with the separate Fail2ban nft table"
done
reset_fixture ufw
touch "$GUARD_TEST_ROOT/fixture/unknown-nft"
reject apply firewall-allow --port 8443 --apply
[[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard ]]
ok 'Unrecognized extra nft tables remain rejected before writes'
for failure in port-occupied new-sshd-invalid; do
 reset_fixture ufw
 touch "$GUARD_TEST_ROOT/fixture/$failure"
 before=$(sha256sum "$GUARD_TEST_ROOT/etc/ssh/sshd_config" "$GUARD_TEST_ROOT/fixture/v4")
 reject apply ssh-port --port 2299 --apply
 [[ $before == "$(sha256sum "$GUARD_TEST_ROOT/etc/ssh/sshd_config" "$GUARD_TEST_ROOT/fixture/v4")" ]]
done
reset_fixture ufw
touch "$GUARD_TEST_ROOT/fixture/ssh-listener-missing"
reject apply ssh-port --port 2299 --apply
grep -q 'SSH新端口未监听' "$work/reject.log"
[[ $(cat "$(backup_dir)/result") == failed ]]
ok 'Occupied ports and invalid candidates reject early; missing SSH listeners cannot report success'
reset_fixture ufw
touch "$GUARD_TEST_ROOT/fixture/socket"
run plan ssh-port --port 2299 > "$work/socket-plan"
grep -q 'ssh.socket' "$work/socket-plan"
[[ -f $GUARD_TEST_ROOT/fixture/socket ]]
run apply ssh-port --port 2299 --apply >/dev/null
[[ ! -f $GUARD_TEST_ROOT/fixture/socket ]]
grep -q 'systemctl <disable> <--now> <ssh.socket>' "$GUARD_TEST_ROOT/fixture/log"
grep -q 'systemctl <restart> <ssh.service>' "$GUARD_TEST_ROOT/fixture/log"
for fault in ssh-kill-group ssh-send-hup ssh-service-masked; do
 reset_fixture ufw
 touch "$GUARD_TEST_ROOT/fixture/socket" "$GUARD_TEST_ROOT/fixture/$fault"
 reject apply ssh-port --port 2299 --apply
 ! grep -q '^MUTATE' "$GUARD_TEST_ROOT/fixture/log"
done
ok 'Socket activation migrates only with session-preserving KillMode and an unmasked SSH service'
reset_fixture ufw
run apply fail2ban-enable --apply >/dev/null
run apply fail2ban-whitelist --ip 198.51.100.9 --apply >/dev/null
run apply fail2ban-whitelist --ip 2001:db8::99 --apply >/dev/null
run apply fail2ban-enable --maxretry 8 --apply >/dev/null
run apply ssh-port --port 2299 --apply >/dev/null
jail=$GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local
grep -q '198.51.100.9' "$jail"; grep -q '2001:db8::99' "$jail"
grep -qx 'maxretry = 8' "$jail"
run apply fail2ban-unban --ip 198.51.100.7 --apply >/dev/null
grep -q 'fail2ban-client <set> <server-guard-sshd> <unbanip> <198.51.100.7>' "$GUARD_TEST_ROOT/fixture/log"
run apply fail2ban-restart --apply >/dev/null
SSH_CONNECTION='' run fail2ban-status > "$work/fail2ban-status"
grep -q 'Currently banned' "$work/fail2ban-status"
SSH_CONNECTION='' run fail2ban-logs > "$work/fail2ban-logs"
grep -q 'Ban 198.51.100.7' "$work/fail2ban-logs"
ok 'Persistent IPv4/IPv6 whitelist survives policy edits and SSH sync; status/logs/unban/restart work'
run apply fail2ban-disable --apply >/dev/null
run apply ssh-port --port 2399 --apply >/dev/null
grep -qx 'enabled = false' "$jail"
grep -q '2399' "$jail"
run apply fail2ban-enable --apply >/dev/null
echo 0 > "$GUARD_TEST_ROOT/fixture/services/fail2ban.active"
run apply ssh-port --port 2499 --apply >/dev/null
[[ $(cat "$GUARD_TEST_ROOT/fixture/services/fail2ban.active") == 0 ]]
grep -q '2499' "$jail"
ok 'SSH sync preserves disabled-jail and stopped-service states'
for value in '' 999.1.1.1 '1.2.3.4;id' '1:2' '2001:::1' '1.2.3.4/0'; do
 reject plan fail2ban-unban --ip "$value"
 reject plan fail2ban-whitelist --ip "$value"
done
reject fail2ban-status --apply
reject fail2ban-logs --port 22
ok 'Invalid IPs and mutation options on read-only queries are rejected'
reset_fixture ufw
printf '2\nN\n3\nN\n4\nN\n13\n1\n8\n0\n0\n' | run menu > "$work/lifecycle-menu"
grep -q '关闭防火墙（保留规则）' "$work/lifecycle-menu"
grep -q 'Fail2ban 防护管理' "$work/lifecycle-menu"
! grep -q '^MUTATE' "$GUARD_TEST_ROOT/fixture/log"
[[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard ]]
ok 'Lifecycle cancellation and Fail2ban navigation/query do not write configuration'

# Preserve administrator settings and report a protection-sync failure honestly.
reset_fixture ufw
run apply fail2ban-enable --apply >/dev/null
printf 'bantime.increment = true\n\n[custom-jail]\nenabled = false\nport = 443\n' >> "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local"
run apply ssh-port --port 2299 --apply >/dev/null
jail=$GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local
grep -qx 'bantime.increment = true' "$jail"
grep -qx '\[custom-jail\]' "$jail"
grep -qx 'port = 443' "$jail"
touch "$GUARD_TEST_ROOT/fixture/fail2ban-reload-fail"
reject apply ssh-port --port 2399 --apply
[[ $(cat "$(backup_dir)/result") == failed ]]
grep -q '2399' "$jail"
no_recovery
ok 'Unknown jail settings and other sections survive; Fail2ban sync failure cannot report SSH operation success'
reset_fixture ufw
run apply ssh-port --port 2299 --apply >/dev/null
before=$(sha256sum "$GUARD_TEST_ROOT/etc/ssh/sshd_config")
run apply ssh-port --port 2299 --apply >/dev/null
[[ $before == "$(sha256sum "$GUARD_TEST_ROOT/etc/ssh/sshd_config")" ]]
ok 'Repeating the same SSH port does not grow duplicate global Port directives'
