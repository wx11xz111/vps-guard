#!/usr/bin/env bash
# shellcheck disable=SC2154 # Loaded by guard_test.sh with fixture state.
reset_fixture ufw
echo 0 > "$GUARD_TEST_ROOT/fixture/services/ufw.active"
touch "$GUARD_TEST_ROOT/fixture/missing-netfilter-persistent"
run ports > "$work/ports"
grep -qx 'backend=ufw' "$work/ports"
grep -qx 'protected-ssh tcp 2222' "$work/ports"
printf '5\n0\n' | run menu > "$work/menu-ufw"
grep -q '防火墙后端：ufw' "$work/menu-ufw"
! grep -q '端口查询失败' "$work/menu-ufw"
run plan firewall-allow --port 8443 > "$work/plan"
grep -q '^防火墙：ufw' "$work/plan"
! grep -q 'systemctl <cat> <netfilter-persistent>' "$GUARD_TEST_ROOT/fixture/log"
! grep -q '^MUTATE' "$GUARD_TEST_ROOT/fixture/log"
[[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard ]]
reject ports --backend iptables
grep -q 'requested backend conflicts with active manager' "$work/reject.log"
for service in firewalld nftables netfilter-persistent; do
 echo 1 > "$GUARD_TEST_ROOT/fixture/services/$service.active"
 reject ports
 grep -q 'conflicting firewall managers' "$work/reject.log"
 echo 0 > "$GUARD_TEST_ROOT/fixture/services/$service.active"
done
ok 'Active UFW with inactive systemd unit supports menu/ports/plan without iptables-persistent; conflicts still refused'

reset_fixture
touch "$GUARD_TEST_ROOT/fixture/missing-netfilter-persistent"
run ports > "$work/ports"
grep -qx 'backend=iptables' "$work/ports"
reject plan firewall-allow --port 8443
grep -q 'install iptables-persistent explicitly for persistence' "$work/reject.log"
ok 'Standalone iptables inspection needs no persistence service; changes still require it'

reset_fixture ufw
echo 0 > "$GUARD_TEST_ROOT/fixture/ufw-active"
touch "$GUARD_TEST_ROOT/fixture/foreign-nft" "$GUARD_TEST_ROOT/fixture/missing-iptables-restore"
run ports > "$work/ports"
grep -qx 'backend=ufw' "$work/ports"
grep -qx 'firewall-state=inactive' "$work/ports"
printf '5\n0\n' | run menu > "$work/menu-ufw-inactive"
grep -q '防火墙状态：未启用' "$work/menu-ufw-inactive"
! grep -q '端口查询失败' "$work/menu-ufw-inactive"
! grep -q '^MUTATE' "$GUARD_TEST_ROOT/fixture/log"
[[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard ]]
reject plan firewall-allow --port 8443
ok 'Inactive UFW and foreign Fail2ban nft tables do not block read-only ports/menu; mutations remain guarded'

for family in ubuntu rocky; do
 for backend in iptables nftables ufw firewalld; do
  reset_fixture "$backend"
  printf 'ID=%s\nVERSION_ID="24"\n' "$family" > "$GUARD_TEST_ROOT/etc/os-release"
  run apply firewall-allow --port 8443 --apply >/dev/null
  run apply firewall-allow --port 9443 --apply >/dev/null
  run ports > "$work/ports"
  grep -qx 'owned tcp 8443' "$work/ports"; grep -qx 'owned tcp 9443' "$work/ports"
  before=$(sha256sum "$(runtime_file "$backend")")
  run plan firewall-edit --port 8443 --to-port 8543 > "$work/plan"
  [[ $before == "$(sha256sum "$(runtime_file "$backend")")" ]]
  reject apply firewall-delete --port 2222 --apply
  reject apply firewall-delete --port 8080 --apply
  reject apply firewall-edit --port 8443 --to-port 2222 --apply
  reject apply firewall-edit --port 8443 --to-port 9443 --apply
  run apply firewall-edit --port 8443 --to-port 8543 --apply >/dev/null
  run apply firewall-delete --port 8543 --apply >/dev/null
  run ports > "$work/ports"
  ! grep -qx 'owned tcp 8443' "$work/ports"; ! grep -qx 'owned tcp 8543' "$work/ports"
  grep -qx 'owned tcp 9443' "$work/ports"
  for ssh in 2222 2200 2022; do grep -qx "protected-ssh tcp $ssh" "$work/ports"; done
  no_recovery
  ok "$family/$backend add/edit/delete persists immediately while protecting SSH and unrelated ports"
 done
done
reset_fixture firewalld
reject apply firewall-allow --port 8080 --apply
run apply firewall-allow --port 8443 --apply >/dev/null
reject apply firewall-edit --port 8443 --to-port 8080 --apply
printf 'invalid registry\n' >> "$GUARD_TEST_ROOT/var/lib/server-guard/firewalld.owned"
reject ports
ok 'External firewalld ports and corrupt ownership state remain rejected'
