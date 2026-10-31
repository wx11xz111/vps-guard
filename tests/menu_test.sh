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
printf '2\n0\n' | run menu > "$work/menu-view"
grep -q 'SSH 保护端口' "$work/menu-view"
[[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard ]]
printf '2\n0\n' | run menu --lang en > "$work/menu-en"
grep -q 'Protected SSH port' "$work/menu-en"
! grep -q 'SSH 保护端口' "$work/menu-en"
for answer in n N ''; do
 reset_fixture
 printf '3\n8443\n%s\n0\n' "$answer" | run menu > "$work/cancel"
 [[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard ]]
done
ok 'Read-only labels and the pre-operation Y/N cancel behavior are retained'
reset_fixture
printf '3\n8443\nbad\nY\n3\n9443\ny\n0\n' | run menu > "$work/menu-add"
grep -q '请输入 Y 或 N' "$work/menu-add"
grep -q 8443 "$GUARD_TEST_ROOT/fixture/v4"; grep -q 9443 "$GUARD_TEST_ROOT/fixture/v4"
no_recovery
! grep -q 'pending /' "$work/menu-add"
ok 'Two menu changes apply immediately in the same session after their initial Y/N prompts'
reset_fixture
printf '17\n3\n600\n3600\nN\n0\n' | run menu > "$work/menu-policy"
[[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard ]]
printf '17\n\n\n\ny\n17\n6\n900\n7200\ny\n18\n0\n' | run menu > "$work/menu-policy-twice"
grep -qx 'maxretry = 6' "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local"
grep -qx 'bantime = 7200' "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local"
grep -q 'status=applied integrity=ok' "$work/menu-policy-twice"
! grep -q 'one pending transaction' "$work/menu-policy-twice"
no_recovery
ok 'Repeated Fail2ban configuration no longer requires a new SSH session, confirmation ID or rollback'
printf '14\n15\n0\n' | run menu > "$work/menu-removed"
grep -q '确认和回退菜单已取消' "$work/menu-removed"
printf '9\n0\n' | run menu > "$work/menu-status"
grep -q '无需二次确认' "$work/menu-status"
grep -q 'Fail2ban：服务运行中，本工具 jail 运行中' "$work/menu-status"
reset_fixture ufw
printf '16\n0\n' | run menu > "$work/menu-rules"
grep -q '8080/tcp' "$work/menu-rules"
ok 'Status, native rules and removed-option guidance remain available'
