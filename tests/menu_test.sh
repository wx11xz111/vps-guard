#!/usr/bin/env bash
# shellcheck disable=SC2154 # Sourced by guard_test.sh with fixture functions.
reset_fixture
printf '0\n' | run > "$work/menu-default"
grep -q '服务器保护菜单' "$work/menu-default"
ok 'Single-command entry opens Chinese menu by default'

reset_fixture
if printf '2\n8443\n确认\n0\n' | run menu --dry-run > "$work/menu-unsafe" 2>&1; then
 echo 'FAIL: --dry-run unexpectedly entered mutable menu'; exit 1
fi
[[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
ok 'Menu rejects dry-run and does not mutate'
if printf '0\n' | run menu --backend nftables > "$work/menu-ignored-option" 2>&1; then
 echo 'FAIL: menu silently ignored requested backend'; exit 1
fi
if printf '0\n' | run menu --scope owned > "$work/menu-default-scope" 2>&1; then
 echo 'FAIL: menu accepted ignored explicit scope'; exit 1
fi
if printf '0\n' | run menu --timeout 180 > "$work/menu-default-timeout" 2>&1; then
 echo 'FAIL: menu accepted ignored explicit timeout'; exit 1
fi

reset_fixture
printf '1\n0\n' | run menu > "$work/menu-view"
grep -q '服务器保护菜单' "$work/menu-view"
grep -q 'SSH 保护端口' "$work/menu-view"
grep -q '2222' "$work/menu-view"
[[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard ]]
ok 'Chinese menu lists protected and owned ports without mutation'
printf '1\n0\n' | run menu --lang en > "$work/menu-en"
grep -q 'Protected SSH port' "$work/menu-en"
! grep -q 'SSH 保护端口' "$work/menu-en"
ok 'English menu shows English port labels'

reset_fixture
printf '2\n8443\n取消\n0\n' | run menu > "$work/menu-cancel"
[[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
ok 'Chinese menu previews and cancel leaves no transaction'

reset_fixture
printf '2\n8443\n确认\n0\n' | run menu > "$work/menu-add"
grep -q 'pending / 待确认' "$work/menu-add"
grep -q '8443' "$GUARD_TEST_ROOT/fixture/v4"
rollback
ok 'Chinese menu add delegates to guarded transaction'

reset_fixture
run apply firewall-allow --port 8443 --apply >/dev/null
SSH_CONNECTION='2001:db8::20 45002 2001:db8::1 2222' run confirm --id "$(id_of)" --apply >/dev/null
printf '3\n8443\n8543\n确认\n0\n' | run menu > "$work/menu-edit"
grep -q '8543' "$GUARD_TEST_ROOT/fixture/v4"
! grep -q '8443' "$GUARD_TEST_ROOT/fixture/v4"
rollback
ok 'Chinese menu edit replaces owned port and can roll back'

reset_fixture
run apply firewall-allow --port 8443 --apply >/dev/null
SSH_CONNECTION='2001:db8::20 45002 2001:db8::1 2222' run confirm --id "$(id_of)" --apply >/dev/null
printf '4\n8443\n确认\n0\n' | run menu > "$work/menu-delete"
! grep -q '8443' "$GUARD_TEST_ROOT/fixture/v4"
rollback
ok 'Chinese menu deletes only owned port and can roll back'

reset_fixture
printf '10\n0\n' | run menu > "$work/menu-fail2ban"
grep -q 'Fail2ban' "$work/menu-fail2ban"
ok 'Fail2ban appears in same Chinese menu'

reset_fixture
printf '6\n0\n' | run menu > "$work/menu-status"
grep -q 'Fail2ban：服务运行中，本工具 jail 未启用' "$work/menu-status"
ok 'Chinese menu distinguishes Fail2ban service from this tool jail'

reset_fixture
run apply firewall-allow --port 8443 --apply >/dev/null
pending_id=$(id_of)
printf '14\n\n0\n' | run menu > "$work/menu-rollback-empty"
[[ $(id_of) == "$pending_id" ]]
printf '14\n%s\n取消\n0\n' "$pending_id" | run menu > "$work/menu-rollback-cancel"
[[ $(id_of) == "$pending_id" ]]
printf '14\n%s\n确认\n0\n' "$pending_id" | run menu > "$work/menu-rollback-confirm"
[[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
ok 'Menu rollback requires a nonempty transaction ID and explicit confirmation'

reset_fixture
printf '8\n确认\n0\n' | run menu > "$work/menu-disable-fail2ban"
grep -q 'pending / 待确认' "$work/menu-disable-fail2ban"
grep -q 'enabled = false' "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local"
rollback
ok 'Fail2ban menu action uses the guarded transaction'

reset_fixture
run apply fail2ban-enable --apply >/dev/null
SSH_CONNECTION='2001:db8::20 45002 2001:db8::1 2222' run confirm --id "$(id_of)" --apply >/dev/null
printf '6\n0\n' | run menu > "$work/menu-enabled-fail2ban"
grep -q 'Fail2ban：服务运行中，本工具 jail 运行中' "$work/menu-enabled-fail2ban"
ok 'Chinese menu verifies its Fail2ban jail is running'

echo 'PASS: interactive menu suite complete'
