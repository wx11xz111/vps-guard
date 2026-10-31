#!/usr/bin/env bash
set -euo pipefail
# Real state/files/transactions; only privileged OS commands cross the adapter.
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
SCRIPT=$HERE/../server-guard.sh
[[ -f $SCRIPT ]] || { echo 'FAIL: independent server-guard entry point missing'; exit 1; }
[[ $(id -u) == 0 ]] || { echo 'Run fixtures as root inside isolated Linux test environment'; exit 1; }
: "${TMPDIR:?TMPDIR must be an isolated filesystem with working Unix permissions}"
work=$(mktemp -d "$TMPDIR/guard-tests.XXXXXXXX")
trap 'rc=$?; if ((rc)); then tail -n 30 "$work/root/fixture/log" 2>/dev/null || true; cat "$work/apply" "$work/reject.log" 2>/dev/null || true; fi; rm -rf -- "$work"' EXIT
export GUARD_TEST_ROOT=$work/root GUARD_TEST_ADAPTER=$HERE/adapter.sh
export SSH_CONNECTION='2001:db8::20 45000 2001:db8::1 2222'
reset_fixture() {
 rm -rf -- "$GUARD_TEST_ROOT"
 mkdir -p "$GUARD_TEST_ROOT"/{etc/ssh,etc/systemd/system,etc/ufw,etc/default,etc/iptables,etc/firewalld/zones,etc/fail2ban/jail.d,run/systemd/system,fixture}
 chmod 700 "$GUARD_TEST_ROOT"
 printf 'server-guard-fixture-v1\n' > "$GUARD_TEST_ROOT/.server-guard-test"
 printf 'ID=ubuntu\nVERSION_ID="24.04"\n' > "$GUARD_TEST_ROOT/etc/os-release"
 printf 'Port 2222\nInclude /etc/ssh/sshd_config.d/*.conf\n' > "$GUARD_TEST_ROOT/etc/ssh/sshd_config"
 printf '%s\n' "${1:-iptables}" > "$GUARD_TEST_ROOT/fixture/backend"
 printf '*filter\n:INPUT DROP [0:0]\n:FORWARD ACCEPT [0:0]\n:OUTPUT ACCEPT [0:0]\n-A INPUT -p tcp --dport 2222 -j ACCEPT\nCOMMIT\n' > "$GUARD_TEST_ROOT/fixture/v4"
 cp "$GUARD_TEST_ROOT/fixture/v4" "$GUARD_TEST_ROOT/fixture/v6"
 { echo '# original-v4'; sed 's/2222/7777/g' "$GUARD_TEST_ROOT/fixture/v4"; } > "$GUARD_TEST_ROOT/etc/iptables/rules.v4"
 { echo '# original-v6'; sed 's/2222/7777/g' "$GUARD_TEST_ROOT/fixture/v6"; } > "$GUARD_TEST_ROOT/etc/iptables/rules.v6"
 printf 'table inet filter {\n chain input {\n  type filter hook input priority filter; policy drop;\n  tcp dport 2222 accept\n }\n}\n' > "$GUARD_TEST_ROOT/fixture/nft"
 { echo '# original-nft'; sed 's/2222/7777/g' "$GUARD_TEST_ROOT/fixture/nft"; } > "$GUARD_TEST_ROOT/etc/nftables.conf"
 printf '*filter\n:ufw-before-input - [0:0]\n:ufw-before-output - [0:0]\n-A ufw-before-input -j RETURN\nCOMMIT\n' > "$GUARD_TEST_ROOT/etc/ufw/before.rules"
 sed 's/ufw-/ufw6-/g' "$GUARD_TEST_ROOT/etc/ufw/before.rules" > "$GUARD_TEST_ROOT/etc/ufw/before6.rules"
 printf 'ENABLED=yes\n' > "$GUARD_TEST_ROOT/etc/ufw/ufw.conf"
 printf 'IPV6=yes\n' > "$GUARD_TEST_ROOT/etc/default/ufw"
 mkdir -p "$GUARD_TEST_ROOT/fixture/services"
 for svc in nftables netfilter-persistent iptables ip6tables ufw firewalld fail2ban; do
  printf '0\n' > "$GUARD_TEST_ROOT/fixture/services/$svc.active"
  printf '0\n' > "$GUARD_TEST_ROOT/fixture/services/$svc.enabled"
 done
 svc=${1:-iptables}; [[ $svc != iptables ]] || svc=netfilter-persistent
 printf '1\n' > "$GUARD_TEST_ROOT/fixture/services/$svc.active"
 printf '1\n' > "$GUARD_TEST_ROOT/fixture/services/$svc.enabled"
 printf '1\n' > "$GUARD_TEST_ROOT/fixture/services/fail2ban.active"
 printf '1\n' > "$GUARD_TEST_ROOT/fixture/services/fail2ban.enabled"
 printf '1\n' > "$GUARD_TEST_ROOT/fixture/ufw-active"
 printf 'original-firewalld\n' > "$GUARD_TEST_ROOT/etc/firewalld/zones/public.xml"
 printf '22/tcp\n' > "$GUARD_TEST_ROOT/etc/firewalld/fixture-ports"
 printf '22/tcp 8080/tcp\n' > "$GUARD_TEST_ROOT/fixture/fw-ports"
 printf 'ssh\n' > "$GUARD_TEST_ROOT/fixture/fw-services"
 printf 'default\n' > "$GUARD_TEST_ROOT/fixture/fw-target"
 printf 'default\n' > "$GUARD_TEST_ROOT/etc/firewalld/fixture-target"
 printf '[other-jail]\nenabled=true\n' > "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/user.local"
}
ok() { echo "PASS: $*"; }
run() { bash "$SCRIPT" "$@"; }
reject() { if run "$@" >"$work/reject.log" 2>&1; then cat "$work/reject.log"; echo "FAIL: accepted $*"; exit 1; fi; }
id_of() { cat "$GUARD_TEST_ROOT/var/lib/server-guard/pending"; }
rollback() { run rollback --id "$(id_of)" --apply >/dev/null; }
# shellcheck source=regressions.sh
source "$HERE/regressions.sh"
if [[ ${GUARD_TEST_FOCUS:-} == setup ]]; then source "$HERE/setup_test.sh"; exit; fi
if [[ ${GUARD_TEST_FOCUS:-} == ports ]]; then source "$HERE/ports_test.sh"; exit; fi
if [[ ${GUARD_TEST_FOCUS:-} == menu ]]; then source "$HERE/menu_test.sh"; exit; fi
if [[ ${GUARD_TEST_FOCUS:-} == fail2ban ]]; then source "$HERE/fail2ban_test.sh"; exit; fi
if [[ ${GUARD_TEST_FOCUS:-} == features ]]; then source "$HERE/features_test.sh"; exit; fi
if [[ ${GUARD_TEST_FOCUS:-} == selinux* ]]; then source "$HERE/selinux_test.sh"; exit; fi
if [[ -n ${GUARD_TEST_FOCUS:-} ]]; then run_review_regressions "$GUARD_TEST_FOCUS"; exit; fi
reset_fixture
run plan firewall-allow --port 8443 > "$work/plan"
[[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard ]]
grep -q 2222 "$work/plan"; grep -q 2200 "$work/plan"; grep -q 2022 "$work/plan"
ok 'plan is read-only and protects session, effective config and IPv6 listener ports'
for fault in sshd-T ss systemd socket selinux conflict timer-fail; do
 reset_fixture; touch "$GUARD_TEST_ROOT/fixture/$fault"
 reject apply ssh-port --port 2299 --apply
 [[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
 ! grep -q '^MUTATE' "$GUARD_TEST_ROOT/fixture/log"
done
ok 'unsafe discovery/systemd/socket/SELinux/backend conflict rejected before mutation'
reset_fixture
reject apply firewall-allow --port 99999 --apply
reject apply firewall-allow --port '22;id' --apply
reject apply firewall-allow --port 8443
SSH_CONNECTION='' reject apply firewall-allow --port 8443 --apply
SSH_CONNECTION=':::: 45000 2001:db8::1 2222' reject apply firewall-allow --port 8443 --apply
GUARD_TEST_ROOT=/./ GUARD_TEST_ADAPTER=$HERE/adapter.sh reject status
GUARD_TEST_ROOT=// GUARD_TEST_ADAPTER=$HERE/adapter.sh reject status
ok 'strict arguments, explicit apply, SSH environment and canonical test root'
reset_fixture
printf '*raw\n:PREROUTING ACCEPT [0:0]\nCOMMIT\n' >> "$GUARD_TEST_ROOT/fixture/v4"
reject apply firewall-clear --scope all --apply
[[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard ]]
reset_fixture nftables
printf 'table inet filter {\n chain input {\n type filter hook input priority filter; policy drop;\n }\n chain late {\n type filter hook input priority 10; policy drop;\n }\n}\n' > "$GUARD_TEST_ROOT/fixture/nft"
reject apply firewall-allow --port 8443 --apply
[[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard ]]
reset_fixture
mkdir -p "$GUARD_TEST_ROOT/var/lib/server-guard"; chmod 755 "$GUARD_TEST_ROOT/var/lib/server-guard"
reject status
ok 'early tables, late nft base-chain drops and insecure state are rejected'
for backend in iptables nftables ufw firewalld; do
 reset_fixture "$backend"
 cp "$GUARD_TEST_ROOT/fixture/v4" "$work/original-v4"
 cp "$GUARD_TEST_ROOT/fixture/v6" "$work/original-v6"
 cp "$GUARD_TEST_ROOT/fixture/nft" "$work/original-nft"
 run apply firewall-allow --port 8443 --apply > "$work/apply"
 tx=$(id_of)
 [[ $(stat -c %a "$GUARD_TEST_ROOT/var/lib/server-guard") == 700 ]]
 [[ $(stat -c %a "$GUARD_TEST_ROOT/var/lib/server-guard/transactions/$tx/meta") == 600 ]]
 [[ -f $GUARD_TEST_ROOT/etc/systemd/system/server-guard-rollback.timer ]]
 [[ -f $GUARD_TEST_ROOT/etc/systemd/system/server-guard-boot.service ]]
 grep -q 'Persistent=true' "$GUARD_TEST_ROOT/etc/systemd/system/server-guard-rollback.timer"
 ! grep -Eq '^On(Boot|Startup)Sec=' "$GUARD_TEST_ROOT/etc/systemd/system/server-guard-rollback.timer"
 if [[ $backend == iptables ]] && command -v systemd-analyze >/dev/null; then
  systemd-analyze verify "$GUARD_TEST_ROOT/etc/systemd/system/server-guard-rollback.service" "$GUARD_TEST_ROOT/etc/systemd/system/server-guard-rollback.timer" "$GUARD_TEST_ROOT/etc/systemd/system/server-guard-boot.service"
 fi
 case $backend in iptables|ufw) rules=$GUARD_TEST_ROOT/fixture/v4;; nftables) rules=$GUARD_TEST_ROOT/fixture/nft;; firewalld) rules=$GUARD_TEST_ROOT/fixture/fw-ports;; esac
 grep -q '2222' "$rules"; grep -q '2200' "$rules"; grep -q '2022' "$rules"; grep -q '8443' "$rules"
 reject apply firewall-clear --apply
 reject confirm --id "$tx" --apply
 SSH_CONNECTION='2001:db8::99 45111 2001:db8::1 2222' reject confirm --id "$tx" --apply
 run rollback --id "$tx" --apply >/dev/null
 [[ ! -f $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
 case $backend in
  iptables|ufw) cmp "$work/original-v4" "$GUARD_TEST_ROOT/fixture/v4"; cmp "$work/original-v6" "$GUARD_TEST_ROOT/fixture/v6";;
  nftables) cmp "$work/original-nft" "$GUARD_TEST_ROOT/fixture/nft";;
  firewalld) [[ $(cat "$GUARD_TEST_ROOT/fixture/fw-ports") == '22/tcp 8080/tcp' ]];;
 esac
 grep -q '^# original-v4$' "$GUARD_TEST_ROOT/etc/iptables/rules.v4"
 grep -q '^# original-nft$' "$GUARD_TEST_ROOT/etc/nftables.conf"
 [[ $(cat "$GUARD_TEST_ROOT/etc/firewalld/fixture-ports") == '22/tcp' ]]
 ok "$backend real transaction rollback restores runtime and persistent files"
