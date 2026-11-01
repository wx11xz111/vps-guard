#!/usr/bin/env bash
# Loaded only from the bundled, root-controlled installation directory.
setup_empty_rules() {
 local text cmd
 if has nft; then
  text=$(os nft list tables) || die 'Cannot inspect nftables / 无法检查nft规则'
  if [[ -n $text ]]; then
   [[ -z $(sed '/^table ip filter$/d;/^table ip6 filter$/d;/^table inet f2b-table$/d' <<< "$text") ]] || die 'Existing nft tables; use the current manager / 已有nft规则，请使用现有管理器'
   has iptables-save && has ip6tables-save || die 'Cannot inspect existing filter tables'
  fi
 fi
 for cmd in iptables-save ip6tables-save; do
  if has "$cmd"; then
   text=$(os "$cmd") || die 'Cannot inspect firewall rules / 无法检查防火墙规则'
   awk '/^#/ || /^\*filter$/ || /^:(INPUT|OUTPUT|FORWARD) ACCEPT \[/ || /^COMMIT$/ || /^[[:space:]]*$/ {next} {exit 1}' <<< "$text" || die 'Existing filtering rules; no installation / 已有过滤规则，停止安装'
  fi
 done
}
setup_firewall() (
 platform; secure_paths; discover
 local service s status zone p rules active=0 work='' masked=0 started=0 success=0 enable_changed=0
 [[ $(os systemctl is-system-running) =~ ^(running|degraded)$ ]] || die 'systemd unavailable'
 [[ $FAMILY == debian ]] && service=ufw || service=firewalld
 for s in ufw firewalld nftables netfilter-persistent iptables ip6tables; do
  if os systemctl is-active --quiet "$s"; then
   [[ $s == "$service" ]] || die "Firewall manager $s already active / 已有其他防火墙运行"
   if [[ $s != ufw || $(os ufw status) == 'Status: active'* ]]; then active=1; fi
  fi
 done
 if ((active)); then
  say "$service is already active; use port management." "$service 已运行，请使用端口管理菜单。"; return 0
 fi
 if [[ $service == ufw ]] && has ufw && [[ $(os ufw status) == 'Status: active'* ]]; then
  say 'UFW is already active.' 'UFW 已运行。'; return 0
 fi
 status=$(os systemctl is-enabled "$service" 2>/dev/null || true)
 [[ $status != masked* ]] || die 'Service was masked by administrator / 服务已被管理员屏蔽，请先检查'
 setup_empty_rules
 say "Install/enable $service; preserve SSH TCP ports: ${PROTECTED_PORTS[*]}. Other services may need additional ports." "安装并启用 $service；先放行 SSH TCP 端口：${PROTECTED_PORTS[*]}。其他业务端口请另行放行。"
 say 'Allow these ports in your cloud security group and retain rescue-console access.' '请先在云安全组放行以上端口，并保留救援控制台入口。' warning
 [[ $MODE != plan && $DRY == 0 ]] || return 0
 [[ $APPLY == 1 ]] || die '--apply required / 需要--apply'
 lock_state
 work=$(mktemp -d "$STATE/setup.XXXXXXXX")
 setup_cleanup() {
  local rc=$?
  if ((masked)); then os systemctl unmask --runtime "$service" || true; fi
  if ((started && !success)); then
   if [[ $service == ufw ]]; then os ufw --force disable || true; else os systemctl stop firewalld || true; fi
   if ((enable_changed)); then os systemctl disable "$service" || true; fi
   say "Activation failed; attempted to stop the firewall. Check the console if cleanup failed." "启用失败，已尝试停止防火墙；如清理报错请通过控制台检查。" error >&2
  fi
  [[ -z $work ]] || rm -rf -- "$work"
  exit "$rc"
 }
 trap setup_cleanup EXIT
 masked=1
 os systemctl mask --runtime "$service"
 if [[ $service == ufw ]]; then
  if ! has ufw; then os apt-get update; DEBIAN_FRONTEND=noninteractive os apt-get -y install ufw; fi
  need ufw ufw ufw
 else
  if ! has firewall-cmd || ! has firewall-offline-cmd; then os dnf -y install firewalld; fi
  need firewall-cmd firewalld firewalld; need firewall-offline-cmd firewalld firewalld
 fi
 secure_paths; setup_empty_rules
 if [[ $service == ufw ]]; then
  [[ $(os ufw status) == 'Status: inactive' ]] || die 'UFW status changed during installation'
  ufw_persistent_preflight "$ROOT"
  TX=$work
  ufw_build "$ROOT/etc/ufw/before.rules" "$work/before.rules"
  ufw_build "$ROOT/etc/ufw/before6.rules" "$work/before6.rules"
  cat "$work/before.rules" > "$ROOT/etc/ufw/before.rules"
  cat "$work/before6.rules" > "$ROOT/etc/ufw/before6.rules"
  for p in "${PROTECTED_PORTS[@]}"; do os ufw allow "$p/tcp"; done
 else
  [[ ! -f $ROOT/etc/firewalld/direct.xml ]] || die 'Custom firewalld direct rules refused / 不接管自定义direct规则'
  [[ -z $(find "$ROOT/etc/firewalld/policies" -type f -print -quit 2>/dev/null || true) ]] || die 'Custom firewalld policies refused'
  if [[ -f $ROOT/etc/firewalld/firewalld.conf ]]; then
   ! grep -Eq '^[[:space:]]*(CleanupOnExit=no|FirewallBackend=iptables)' "$ROOT/etc/firewalld/firewalld.conf" || die 'Unsupported firewalld configuration'
  fi
  os firewall-offline-cmd --system-config "$ROOT/etc/firewalld" --check-config
  local zones policies policy rule
  policies=$(os firewall-offline-cmd --system-config "$ROOT/etc/firewalld" --get-policies) || die 'Cannot inspect firewalld policies'
  for policy in $policies; do
   [[ $policy == allow-host-ipv6 ]] || die 'Custom firewalld policy refused'
   rules=$(os firewall-offline-cmd --system-config "$ROOT/etc/firewalld" --policy="$policy" --get-target) || die 'Cannot inspect policy target'
   [[ $rules == CONTINUE ]] || die 'Modified host policy refused'
   rules=$(os firewall-offline-cmd --system-config "$ROOT/etc/firewalld" --policy="$policy" --list-rich-rules) || die 'Cannot inspect policy rules'
   while IFS= read -r rule; do
    [[ -z $rule || $rule =~ ^rule\ family=\"ipv6\"\ icmp-type\ name=\"[a-z-]+\"\ accept$ ]] || die 'Modified host policy refused'
   done <<< "$rules"
  done
  zones=$(os firewall-offline-cmd --system-config "$ROOT/etc/firewalld" --get-zones)
  [[ -n $zones ]] || die 'No firewalld zones'
  for zone in $zones; do
   [[ $zone =~ ^[A-Za-z0-9_-]+$ ]] || die 'Invalid zone'
   rules=$(os firewall-offline-cmd --system-config "$ROOT/etc/firewalld" --zone="$zone" --list-rich-rules) || die 'Cannot inspect rich rules'
   [[ -z $rules ]] || die 'Custom rich rules refused'
   rules=$(os firewall-offline-cmd --system-config "$ROOT/etc/firewalld" --zone="$zone" --list-forward-ports) || die 'Cannot inspect forwarding'
   [[ -z $rules ]] || die 'Custom forwarding refused'
  done
  for zone in $zones; do
   for p in "${PROTECTED_PORTS[@]}"; do os firewall-offline-cmd --system-config "$ROOT/etc/firewalld" --zone="$zone" --add-port="$p/tcp"; done
  done
  os firewall-offline-cmd --system-config "$ROOT/etc/firewalld" --check-config
 fi
 os systemctl unmask --runtime "$service"; masked=0
 started=1
 if [[ $service == ufw ]]; then
  os ufw --force enable
  [[ $(os ufw status) == 'Status: active'* ]] || die 'UFW did not activate'
 else
  os systemctl start firewalld
  os firewall-cmd --state
  for zone in $zones; do
   for p in "${PROTECTED_PORTS[@]}"; do os firewall-cmd --zone="$zone" --query-port="$p/tcp"; done
  done
 fi
 [[ $status == enabled ]] || enable_changed=1
 os systemctl enable "$service"
 printf '%s\n' "$service" > "$STATE/firewall.backend"
 success=1
 say "Firewall enabled: $service. Open a new SSH connection to verify access." "防火墙已启用：$service。请新建 SSH 连接验证访问。" success
)
detect_backend() {
 local SESSION_PORT=${SESSION_PORT:-unknown}
 local s; local -a active=()
 for s in firewalld ufw nftables; do
  # UFW rules can remain active even when its oneshot unit is inactive.
  # Identify the manager before falling back to its underlying iptables rules.
  if os systemctl is-active --quiet "$s" || { [[ $s == ufw ]] && has ufw && [[ $(os ufw status) == 'Status: active'* ]]; }; then
   active+=("$s")
  fi
 done
 if os systemctl is-active --quiet netfilter-persistent || os systemctl is-active --quiet iptables || os systemctl is-active --quiet ip6tables; then active+=(iptables); fi
 ((${#active[@]} <= 1)) || die 'conflicting firewall managers / 多个防火墙管理器冲突'
 BACKEND=${BACKEND_REQUEST:-${active[0]:-}}
 if [[ -n $BACKEND_REQUEST && ${#active[@]} != 0 && $BACKEND_REQUEST != "${active[0]}" ]]; then die 'requested backend conflicts with active manager'; fi
 if [[ -z $BACKEND ]]; then
  # Retain the manager identity after stopping its service. Never interpret
  # an inactive UFW installation as unmanaged iptables rules.
  local remembered=''
  if [[ -f $STATE/firewall.backend ]]; then remembered=$(cat "$STATE/firewall.backend"); fi
  case $remembered in ufw|firewalld|nftables|iptables) BACKEND=$remembered;; esac
  if [[ -z $BACKEND ]] && has ufw && [[ -f $ROOT/etc/ufw/ufw.conf ]]; then BACKEND=ufw; fi
  if [[ -z $BACKEND ]] && has firewall-cmd && [[ -f $ROOT/etc/firewalld/firewalld.conf ]]; then BACKEND=firewalld; fi
 fi
 if [[ -z $BACKEND ]]; then
  local nt='' ip=''
  if has nft; then nt=$(os nft list tables) || die 'cannot inspect nftables'; fi
  if has iptables-save; then ip=$(os iptables-save) || die 'cannot inspect iptables'; fi
  [[ -z $nt || -z $ip ]] || die 'ambiguous unmanaged nft/iptables; choose a single manager first'
  if [[ -n $nt ]]; then BACKEND=nftables; elif [[ -n $ip ]]; then BACKEND=iptables; else die "no supported firewall manager. Menu 7/8 need no firewall. For port/SSH changes, allow current SSH port $SESSION_PORT/tcp in the cloud security group and UFW (Debian/Ubuntu) or firewalld (RHEL/Rocky/Alma) before enabling the manager; keep this SSH session and rescue-console access, then retry. / 未检测到受支持防火墙。菜单7/8无需防火墙；可用菜单1安装并启用防火墙。端口或SSH操作请先在云安全组和拟启用的UFW或firewalld中放行当前SSH端口 $SESSION_PORT/tcp，保留当前连接及救援控制台，再启用防火墙并重试"; fi
 fi
}
backend_show_rules() {
 # Read native rules without mutation preflight or persistence dependencies.
 printf 'backend=%s\n' "$BACKEND"
 case $BACKEND in
  ufw)
   need ufw ufw ufw
   os ufw status numbered || return
   say 'Complete runtime rules (including before/after chains):' '完整运行规则（含before/after链）：'
   os ufw show raw || return;;
  nftables) need nft nftables nftables; os nft list ruleset || return;;
  iptables)
   need iptables-save iptables iptables; need ip6tables-save iptables iptables
   say 'IPv4 runtime rules:' 'IPv4运行规则：'; os iptables-save || return
   say 'IPv6 runtime rules:' 'IPv6运行规则：'; os ip6tables-save || return;;
  firewalld)
   need firewall-cmd firewalld firewalld
   say 'Runtime zones:' '运行区域规则：'; os firewall-cmd --list-all-zones || return
   say 'Permanent zones:' '永久区域规则：'; os firewall-cmd --permanent --list-all-zones || return;;
 esac
}
backend_read_ports() {
 # Inspection must work even when the configuration is unsafe to modify.
 case $BACKEND in
  nftables)
   need nft nftables nftables
   NFT_TEXT=$(os nft list ruleset) || die 'cannot read nftables rules';;
  iptables|ufw)
   need iptables-save iptables iptables; need ip6tables-save iptables iptables
   IPT4=$(os iptables-save) || die 'cannot read IPv4 rules'
   IPT6=$(os ip6tables-save) || die 'cannot read IPv6 rules'
   if [[ $BACKEND == ufw ]]; then
    need ufw ufw ufw
    local status; status=$(os ufw status) || die 'cannot query UFW status'
    case $status in 'Status: active'*) UFW_STATE=active;; 'Status: inactive') UFW_STATE=inactive;; *) die 'unknown UFW status';; esac
   fi;;
  firewalld)
   need firewall-cmd firewalld firewalld
   fw_query --state >/dev/null || die 'cannot query firewalld state';;
 esac
}
iptables_shape() {
 # INPUT is protected ahead of all existing rules. Early raw/mangle/security
 # tables can drop before/after filter, so they are outside this safe subset.
 awk '
  /^\*/ && $0 != "*filter" {bad=1}
  END {exit bad}
 ' <<< "$1" || die 'unsupported iptables early tables; no changes'
 [[ $1 == *'*filter'* && $1 == *':INPUT '* && $1 == *':OUTPUT '* ]] || die 'incomplete filter ruleset'
}
nft_shape() {
 # Only one inet table and one input base chain; any additional base-chain
 # accept/drop interactions, raw hooks, maps, includes or output filtering fail.
 local tables
 tables=$(os nft list tables) || die 'Cannot inspect nftables tables'
 [[ -z $(sed '/^table inet filter$/d;/^table inet f2b-table$/d' <<< "$tables") ]] || die 'nftables requires inet filter and optional Fail2ban table; extra base-chain paths refused'
 awk '
  /^[[:space:]]*table / {if ($0 !~ /^table inet filter \{$/) bad=1; next}
  /^[[:space:]]*chain / {chain=$2; if(chain!="input" && chain!="forward" && chain!="output") bad=1; next}
  /hook / {if(chain=="input" && $0 ~ /type filter hook input priority (filter|0); policy (accept|drop);/) input++; else if(chain=="forward" && $0 ~ /type filter hook forward priority (filter|0);/) {} else if(chain=="output" && $0 ~ /type filter hook output priority (filter|0); policy accept;/) {} else bad=1; next}
  /^[[:space:]]*}/ || /^[[:space:]]*$/ {next}
  chain=="output" && $0 !~ /comment "server-guard"/ {bad=1}
  /flowtable |set |map |include |hook |jump |goto / {bad=1}
  /^[[:space:]]*(flush|delete|add|insert|replace|destroy)[[:space:]]/ {bad=1}
  END {exit (bad || input!=1)}
 ' <<< "$NFT_TEXT" || die 'unsupported nftables rule shape; no changes'
}
fw_query() {
 if [[ ${FW_OFFLINE:-0} == 1 ]]; then
  local -a args=("$@")
  [[ ${args[0]:-} != --permanent ]] || args=("${args[@]:1}")
  case ${args[0]:-} in --state|--get-active-zones) return 0;; --get-active-policies) args=(--get-policies);; esac
  os firewall-offline-cmd --system-config "$ROOT/etc/firewalld" "${args[@]}"
 else os firewall-cmd "$@"; fi
}
fw_target() {
 local layer=$1 kind=$2 name=$3 output
 if [[ $layer == permanent ]]; then fw_query --permanent "--$kind=$name" --get-target
 else
  output=$(fw_query "--$kind=$name" --list-all) || return
  sed -n 's/^[[:space:]]*target: //p' <<< "$output"
 fi
}
fw_bool() {
 if fw_query "$@" >/dev/null 2>&1; then echo yes; else local rc=$?; [[ $rc == 1 ]] || return "$rc"; echo no; fi
}
fw_simple() {
 local zone prop value option prefix policy rules; local -a args=()
 for prefix in runtime permanent; do
  args=(); [[ $prefix == runtime ]] || args+=(--permanent)
  # Reject policies/direct paths; lack of reliable introspection is fail-closed.
  value=$(fw_query "${args[@]}" --get-policies) || die 'firewalld policy introspection unsupported'
  for policy in $value; do
   [[ $policy == allow-host-ipv6 ]] || die 'custom firewalld policies unsupported'
   [[ $(fw_target "$prefix" policy "$policy") == CONTINUE ]] || die 'modified IPv6 host policy refused'
   rules=$(fw_query "${args[@]}" --policy="$policy" --list-rich-rules) || die 'cannot inspect host policy'
   while IFS= read -r value; do [[ -z $value || $value =~ ^rule\ family=\"ipv6\"\ icmp-type\ name=\"[a-z-]+\"\ accept$ ]] || die 'modified host policy rich rule refused'; done <<< "$rules"
  done
  for option in --get-all-rules --get-all-passthroughs; do
   value=$(fw_query "${args[@]}" --direct "$option") || die 'cannot inspect firewalld direct rules'
   [[ -z $value ]] || die 'firewalld direct paths unsupported'
  done
  for zone in $FW_ZONES; do
   [[ $zone =~ ^[A-Za-z0-9_-]+$ ]] || die 'invalid firewalld zone'
   for prop in rich-rules forward-ports source-ports protocols icmp-blocks; do
    value=$(fw_query "${args[@]}" --zone="$zone" --list-"$prop") || die 'cannot inspect zone'
    [[ -z $value ]] || die "complex firewalld zone $zone ($prop) refused"
   done
   for option in masquerade icmp-block-inversion; do
    if fw_query "${args[@]}" --zone="$zone" --query-"$option" >/dev/null 2>&1; then die "complex firewalld zone $zone ($option) refused"; else [[ $? == 1 ]] || die 'unsupported zone introspection'; fi
   done
   value=$(fw_target "$prefix" zone "$zone") || die 'cannot inspect target'
   [[ $value == default || $value == ACCEPT || $value == DROP || $value == REJECT || $value == '%%REJECT%%' ]] || die 'unsupported zone target'
   if [[ $prefix == runtime ]]; then
    [[ $value == "$(fw_target permanent zone "$zone")" ]] || die 'runtime/permanent target mismatch refused'
    value=$(fw_bool --zone="$zone" --query-forward) || die 'forward introspection unsupported'
    [[ $value == "$(fw_bool --permanent --zone="$zone" --query-forward)" ]] || die 'runtime/permanent forwarding mismatch refused'
   fi
  done
 done
}
firewall_service_preflight() {
 local service status tables
 case $BACKEND in
  ufw|firewalld|nftables) service=$BACKEND;;
  iptables) [[ $FAMILY == debian ]] && service=netfilter-persistent || service='iptables ip6tables';;
 esac
 if [[ $ACTION != firewall-disable ]]; then
  for service in $service; do
   status=$(os systemctl is-enabled "$service" 2>/dev/null || true)
   [[ $status != masked* ]] || die 'Firewall service was masked by administrator / 防火墙已被管理员屏蔽，请先检查'
  done
 fi
 if [[ $BACKEND == nftables && $ACTION == firewall-disable ]]; then
  tables=$(os nft list tables) || die 'Cannot inspect nftables tables'
  ! grep -qx 'table inet f2b-table' <<< "$tables" || die 'Stopping nftables may flush Fail2ban rules; use UFW/firewalld lifecycle management / nftables停止服务可能清除Fail2ban规则，当前拒绝执行'
 fi
}
backend_preflight() {
 FW_OFFLINE=0
 case $ACTION in firewall-start|firewall-restart|firewall-disable) firewall_service_preflight;; esac
 case $BACKEND in
  nftables)
   need nft nftables nftables
   NFT_TEXT=$(os nft list table inet filter 2>/dev/null || true)
   if [[ -n $NFT_TEXT ]]; then nft_shape
   elif [[ $ACTION != firewall-start && $ACTION != firewall-restart && $ACTION != firewall-disable ]]; then die 'nft filter table missing'; fi
   if [[ -f $ROOT/etc/nftables.conf ]]; then
    local runtime_nft=$NFT_TEXT; NFT_TEXT=$(cat "$ROOT/etc/nftables.conf"); nft_shape; NFT_TEXT=$runtime_nft
   fi
   if has iptables-save; then [[ -z $(os iptables-save) ]] || die 'iptables rules conflict with nftables'; fi
   os systemctl cat nftables >/dev/null || die 'nftables persistent service missing';;
  iptables|ufw)
   need iptables-save iptables iptables; need ip6tables-save iptables iptables
   need iptables-restore iptables iptables; need ip6tables-restore iptables iptables
   IPT4=$(os iptables-save) || die 'IPv4 snapshot failed'; IPT6=$(os ip6tables-save) || die 'IPv6 snapshot failed'
   if [[ -n $IPT4$IPT6 ]]; then iptables_shape "$IPT4"; iptables_shape "$IPT6"
   else case $ACTION in firewall-start|firewall-restart|firewall-disable) :;; *) die 'incomplete filter ruleset';; esac; fi
   if [[ $BACKEND == iptables ]]; then
    local persist
    for persist in etc/iptables/rules.v4 etc/iptables/rules.v6 etc/sysconfig/iptables etc/sysconfig/ip6tables; do
     [[ ! -f $ROOT/$persist ]] || iptables_shape "$(cat "$ROOT/$persist")"
    done
   fi
   # nft-backed iptables tables are expected. Other families/tables are not.
   if has nft; then
    local tables; tables=$(os nft list tables) || die 'cannot inspect competing nft rules'
    [[ -z $(sed '/^table ip filter$/d;/^table ip6 filter$/d;/^table inet f2b-table$/d' <<< "$tables") ]] || die 'foreign nftables tables conflict with iptables/UFW'
   fi
   if [[ $BACKEND == ufw ]]; then
    need ufw ufw ufw
    local ufw_status; ufw_status=$(os ufw status) || die 'cannot query UFW status'
    if [[ $ufw_status != 'Status: active'* ]]; then
     case $ACTION in firewall-start|firewall-restart|firewall-disable) [[ $ufw_status == 'Status: inactive' ]] || die 'Unknown UFW state';; *) die 'UFW is inactive; choose 19 to start it / UFW未启用，请选19启动后再修改端口';; esac
    fi
    [[ -f $ROOT/etc/ufw/before.rules && -f $ROOT/etc/ufw/before6.rules ]] || die 'UFW persistent rule files missing'
    ufw_persistent_preflight "$ROOT"
    ufw_early_paths "$IPT4"; ufw_early_paths "$IPT6"
   elif [[ $FAMILY == debian ]]; then os systemctl cat netfilter-persistent >/dev/null || die 'install iptables-persistent explicitly for persistence'
   else os systemctl cat iptables ip6tables >/dev/null || die 'install iptables-services explicitly for persistence'; fi;;
  firewalld)
   need firewall-cmd firewalld firewalld
   if ! os systemctl is-active --quiet firewalld; then
    case $ACTION in firewall-start|firewall-restart|firewall-disable) FW_OFFLINE=1; need firewall-offline-cmd firewalld firewalld;; esac
   fi
   fw_query --state >/dev/null || die 'firewalld is inactive / firewalld未运行'
   FW_ZONES=$(fw_query --get-zones) || die 'cannot list firewalld zones'
   [[ -n $FW_ZONES ]] || die 'no firewalld zones'
   fw_query --get-active-zones >/dev/null || die 'cannot inspect active zones'
   local tables cleanup
   need nft nftables nftables
   tables=$(os nft list tables) || die 'cannot inspect firewalld nft paths'
   [[ -z $(sed '/^table inet firewalld$/d;/^table inet f2b-table$/d' <<< "$tables") ]] || die 'firewalld requires native table and optional Fail2ban table; foreign tables refused'
   if [[ $FW_OFFLINE == 0 ]]; then grep -qx 'table inet firewalld' <<< "$tables" || die 'firewalld native table missing'; fi
   cleanup=$(sed -n 's/^CleanupOnExit=//p' "$ROOT/etc/firewalld/firewalld.conf" 2>/dev/null || true)
   [[ -z $cleanup || $cleanup == yes ]] || die 'firewalld CleanupOnExit=no prevents safe disable'
   fw_simple;;
  *) die 'unsupported firewall backend';;
 esac
}
backend_snapshot() {
 case $BACKEND in
  nftables) printf '%s\n' "$NFT_TEXT" > "$TX/nft.runtime";;
  iptables|ufw) printf '%s\n' "$IPT4" > "$TX/ipv4.runtime"; printf '%s\n' "$IPT6" > "$TX/ipv6.runtime";;
  firewalld)
   local zone prop
   printf '%s\n' "$FW_ZONES" > "$TX/fw.zones"
   mkdir "$TX/firewalld"
   for zone in $FW_ZONES; do
    for prop in ports services interfaces sources; do fw_query --zone="$zone" --list-"$prop" > "$TX/firewalld/$zone.$prop"; done
   done;;
 esac
}
iptables_build() {
 local input=$1 output=$2 mode=$3 p
 # Remove only our reserved chains. Existing unrelated rules/counters survive.
 awk -v clear="$mode" '
  /^:SG_INPUT / || /^:SG_REPLY / || /^-A SG_INPUT / || /^-A SG_REPLY / || /^-A (INPUT|ufw6?-before-input) -j SG_INPUT$/ || /^-A (OUTPUT|ufw6?-before-output) -j SG_REPLY$/ {next}
  clear=="all" && /^-A / {next}
  clear=="all" && /^:/ {if ($1==":INPUT" || $1==":OUTPUT" || $1==":FORWARD") {print $1 " ACCEPT [0:0]"}; next}
  {print}
 ' "$input" > "$output.clean"
 {
  printf ':SG_INPUT - [0:0]\n:SG_REPLY - [0:0]\n-A INPUT -j SG_INPUT\n-A OUTPUT -j SG_REPLY\n-A SG_INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT\n-A SG_REPLY -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT\n'
  for p in "${PORTS[@]}"; do printf -- '-A SG_INPUT -p tcp --dport %s -j ACCEPT\n' "$p"; done
  if [[ $ACTION != firewall-clear && $ACTION != firewall-disable && $mode != all ]]; then
   awk -v remove="$([[ $ACTION == firewall-edit || $ACTION == firewall-delete ]] && echo "$PORT")" '/^-A SG_INPUT -p tcp --dport [0-9]+ -j ACCEPT$/ && $6!=remove' "$input"
  fi
  printf -- '-A SG_INPUT -j RETURN\n-A SG_REPLY -j RETURN\n'
 } > "$output.owned"
 awk -v file="$output.owned" '
  !inserted && (/^-A / || /^COMMIT$/) {while((getline x < file)>0)print x; close(file); inserted=1}
  {print}
 ' "$output.clean" > "$output"
}
ufw_persistent_preflight() {
 local root=$1 file
 [[ -f $root/etc/default/ufw ]] || die 'UFW IPv6 persistent configuration missing'
 ufw_validate_text "$(cat "$root/etc/default/ufw")" "$(cat "$root/etc/ufw/before.rules")" "$(cat "$root/etc/ufw/before6.rules")"
 for file in after.rules after6.rules user.rules user6.rules; do
  [[ ! -f $root/etc/ufw/$file ]] || ufw_later_paths "$(cat "$root/etc/ufw/$file")"
 done
}
ufw_early_paths() {
 awk '
  /^-/ && $1!="-A" {bad=1}
  /^-A ufw6?-before-logging-(input|output) / {
   target=""; for(i=3;i<=NF;i++){if($i=="-g")bad=1; if($i=="-j")target=$(i+1)}
   if(target!="LOG" && target!="NFLOG" && target!="RETURN")bad=1
  }
  END {exit bad}
 ' <<< "$1" || die 'UFW earlier logging path may reject SSH; no changes'
}
ufw_later_paths() {
 ufw_early_paths "$1"
 # restore -n still flushes a declared user-defined chain. A later file must
 # not redefine/overwrite the protected before path or our reserved chains.
 if grep -Eq '^:(SG_INPUT|SG_REPLY|ufw6?-before-(input|output)) |^-A SG_(INPUT|REPLY) ' <<< "$1"; then die 'later UFW file overrides protected before chains'; fi
}
ufw_validate_text() {
 local ipv6 text prefix=ufw
 ipv6=$(sed -n 's/^[[:space:]]*IPV6=//p' <<< "$1" | tr -d "\"'[:space:]")
 [[ $ipv6 == yes ]] || die 'UFW IPV6=yes required for persistent dual-stack SSH protection; no changes'
 for text in "$2" "$3"; do
  grep -q "^:$prefix-before-input " <<< "$text" && grep -q "^:$prefix-before-output " <<< "$text" || die 'standard dual-stack UFW before-input/output chains required'
  awk '/^\*/ && $0!="*filter" {exit 1}' <<< "$text" || die 'non-filter UFW persistent table refused'
  ufw_early_paths "$text"
  prefix=ufw6
 done
}
ufw_build() {
 local input=$1 output=$2 prefix=ufw
 if grep -q '^:ufw6-before-input ' "$input"; then prefix=ufw6; fi
 iptables_build "$input" "$output.generic" owned
 # UFW installs built-in INPUT/OUTPUT jumps before restore -n. Attach at the
 # head of the before chains, not at the tail of already populated built-ins.
 sed "s/^-A INPUT -j SG_INPUT$/-A $prefix-before-input -j SG_INPUT/;s/^-A OUTPUT -j SG_REPLY$/-A $prefix-before-output -j SG_REPLY/" "$output.generic" > "$output"
}
persist_iptables() {
 local path4 path6 mode=$1 base4 base6
 if [[ $FAMILY == debian ]]; then path4=$ROOT/etc/iptables/rules.v4; path6=$ROOT/etc/iptables/rules.v6
 else path4=$ROOT/etc/sysconfig/iptables; path6=$ROOT/etc/sysconfig/ip6tables; fi
 base4=$path4; base6=$path6
 [[ -f $base4 ]] || base4=$TX/v4.new
 [[ -f $base6 ]] || base6=$TX/v6.new
 iptables_build "$base4" "$TX/p4.new" "$mode"
 iptables_build "$base6" "$TX/p6.new" "$mode"
 if [[ $FAMILY == debian ]]; then
  mkdir -p "$ROOT/etc/iptables"
  cp "$TX/p4.new" "$path4"; cp "$TX/p6.new" "$path6"
  os systemctl enable netfilter-persistent
 else
  mkdir -p "$ROOT/etc/sysconfig"
  cp "$TX/p4.new" "$path4"; cp "$TX/p6.new" "$path6"
  os systemctl enable iptables; os systemctl enable ip6tables
 fi
}
nft_build() {
 local input=$1 output=$2 mode=$3 ports
 ports=$({ printf '%s\n' "${PORTS[@]}"; if [[ $mode != all && $ACTION != firewall-clear && $ACTION != firewall-disable ]]; then nft_owned_ports < "$input"; fi; } | awk -v remove="$([[ $ACTION == firewall-edit || $ACTION == firewall-delete ]] && echo "$PORT")" 'NF && $1!=remove' | sort -nu | paste -sd,)
 if [[ $mode == all ]]; then
  printf 'table inet filter {\n chain input {\n type filter hook input priority filter; policy accept;\n }\n}\n' > "$output.base"
 else
  sed '/comment "server-guard"/d' "$input" > "$output.base"
 fi
 awk -v ports="$ports" '
  {print}
  /type filter hook input / {print "  ct state established,related accept comment \"server-guard\""; print "  tcp dport { " ports " } accept comment \"server-guard\""}
  /type filter hook output / {print "  ct state established,related accept comment \"server-guard\""}
 ' "$output.base" > "$output"
}
backend_change() {
 case $ACTION in firewall-start|firewall-restart|firewall-disable) firewall_service_change; return;; esac
 local mode=owned source_tx=$TX zone p prop value
 [[ $SCOPE != all || ($ACTION != firewall-clear && $ACTION != firewall-disable) ]] || mode=all
 case $BACKEND in
  nftables)
   nft_build "$source_tx/nft.runtime" "$TX/nft.new" "$mode"
   { echo 'delete table inet filter'; cat "$TX/nft.new"; } > "$TX/nft.apply"
   os nft -f "$TX/nft.apply"
   local persistent_nft=$ROOT/etc/nftables.conf
   [[ -f $persistent_nft ]] || persistent_nft=$source_tx/nft.runtime
   nft_build "$persistent_nft" "$TX/nft.persistent" "$mode"
   cp "$TX/nft.persistent" "$ROOT/etc/nftables.conf"
   os systemctl enable nftables;;
  iptables|ufw)
   iptables_build "$source_tx/ipv4.runtime" "$TX/v4.new" "$mode"
   iptables_build "$source_tx/ipv6.runtime" "$TX/v6.new" "$mode"
   if [[ $BACKEND == ufw ]]; then
    if [[ $mode == all ]]; then
     # UFW remains the persistent manager. Replace all of its filter inputs,
     # rather than leaving hidden user.rules to reappear on reboot.
     os ufw --force reset
     os ufw default allow incoming
     os ufw default allow outgoing
     os ufw default allow routed
     ufw_build "$ROOT/etc/ufw/before.rules" "$TX/ufw4.new"
     ufw_build "$ROOT/etc/ufw/before6.rules" "$TX/ufw6.new"
     cp "$TX/ufw4.new" "$ROOT/etc/ufw/before.rules"
     cp "$TX/ufw6.new" "$ROOT/etc/ufw/before6.rules"
     if [[ $ACTION == firewall-disable ]]; then os ufw --force disable; else os ufw --force enable; fi
    else
     ufw_build "$ROOT/etc/ufw/before.rules" "$TX/ufw4.new"
     ufw_build "$ROOT/etc/ufw/before6.rules" "$TX/ufw6.new"
     cp "$TX/ufw4.new" "$ROOT/etc/ufw/before.rules"
     cp "$TX/ufw6.new" "$ROOT/etc/ufw/before6.rules"
    fi
   else persist_iptables "$mode"; fi
   os iptables-restore < "$TX/v4.new"
   os ip6tables-restore < "$TX/v6.new";;
  firewalld)
   if [[ $ACTION == firewall-edit || $ACTION == firewall-delete ]]; then
    local layer owned_zone owned_port; local -a layer_args
    while read -r layer owned_zone owned_port; do
     [[ $owned_port == "$PORT" ]] || continue
     layer_args=(); [[ $layer == runtime ]] || layer_args+=(--permanent)
     fw_query "${layer_args[@]}" --zone="$owned_zone" --remove-port="$owned_port/tcp" >/dev/null
    done < "$STATE/firewalld.owned"
    awk -v p="$PORT" '$3!=p' "$STATE/firewalld.owned" > "$TX/firewalld.owned.new"
    cp "$TX/firewalld.owned.new" "$STATE/firewalld.owned"
   fi
   if [[ $mode == all ]]; then
    if [[ $ACTION == firewall-disable ]]; then
     os systemctl stop firewalld; os systemctl disable firewalld
    else
     # Make every target permissive BEFORE reload, then remove rules. This
     # sequence cannot close an SSH path through a previously restrictive zone.
     for zone in $FW_ZONES; do fw_query --permanent --zone="$zone" --set-target=ACCEPT >/dev/null; done
     fw_query --reload
     for zone in $FW_ZONES; do
      for layer in runtime permanent; do
       local -a clear_args=(); [[ $layer == runtime ]] || clear_args+=(--permanent)
       for prop in ports services; do
        value=$(fw_query "${clear_args[@]}" --zone="$zone" --list-"$prop")
        for p in $value; do fw_query "${clear_args[@]}" --zone="$zone" --remove-"${prop%s}=$p" >/dev/null; done
       done
      done
     done
     : > "$STATE/firewalld.owned"
    fi
   else
    if [[ $ACTION == firewall-clear || $ACTION == firewall-disable ]]; then
     if [[ -f $STATE/firewalld.owned ]]; then
      local layer owned_zone owned_port; local -a layer_args
      while read -r layer owned_zone owned_port; do
       [[ $layer =~ ^(runtime|permanent)$ && $owned_zone =~ ^[A-Za-z0-9_-]+$ ]] && port_valid "$owned_port" || die 'invalid owned firewall registry'
       layer_args=(); [[ $layer == runtime ]] || layer_args+=(--permanent)
       fw_query "${layer_args[@]}" --zone="$owned_zone" --remove-port="$owned_port/tcp" >/dev/null
      done < "$STATE/firewalld.owned"
      : > "$STATE/firewalld.owned"
     fi
    fi
    # Add to EVERY zone, not only default: source/interface zones may differ.
    # No rich/direct/custom policy path survived preflight.
    for zone in $FW_ZONES; do
     for p in "${PORTS[@]}"; do
      for layer in runtime permanent; do
       local -a layer_args=(); [[ $layer == runtime ]] || layer_args+=(--permanent)
       value=$(fw_query "${layer_args[@]}" --zone="$zone" --list-ports)
       if [[ " $value " != *" $p/tcp "* ]]; then
        fw_query "${layer_args[@]}" --zone="$zone" --add-port="$p/tcp" >/dev/null
        printf '%s %s %s\n' "$layer" "$zone" "$p" >> "$STATE/firewalld.owned"
       fi
      done
     done
    done
   fi;;
 esac
}
firewall_service_change() {
 local service zone p family source runtime owned_zone owned_port
 if [[ $ACTION == firewall-disable ]]; then
  say 'Stopping the firewall; saved port rules are retained.' '正在关闭防火墙，保留已保存的端口规则。' warning
  case $BACKEND in
   ufw) os ufw --force disable; os systemctl stop ufw; os systemctl disable ufw;;
   firewalld) os systemctl stop firewalld; os systemctl disable firewalld;;
   nftables) os systemctl stop nftables; os systemctl disable nftables;;
   iptables)
    if [[ $FAMILY == debian ]]; then os systemctl stop netfilter-persistent; os systemctl disable netfilter-persistent
    else for service in iptables ip6tables; do os systemctl stop "$service"; os systemctl disable "$service"; done; fi
    printf '*filter\n:INPUT ACCEPT [0:0]\n:FORWARD ACCEPT [0:0]\n:OUTPUT ACCEPT [0:0]\nCOMMIT\n' > "$TX/iptables.stopped"
    os iptables-restore < "$TX/iptables.stopped"; os ip6tables-restore < "$TX/iptables.stopped";;
  esac
 else
  say "Preparing SSH protection before loading $BACKEND rules." "正在准备SSH放行，再加载 $BACKEND 规则。"
  case $BACKEND in
   ufw)
    ufw_build "$ROOT/etc/ufw/before.rules" "$TX/ufw4.new"
    ufw_build "$ROOT/etc/ufw/before6.rules" "$TX/ufw6.new"
    cat "$TX/ufw4.new" > "$ROOT/etc/ufw/before.rules"
    cat "$TX/ufw6.new" > "$ROOT/etc/ufw/before6.rules"
    if [[ $ACTION == firewall-restart && $(os ufw status) == 'Status: active'* ]]; then os ufw reload; else os ufw --force enable; fi
    os systemctl enable ufw
    os systemctl start ufw
    [[ $(os ufw status) == 'Status: active'* ]] || die 'UFW did not activate / UFW未成功启用';;
   firewalld)
    if [[ $FW_OFFLINE == 1 ]]; then
     # Offline writes prepare every zone before a stopped daemon can filter.
     for zone in $FW_ZONES; do
      for p in "${PORTS[@]}"; do
       source=$(fw_query --zone="$zone" --list-ports)
       if [[ " $source " != *" $p/tcp "* ]]; then
        fw_query --zone="$zone" --add-port="$p/tcp" >/dev/null
        printf 'permanent %s %s\nruntime %s %s\n' "$zone" "$p" "$zone" "$p" >> "$STATE/firewalld.owned"
       fi
      done
     done
     os firewall-offline-cmd --system-config "$ROOT/etc/firewalld" --check-config
     os systemctl start firewalld
     FW_OFFLINE=0
    else
     (local ACTION=firewall-protect; backend_change)
     [[ $ACTION != firewall-restart ]] || fw_query --reload
    fi
    os systemctl enable firewalld
    fw_query --state >/dev/null
    for zone in $FW_ZONES; do for p in "${PORTS[@]}"; do fw_query --zone="$zone" --query-port="$p/tcp" >/dev/null || die 'SSH firewall rule missing after activation / 启动后SSH规则核对失败'; done; done;;
   iptables)
    for family in 4 6; do
     if [[ $FAMILY == debian ]]; then source=$ROOT/etc/iptables/rules.v$family
     elif [[ $family == 4 ]]; then source=$ROOT/etc/sysconfig/iptables; else source=$ROOT/etc/sysconfig/ip6tables; fi
     if [[ ! -f $source ]]; then source=$TX/ipv$family.runtime; fi
     [[ -s $source ]] || die 'Saved firewall rules missing; install/enable the firewall first / 缺少已保存规则，请先安装并启用防火墙'
     iptables_build "$source" "$TX/start$family.new" owned
     if [[ $FAMILY == debian ]]; then source=$ROOT/etc/iptables/rules.v$family
     elif [[ $family == 4 ]]; then source=$ROOT/etc/sysconfig/iptables; else source=$ROOT/etc/sysconfig/ip6tables; fi
     mkdir -p "${source%/*}"; cp "$TX/start$family.new" "$source"
    done
    os iptables-restore < "$TX/start4.new"; os ip6tables-restore < "$TX/start6.new"
    if [[ $FAMILY == debian ]]; then os systemctl enable netfilter-persistent; os systemctl start netfilter-persistent
    else for service in iptables ip6tables; do os systemctl enable "$service"; os systemctl start "$service"; done; fi;;
   nftables)
    source=$ROOT/etc/nftables.conf
    [[ -f $source ]] || source=$TX/nft.runtime
    [[ -s $source ]] || die 'Saved nftables rules missing / 缺少已保存nftables规则'
    nft_build "$source" "$TX/nft.start" owned
    cp "$TX/nft.start" "$ROOT/etc/nftables.conf"
    os systemctl start nftables
    { if os nft list table inet filter >/dev/null 2>&1; then echo 'delete table inet filter'; fi; cat "$TX/nft.start"; } > "$TX/nft.apply"
    os nft -f "$TX/nft.apply"
    os systemctl enable nftables;;
  esac
 fi
 printf '%s\n' "$BACKEND" > "$STATE/firewall.backend"
}
protected_port() { local p; for p in "${PROTECTED_PORTS[@]}"; do [[ $p != "$1" ]] || return 0; done; return 1; }
fw_port_unowned_or_inconsistent() {
 local p=$1 zone layer current; local -a args=()
 [[ -f $STATE/firewalld.owned ]] && backend_owned_ports >/dev/null || [[ ! -f $STATE/firewalld.owned ]] || return 0
 for zone in $FW_ZONES; do
  for layer in runtime permanent; do
   args=(); [[ $layer == runtime ]] || args+=(--permanent)
   current=$(fw_query "${args[@]}" --zone="$zone" --list-ports) || return 0
   if [[ " $current " == *" $p/tcp "* ]]; then
    [[ -f $STATE/firewalld.owned ]] && grep -Fxq "$layer $zone $p" "$STATE/firewalld.owned" || return 0
   elif [[ -f $STATE/firewalld.owned ]] && grep -Fxq "$layer $zone $p" "$STATE/firewalld.owned"; then return 0
   fi
  done
 done
 return 1
}
iptables_owned_ports() { awk '/^-A SG_INPUT -p tcp --dport [0-9]+ -j ACCEPT$/ {print $6}' | sort -nu; }
nft_owned_ports() {
 sed -n 's/^[[:space:]]*tcp dport { \([0-9, ]*\) } accept comment "server-guard"$/\1/p' | tr ', ' '\n' | sed '/^$/d' | sort -nu
}
backend_owned_ports() {
 case $BACKEND in
  iptables|ufw) iptables_owned_ports <<< "$IPT4";;
  nftables) nft_owned_ports <<< "$NFT_TEXT";;
  firewalld)
   if [[ -f $STATE/firewalld.owned ]]; then
    awk 'NF!=3 || $1!~/^(runtime|permanent)$/ || $2!~/^[A-Za-z0-9_-]+$/ || $3!~/^[1-9][0-9]*$/ || $3>65535 {exit 1} {print $3}' "$STATE/firewalld.owned" | sort -nu
   fi;;
 esac
}
backend_port_owned() {
 local p=$1 file layer zone current
 case $BACKEND in
  iptables|ufw)
   iptables_owned_ports <<< "$IPT4" | grep -qx "$p" || return 1
   iptables_owned_ports <<< "$IPT6" | grep -qx "$p" || return 1
   if [[ $BACKEND == ufw ]]; then
    for file in etc/ufw/before.rules etc/ufw/before6.rules; do iptables_owned_ports < "$ROOT/$file" | grep -qx "$p" || return 1; done
   else
    if [[ $FAMILY == debian ]]; then local files=(etc/iptables/rules.v4 etc/iptables/rules.v6); else local files=(etc/sysconfig/iptables etc/sysconfig/ip6tables); fi
    for file in "${files[@]}"; do [[ -f $ROOT/$file ]] && iptables_owned_ports < "$ROOT/$file" | grep -qx "$p" || return 1; done
   fi;;
  nftables)
   nft_owned_ports <<< "$NFT_TEXT" | grep -qx "$p" || return 1
   [[ -f $ROOT/etc/nftables.conf ]] && nft_owned_ports < "$ROOT/etc/nftables.conf" | grep -qx "$p" || return 1;;
  firewalld)
   [[ -f $STATE/firewalld.owned ]] || return 1
   backend_owned_ports >/dev/null || return 1
   for zone in $FW_ZONES; do
    for layer in runtime permanent; do
     grep -Fxq "$layer $zone $p" "$STATE/firewalld.owned" || return 1
     local -a args=(); [[ $layer == runtime ]] || args+=(--permanent)
     current=$(fw_query "${args[@]}" --zone="$zone" --list-ports) || return
     [[ " $current " == *" $p/tcp "* ]] || return 1
    done
   done;;
 esac
}
