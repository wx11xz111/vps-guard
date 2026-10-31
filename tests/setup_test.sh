#!/usr/bin/env bash
# shellcheck disable=SC2154
export GUARD_TEST_ADAPTER=$HERE/setup_adapter.sh
setup_fixture() {
 reset_fixture
 local s
 for s in ufw firewalld nftables netfilter-persistent iptables ip6tables; do echo 0 > "$GUARD_TEST_ROOT/fixture/services/$s.active"; done
 : > "$GUARD_TEST_ROOT/fixture/nft"; : > "$GUARD_TEST_ROOT/fixture/v4"; : > "$GUARD_TEST_ROOT/fixture/v6"
 echo 0 > "$GUARD_TEST_ROOT/fixture/ufw-active"
 echo ENABLED=no > "$GUARD_TEST_ROOT/etc/ufw/ufw.conf"
}
for distro in ubuntu rocky; do
 setup_fixture
 printf 'ID=%s\nVERSION_ID="%s"\n' "$distro" "$([[ $distro == ubuntu ]] && echo 24 || echo 9)" > "$GUARD_TEST_ROOT/etc/os-release"
 run plan firewall-setup > "$work/plan"
 [[ ! -e $GUARD_TEST_ROOT/fixture/setup.log ]]
 run apply firewall-setup --apply > "$work/apply"
 grep -q '2222' "$GUARD_TEST_ROOT/fixture/setup.log"
 grep -q '2200' "$GUARD_TEST_ROOT/fixture/setup.log"
 grep -q '2022' "$GUARD_TEST_ROOT/fixture/setup.log"
 if [[ $distro == ubuntu ]]; then grep -q 'apt-get <-y> <install> <ufw>' "$GUARD_TEST_ROOT/fixture/setup.log"; else grep -q 'dnf <-y> <install> <firewalld>' "$GUARD_TEST_ROOT/fixture/setup.log"; fi
 [[ ! -e $GUARD_TEST_ROOT/fixture/masked ]]
 ok "$distro installs and protects all SSH ports before enabling"
done
setup_fixture
printf '1\n确认\n0\n' | run menu > "$work/setup-menu"
grep -q '安装并启用防火墙' "$work/setup-menu"
ok 'Menu 1 installs and enables the firewall'
setup_fixture
echo 1 > "$GUARD_TEST_ROOT/fixture/services/nftables.active"
reject apply firewall-setup --apply
[[ ! -e $GUARD_TEST_ROOT/fixture/setup.log ]]
setup_fixture
printf '*filter\n:INPUT DROP [0:0]\nCOMMIT\n' > "$GUARD_TEST_ROOT/fixture/v4"
reject apply firewall-setup --apply
[[ ! -e $GUARD_TEST_ROOT/fixture/setup.log ]]
ok 'Conflicting manager and unmanaged filtering rejected before installation'
setup_fixture
touch "$GUARD_TEST_ROOT/fixture/package-fail"
reject apply firewall-setup --apply
[[ ! -e $GUARD_TEST_ROOT/fixture/masked ]]
[[ $(cat "$GUARD_TEST_ROOT/fixture/ufw-active") == 0 ]]
setup_fixture
touch "$GUARD_TEST_ROOT/fixture/setup-enable-fail"
reject apply firewall-setup --apply
[[ $(cat "$GUARD_TEST_ROOT/fixture/ufw-active") == 0 ]]
ok 'Package/activation failures clean up the temporary mask and stop activation'
setup_fixture
touch "$GUARD_TEST_ROOT/fixture/installed"
printf 'table ip filter\ntable ip6 filter\n' > "$GUARD_TEST_ROOT/fixture/nft"
printf '*filter\n:INPUT ACCEPT [0:0]\n:FORWARD ACCEPT [0:0]\n:OUTPUT ACCEPT [0:0]\nCOMMIT\n' > "$GUARD_TEST_ROOT/fixture/v4"
cp "$GUARD_TEST_ROOT/fixture/v4" "$GUARD_TEST_ROOT/fixture/v6"
run apply firewall-setup --dry-run > /dev/null
[[ ! -e $GUARD_TEST_ROOT/fixture/setup.log ]]
run apply firewall-setup --apply > /dev/null
! grep -q '^apt-get' "$GUARD_TEST_ROOT/fixture/setup.log"
ok 'Installed UFW enables without package reinstall; dry-run is read-only'
setup_fixture
echo 1 > "$GUARD_TEST_ROOT/fixture/services/ufw.active"
echo 1 > "$GUARD_TEST_ROOT/fixture/services/nftables.active"
reject apply firewall-setup --apply
for fault in rich-fail query-fail; do
 setup_fixture
 printf 'ID=rocky\nVERSION_ID="9"\n' > "$GUARD_TEST_ROOT/etc/os-release"
 touch "$GUARD_TEST_ROOT/fixture/$fault"
 reject apply firewall-setup --apply
 [[ $(cat "$GUARD_TEST_ROOT/fixture/services/firewalld.active") == 0 ]]
 [[ ! -e $GUARD_TEST_ROOT/fixture/masked ]]
done
ok 'Incomplete firewalld inspection or runtime SSH verification aborts safely'
