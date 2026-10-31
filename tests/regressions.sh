#!/usr/bin/env bash
# Uses the actual entry point and fixtures from guard_test.sh.
confirmed() { SSH_CONNECTION='2001:db8::20 45002 2001:db8::1 2222' run confirm --id "$(id_of)" --apply >/dev/null; }
runtime_file() { case $1 in nftables) echo "$GUARD_TEST_ROOT/fixture/nft";; firewalld) echo "$GUARD_TEST_ROOT/fixture/fw-ports";; *) echo "$GUARD_TEST_ROOT/fixture/v4";; esac; }
persistent_file() { case $1 in nftables) echo "$GUARD_TEST_ROOT/etc/nftables.conf";; ufw) echo "$GUARD_TEST_ROOT/etc/ufw/before.rules";; firewalld) echo "$GUARD_TEST_ROOT/etc/firewalld/fixture-ports";; *) echo "$GUARD_TEST_ROOT/etc/iptables/rules.v4";; esac; }
run_review_regressions() {
 local group=$1 backend action saved tx family
 if [[ $group == R1 || $group == all ]]; then
  reset_fixture
  mkdir -p "$GUARD_TEST_ROOT/etc/systemd/system/multi-user.target.wants"
  ln -s /usr/lib/systemd/system/sshd.service "$GUARD_TEST_ROOT/etc/systemd/system/multi-user.target.wants/sshd.service"
  run apply firewall-allow --port 8443 --apply >/dev/null
  [[ -L $GUARD_TEST_ROOT/etc/systemd/system/multi-user.target.wants/server-guard-boot.service ]]
  confirmed
  [[ ! -L $GUARD_TEST_ROOT/etc/systemd/system/multi-user.target.wants/server-guard-boot.service ]]
  run apply firewall-allow --port 9443 --apply >/dev/null
  touch "$GUARD_TEST_ROOT/fixture/restore-fail"
  if env -u SSH_CONNECTION bash "$GUARD_TEST_ROOT/var/lib/server-guard/runner/server-guard.sh" recover --apply >/dev/null 2>&1; then echo 'FAIL: injected restore failure ignored'; return 1; fi
  [[ -f $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
  rm "$GUARD_TEST_ROOT/fixture/restore-fail"
  env -u SSH_CONNECTION bash "$GUARD_TEST_ROOT/var/lib/server-guard/runner/server-guard.sh" recover --apply >/dev/null
  [[ ! -f $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
  # Legitimate unrelated wants links remain; tool-controlled paths cannot escape.
  [[ -L $GUARD_TEST_ROOT/etc/systemd/system/multi-user.target.wants/sshd.service ]]
  rm "$GUARD_TEST_ROOT/etc/systemd/system/server-guard-boot.service"
  ln -s "${GUARD_TEST_ROOT%/*}/outside" "$GUARD_TEST_ROOT/etc/systemd/system/server-guard-boot.service"
  reject apply firewall-allow --port 8443 --apply
  ok 'R1 normal enable links permit confirm and detached recovery/retry; unsafe owned unit refused'
 fi
 if [[ $group == R2 || $group == all ]]; then
  reset_fixture ufw
  printf '*filter\n:ufw-before-input - [0:0]\n:ufw-before-output - [0:0]\n-A ufw-before-input -p tcp --dport 2299 -j DROP\n-A ufw-before-output -j DROP\nCOMMIT\n' > "$GUARD_TEST_ROOT/etc/ufw/before.rules"
  sed 's/ufw-/ufw6-/g' "$GUARD_TEST_ROOT/etc/ufw/before.rules" > "$GUARD_TEST_ROOT/etc/ufw/before6.rules"
  run apply ssh-port --port 2299 --apply >/dev/null
  for family in v4 v6; do
   bash "$HERE/ufw_model.sh" load "$GUARD_TEST_ROOT" "$family"
   [[ $(bash "$HERE/ufw_model.sh" verdict "$GUARD_TEST_ROOT/fixture/$family" INPUT 2299 NEW) == ACCEPT ]] || { echo "FAIL R2: $family persistent SSH path hits pre-existing deny"; return 1; }
   [[ $(bash "$HERE/ufw_model.sh" verdict "$GUARD_TEST_ROOT/fixture/$family" OUTPUT 45000 ESTABLISHED) == ACCEPT ]]
  done
  rollback
  reset_fixture ufw
  printf 'IPV6=no\n' > "$GUARD_TEST_ROOT/etc/default/ufw"
  reject apply ssh-port --port 2299 --apply
  [[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
  ! grep -q '^MUTATE' "$GUARD_TEST_ROOT/fixture/log"
  for family in v4 v6 before.rules before6.rules after.rules after6.rules user.rules user6.rules; do
   reset_fixture ufw
   if [[ $family == v* ]]; then
    printf '*filter\n:INPUT DROP [0:0]\n:OUTPUT ACCEPT [0:0]\n:ufw-before-logging-input - [0:0]\n-A INPUT -j ufw-before-logging-input\n-A ufw-before-logging-input -j DROP\nCOMMIT\n' > "$GUARD_TEST_ROOT/fixture/$family"
   else
    printf '*filter\n:ufw-before-input - [0:0]\n:ufw-before-output - [0:0]\n:ufw-before-logging-output - [0:0]\n-A ufw-before-logging-output -j REJECT\nCOMMIT\n' > "$GUARD_TEST_ROOT/etc/ufw/$family"
   fi
   if [[ $family == v6 ]]; then sed -i 's/ufw-/ufw6-/g' "$GUARD_TEST_ROOT/fixture/$family"; elif [[ $family == *6.rules ]]; then sed -i 's/ufw-/ufw6-/g' "$GUARD_TEST_ROOT/etc/ufw/$family"; fi
   reject apply ssh-port --port 2299 --apply
   [[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
   ! grep -q '^MUTATE' "$GUARD_TEST_ROOT/fixture/log"
  done
  ok 'R2 UFW persistent path protects both families; IPV6=no and rejecting earlier logging chains refused'
 fi
 if [[ $group == R3 || $group == all ]]; then
  for backend in iptables nftables ufw firewalld; do
   reset_fixture "$backend"
   run apply firewall-allow --port 8443 --apply >/dev/null; confirmed
   for action in fail2ban-enable fail2ban-disable ssh-port; do
    if [[ $action == ssh-port ]]; then run apply "$action" --port 2299 --apply >/dev/null; else run apply "$action" --apply >/dev/null; fi
    grep -q 8443 "$(runtime_file "$backend")" || { echo "FAIL R3: $backend $action removed confirmed 8443"; return 1; }
    grep -q 8443 "$(persistent_file "$backend")"
    rollback
   done
   # Restore a snapshot whose pre-state contains a previously confirmed allow.
   run apply firewall-allow --port 9443 --apply >/dev/null; saved=$(id_of); confirmed
   run apply firewall-clear --apply >/dev/null; confirmed
   ! grep -q 8443 "$(runtime_file "$backend")"
   run apply firewall-restore --id "$saved" --apply >/dev/null
   grep -q 8443 "$(runtime_file "$backend")"; grep -q 8443 "$(persistent_file "$backend")"
   ! grep -q 9443 "$(runtime_file "$backend")"
   rollback
  done
  ok 'R3 SSH/Fail2ban preserve confirmed ordinary ports; restore preserves target-owned ports on all backends'
 fi
 if [[ $group == R4 || $group == all ]]; then
  for backend in ufw firewalld; do
   reset_fixture "$backend"
   run apply firewall-disable --scope all --apply >/dev/null; saved=$(id_of); confirmed
   if [[ $backend == ufw ]]; then [[ $(bash "$GUARD_TEST_ADAPTER" ufw status) == 'Status: inactive' ]]; else ! bash "$GUARD_TEST_ADAPTER" firewall-cmd --state; fi
   if [[ $backend == firewalld ]]; then
    touch "$GUARD_TEST_ROOT/fixture/missing-firewall-offline-cmd"
    reject apply firewall-restore --id "$saved" --apply
    [[ ! -f $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
    rm "$GUARD_TEST_ROOT/fixture/missing-firewall-offline-cmd"
    touch "$GUARD_TEST_ROOT/fixture/offline-add-fail"
    reject apply firewall-restore --id "$saved" --apply
    [[ ! -f $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
    ! bash "$GUARD_TEST_ADAPTER" firewall-cmd --state
   fi
   printf '3399\n' > "$GUARD_TEST_ROOT/fixture/require-start-port"
   SSH_CONNECTION='2001:db8::20 45100 2001:db8::1 3399' run plan firewall-restore --id "$saved" >/dev/null
   SSH_CONNECTION='2001:db8::20 45100 2001:db8::1 3399' run apply firewall-restore --id "$saved" --apply >/dev/null
   grep -q 3399 "$(runtime_file "$backend")"
   if [[ $backend == ufw ]]; then
    for family in v4 v6; do
     bash "$HERE/ufw_model.sh" load "$GUARD_TEST_ROOT" "$family"
     [[ $(bash "$HERE/ufw_model.sh" verdict "$GUARD_TEST_ROOT/fixture/$family" INPUT 3399 NEW) == ACCEPT ]]
    done
   fi
   # Rolling back a restore must reestablish the stopped/disabled pre-state.
   rollback
   rm "$GUARD_TEST_ROOT/fixture/require-start-port"
   if [[ $backend == ufw ]]; then [[ $(bash "$GUARD_TEST_ADAPTER" ufw status) == 'Status: inactive' ]]; else ! bash "$GUARD_TEST_ADAPTER" firewall-cmd --state; fi
   run apply firewall-restore --id "$saved" --backend "$backend" --apply >/dev/null; tx=$(id_of); confirmed
   if [[ $backend == ufw ]]; then [[ $(bash "$GUARD_TEST_ADAPTER" ufw status) == 'Status: active' ]]; else [[ $(bash "$GUARD_TEST_ADAPTER" firewall-cmd --state) == running ]]; fi
   [[ ! -f $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
   [[ -f $GUARD_TEST_ROOT/var/lib/server-guard/transactions/$tx/meta ]]
  done
  ok 'R4 confirmed disable can safely restore automatically; rollback of restore preserves disabled state'
 fi
}
