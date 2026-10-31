#!/usr/bin/env bash
# shellcheck disable=SC2154 # Loaded by guard_test.sh with fixture state.
for family in ubuntu rocky; do
 for backend in iptables nftables ufw firewalld; do
  reset_fixture "$backend"
  printf 'ID=%s\nVERSION_ID="24"\n' "$family" > "$GUARD_TEST_ROOT/etc/os-release"
  run ports > "$work/ports"
  grep -qx 'protected-ssh tcp 2222' "$work/ports"
  ! grep -q '^owned tcp ' "$work/ports"
  [[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard ]]
  run apply firewall-allow --port 8443 --apply >/dev/null; confirmed
  run apply firewall-allow --port 9443 --apply >/dev/null; confirmed
  run ports > "$work/ports"
  grep -qx 'owned tcp 8443' "$work/ports"; grep -qx 'owned tcp 9443' "$work/ports"
  before=$(sha256sum "$(runtime_file "$backend")")
  run plan firewall-edit --port 8443 --to-port 8543 > "$work/plan"
  [[ $before == "$(sha256sum "$(runtime_file "$backend")")" ]]
  reject apply firewall-delete --port 2222 --apply
  reject apply firewall-delete --port 8080 --apply
  reject apply firewall-edit --port 8443 --to-port 2222 --apply
  reject apply firewall-edit --port 8443 --to-port 9443 --apply
  reject apply firewall-edit --port 8443 --to-port 8443 --apply
  run apply firewall-edit --port 8443 --to-port 8543 --apply >/dev/null
  run ports > "$work/ports"
  ! grep -qx 'owned tcp 8443' "$work/ports"; grep -qx 'owned tcp 8543' "$work/ports"
  grep -qx 'owned tcp 9443' "$work/ports"
  if [[ $family == rocky && $backend == iptables ]]; then grep -q 8543 "$GUARD_TEST_ROOT/etc/sysconfig/iptables"
  else grep -q 8543 "$(persistent_file "$backend")"; fi
  rollback
  run ports > "$work/ports"
  grep -qx 'owned tcp 8443' "$work/ports"; ! grep -qx 'owned tcp 8543' "$work/ports"
  run apply firewall-edit --port 8443 --to-port 8543 --apply >/dev/null; confirmed
  run apply firewall-delete --port 8543 --apply >/dev/null
  bash "$GUARD_TEST_ROOT/var/lib/server-guard/runner/server-guard.sh" recover --apply >/dev/null
  run ports > "$work/ports"; grep -qx 'owned tcp 8543' "$work/ports"
  run apply firewall-delete --port 8543 --apply >/dev/null; confirmed
  run ports > "$work/ports"
  ! grep -qx 'owned tcp 8543' "$work/ports"; grep -qx 'owned tcp 9443' "$work/ports"
  for ssh in 2222 2200 2022; do grep -qx "protected-ssh tcp $ssh" "$work/ports"; done
  case $backend in
   iptables|ufw) grep -q '^-A INPUT -p tcp --dport 2222 -j ACCEPT$' "$GUARD_TEST_ROOT/fixture/v4";;
   firewalld) grep -q 8080 "$GUARD_TEST_ROOT/fixture/fw-ports";;
  esac
  ok "$family/$backend own port list/add/edit/delete, protected SSH, preview, confirm and detached rollback"
 done
done
reset_fixture
run apply firewall-allow --port 8443 --apply >/dev/null; confirmed
touch "$GUARD_TEST_ROOT/fixture/mutate-fail"
reject apply firewall-edit --port 8443 --to-port 8543 --apply
run ports > "$work/ports"; grep -qx 'owned tcp 8443' "$work/ports"; ! grep -qx 'owned tcp 8543' "$work/ports"
ok 'Partial edit failure restores old owned port'
reset_fixture firewalld
reject apply firewall-allow --port 8080 --apply
[[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
run apply firewall-allow --port 8443 --apply >/dev/null; confirmed
reject apply firewall-edit --port 8443 --to-port 8080 --apply
run ports > "$work/ports"; grep -qx 'owned tcp 8443' "$work/ports"
printf 'invalid registry\n' >> "$GUARD_TEST_ROOT/var/lib/server-guard/firewalld.owned"
reject ports
ok 'Externally open firewalld ports and corrupt ownership state are rejected'
echo 'PASS: owned ports suite complete'
