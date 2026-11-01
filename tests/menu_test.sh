#!/usr/bin/env bash
# shellcheck disable=SC2154 # Sourced by guard_test.sh.
reset_fixture
printf '0\n' | run > "$work/menu-default"
grep -q '服务器保护菜单' "$work/menu-default"
! grep -q '14 确认变更\|15 手工回退\|13 恢复防火墙' "$work/menu-default"
if printf '0\n' | run menu --dry-run > "$work/menu-rejected" 2>&1; then exit 1; fi
if printf '0\n' | run menu --backend nftables > "$work/menu-rejected" 2>&1; then exit 1; fi
ok 'Menu omits removed recovery entries and rejects ignored command options'
reset_fixture
printf '5\n0\n' | run menu > "$work/menu-view"
grep -q 'SSH 保护端口' "$work/menu-view"
[[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard ]]
printf '5\n0\n' | run menu --lang en > "$work/menu-en"
grep -q 'Protected SSH port' "$work/menu-en"
! grep -q 'SSH 保护端口' "$work/menu-en"
for answer in n N ''; do
 reset_fixture
 printf '6\n8443\n%s\n0\n' "$answer" | run menu > "$work/cancel"
 [[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard ]]
done
ok 'Read-only labels and the pre-operation Y/N cancel behavior are retained'
reset_fixture
printf '6\n8443\nbad\nY\n6\n9443\ny\n0\n' | run menu > "$work/menu-add"
grep -q '请输入 Y 或 N' "$work/menu-add"
grep -q 8443 "$GUARD_TEST_ROOT/fixture/v4"; grep -q 9443 "$GUARD_TEST_ROOT/fixture/v4"
no_recovery
! grep -q 'pending /' "$work/menu-add"
ok 'Two menu changes apply immediately in the same session after their initial Y/N prompts'
reset_fixture
printf '12\n3\n600\n3600\nN\n0\n' | run menu > "$work/menu-policy"
[[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard ]]
printf '12\n\n\n\ny\n12\n6\n900\n7200\ny\n16\n0\n' | run menu > "$work/menu-policy-twice"
grep -qx 'maxretry = 6' "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local"
grep -qx 'bantime = 7200' "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local"
printf '12\n\n\n\ny\n0\n' | run menu > "$work/menu-policy-keep"
grep -qx 'maxretry = 6' "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local"
grep -qx 'findtime = 900' "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local"
grep -qx 'bantime = 7200' "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local"
grep -q 'status=applied integrity=ok' "$work/menu-policy-twice"
! grep -q 'one pending transaction' "$work/menu-policy-twice"
no_recovery
ok 'Repeated Fail2ban configuration no longer requires a new SSH session, confirmation ID or rollback'
printf '19\n20\n21\n0\n' | run menu > "$work/menu-removed"
[[ $(grep -c '选项无效' "$work/menu-removed") == 3 ]]
printf '14\n0\n' | run menu > "$work/menu-status"
grep -q '无需二次确认' "$work/menu-status"
grep -q '本工具 jail 运行中' "$work/menu-status"
reset_fixture ufw
printf '15\n0\n' | run menu > "$work/menu-rules"
grep -q '8080/tcp' "$work/menu-rules"
ok 'Status and native rules use the reordered menu; out-of-range legacy entries are rejected'
for choice in 1 2 3 4 10 11 17 18; do
 reset_fixture ufw
 printf '%s\nN\n0\n' "$choice" | run menu > "$work/reordered-cancel"
 grep -q '已取消' "$work/reordered-cancel"
 [[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard ]]
 ! grep -q '^MUTATE' "$GUARD_TEST_ROOT/fixture/log"
done
reset_fixture ufw
printf '9\n2299\nN\n13\n1\n8\n0\n0\n' | run menu > "$work/reordered-navigation"
grep -q 'Fail2ban 防护管理' "$work/reordered-navigation"
[[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard ]]
ok 'Reordered lifecycle, SSH and cleanup entries retain confirmation; Fail2ban navigation is read-only'
reset_fixture ufw
printf '6\n8443\ny\n7\n8443\n8543\ny\n8\n8543\ny\n9\n2299\ny\n0\n' | run menu > "$work/reordered-actions"
run ports > "$work/reordered-ports"
! grep -Eq '^owned tcp (8443|8543)$' "$work/reordered-ports"
grep -qx 'Port 2299' "$GUARD_TEST_ROOT/etc/ssh/sshd_config"
grep -qx 'protected-ssh tcp 2222' "$work/reordered-ports"
no_recovery
ok 'Menu 6/7/8 performs TCP add/edit/delete; menu 9 changes SSH while preserving its protected ports'
