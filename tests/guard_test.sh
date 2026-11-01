#!/usr/bin/env bash
set -euo pipefail
# Real state/files/operations; only privileged OS commands cross the adapter.
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
backup_of() { cat "$GUARD_TEST_ROOT/var/lib/server-guard/latest"; }
backup_dir() { printf '%s/var/lib/server-guard/transactions/%s\n' "$GUARD_TEST_ROOT" "$(backup_of)"; }
no_recovery() {
 [[ ! -f $GUARD_TEST_ROOT/var/lib/server-guard/pending ]]
 [[ ! -f $GUARD_TEST_ROOT/etc/systemd/system/server-guard-rollback.timer ]]
 [[ ! -f $GUARD_TEST_ROOT/etc/systemd/system/server-guard-boot.service ]]
}
runtime_file() { case $1 in nftables) echo "$GUARD_TEST_ROOT/fixture/nft";; firewalld) echo "$GUARD_TEST_ROOT/fixture/fw-ports";; *) echo "$GUARD_TEST_ROOT/fixture/v4";; esac; }
persistent_file() { case $1 in nftables) echo "$GUARD_TEST_ROOT/etc/nftables.conf";; ufw) echo "$GUARD_TEST_ROOT/etc/ufw/before.rules";; firewalld) echo "$GUARD_TEST_ROOT/etc/firewalld/fixture-ports";; *) echo "$GUARD_TEST_ROOT/etc/iptables/rules.v4";; esac; }
focus=${GUARD_TEST_FOCUS:-all}
case $focus in all|operations|ports|menu|features|fail2ban|setup|selinux|workflow) :;; *) echo "Unknown focus: $focus"; exit 1;; esac
for group in operations ports menu features fail2ban setup selinux workflow; do
 [[ $focus == all || $focus == "$group" ]] || continue
 export GUARD_TEST_ADAPTER=$HERE/adapter.sh
 source "$HERE/${group}_test.sh"
done
if [[ $focus == all ]]; then bash "$HERE/fetch_test.sh"; fi
echo 'PASS: immediate-operation suite complete'