done
reset_fixture; touch "$GUARD_TEST_ROOT/fixture/mutate-fail"
reject apply firewall-allow --port 8443 --apply
[[ ! -f $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
grep -q '^# original-v4$' "$GUARD_TEST_ROOT/etc/iptables/rules.v4"
ok 'partial firewall command failure compensates immediately'
reset_fixture
touch "$GUARD_TEST_ROOT/fixture/new-sshd-invalid"
reject apply ssh-port --port 2299 --apply
! grep -q '^Port 2299$' "$GUARD_TEST_ROOT/etc/ssh/sshd_config"
[[ ! -e $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
ok 'new invalid SSH config is restored without stopping sshd'
reset_fixture
run apply ssh-port --port 2299 --apply > /dev/null
tx=$(id_of)
grep -q 'Port 2299' "$GUARD_TEST_ROOT/etc/ssh/sshd_config"
grep -q 'Port 2222' "$GUARD_TEST_ROOT/etc/ssh/sshd_config"
SSH_CONNECTION='2001:db8::20 45001 2001:db8::1 2222' reject confirm --id "$tx" --apply
SSH_CONNECTION='2001:db8::20 45001 2001:db8::1 2299' run confirm --id "$tx" --apply >/dev/null
[[ ! -f $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
ok 'SSH change retains old port and requires new SSH connection on new port to confirm'
reset_fixture
run apply firewall-allow --port 8443 --apply >/dev/null
tx=$(id_of)
printf '1\n' > "$GUARD_TEST_ROOT/var/lib/server-guard/transactions/$tx/deadline"
chmod 600 "$GUARD_TEST_ROOT/var/lib/server-guard/transactions/$tx/deadline"
SSH_CONNECTION='2001:db8::20 45002 2001:db8::1 2222' reject confirm --id "$tx" --apply
rollback
ok 'expired transaction cannot be confirmed before delayed timer execution'
reset_fixture
run apply firewall-allow --port 8443 --apply >/dev/null
tx=$(id_of)
cp "$GUARD_TEST_ROOT/var/lib/server-guard/transactions/$tx/meta" "$work/meta.original"
printf 'unexpected\n' >> "$GUARD_TEST_ROOT/var/lib/server-guard/transactions/$tx/meta"
reject rollback --id "$tx" --apply
grep -q 8443 "$GUARD_TEST_ROOT/fixture/v4"
cp "$work/meta.original" "$GUARD_TEST_ROOT/var/lib/server-guard/transactions/$tx/meta"
rollback
ok 'damaged backup metadata rejected before live configuration deletion'
for trigger in timeout boot; do
 reset_fixture; run apply firewall-allow --port 8443 --apply >/dev/null
 # Execute the actual persisted runner used by detached systemd units, without original shell.
 env -u SSH_CONNECTION bash "$GUARD_TEST_ROOT/var/lib/server-guard/runner/server-guard.sh" recover --apply > /dev/null
 [[ ! -f $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
 ok "$trigger detached/reboot runner recovers pending transaction"
done
reset_fixture; run apply firewall-allow --port 8443 --apply >/dev/null
touch "$GUARD_TEST_ROOT/fixture/restore-fail"
reject rollback --id "$(id_of)" --apply
[[ -f $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
rm "$GUARD_TEST_ROOT/fixture/restore-fail"; rollback
ok 'failed rollback stays pending and is retryable'
for backend in iptables nftables; do
 reset_fixture "$backend"
 run apply firewall-allow --port 8443 --apply >/dev/null
 saved=$(id_of)
 SSH_CONNECTION='2001:db8::20 45002 2001:db8::1 2222' run confirm --id "$saved" --apply >/dev/null
 case $backend in iptables) persistent=$GUARD_TEST_ROOT/etc/iptables/rules.v4;; nftables) persistent=$GUARD_TEST_ROOT/etc/nftables.conf;; esac
 grep -q '7777' "$persistent"
 run apply firewall-restore --id "$saved" --apply >/dev/null
 grep -q '7777' "$persistent"
 ! grep -q '8443' "$persistent"
 rollback
done
ok 'runtime/permanent differences survive apply and explicit restore'
for backend in iptables nftables ufw firewalld; do
 reset_fixture "$backend"
 run apply firewall-allow --port 8443 --apply >/dev/null
 saved=$(id_of)
 SSH_CONNECTION='2001:db8::20 45002 2001:db8::1 2222' run confirm --id "$saved" --apply >/dev/null
 run apply firewall-clear --apply >/dev/null
 case $backend in iptables|ufw) rules=$GUARD_TEST_ROOT/fixture/v4;; nftables) rules=$GUARD_TEST_ROOT/fixture/nft;; firewalld) rules=$GUARD_TEST_ROOT/fixture/fw-ports;; esac
 ! grep -q 8443 "$rules"; grep -q 2222 "$rules"
 rollback
done
ok 'owned clear removes previously managed port and retains protected SSH'
reset_fixture firewalld
run apply firewall-clear --scope all --apply >/dev/null
[[ $(cat "$GUARD_TEST_ROOT/fixture/fw-target") == ACCEPT ]]
[[ $(cat "$GUARD_TEST_ROOT/etc/firewalld/fixture-target") == ACCEPT ]]
rollback
ok 'firewalld clear-all opens runtime and permanent zone policies without disabling manager'
for family in debian rocky; do
 for backend in iptables nftables ufw firewalld; do
  reset_fixture "$backend"
  printf 'ID=%s\nVERSION_ID="%s"\n' "$family" "$([[ $family == debian ]] && echo 12 || echo 9)" > "$GUARD_TEST_ROOT/etc/os-release"
  run apply firewall-clear --scope all --apply >/dev/null; rollback
  run apply firewall-disable --scope all --apply >/dev/null; rollback
  run apply firewall-clear --apply >/dev/null
  saved=$(id_of)
  SSH_CONNECTION='2001:db8::20 45002 2001:db8::1 2222' run confirm --id "$saved" --apply >/dev/null
  run apply firewall-restore --id "$saved" --apply >/dev/null; rollback
 done
done
ok 'Debian/RHEL families: all backends clear, disable, owned clear and restore'
reset_fixture; printf 'ID=centos\nVERSION_ID="7"\n' > "$GUARD_TEST_ROOT/etc/os-release"
reject apply firewall-clear --apply
reset_fixture; run apply fail2ban-enable --apply >/dev/null
grep -q '2001:db8::20' "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local"
grep -q '2200' "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/server-guard.local"
[[ $(cat "$GUARD_TEST_ROOT/etc/fail2ban/jail.d/user.local") == $'[other-jail]\nenabled=true' ]]
rollback
run apply fail2ban-disable --apply >/dev/null; rollback
ok 'Fail2ban owns only its jail, covers all ports and ignores management source; CentOS7 rejected'
bash "$HERE/fetch_test.sh"
source "$HERE/features_test.sh"
run_review_regressions all
printf 'PASS: server-guard suite complete\n'
