# 独立服务器保护工具 / Server Guard

`scripts/server-guard/server-guard.sh` 是独立 Bash 工具，不依赖面板、数据库或原安装器。默认不改变系统；必须显式给出 `apply … --apply`。支持中文/英文提示（`--lang zh/en`），`plan` 和 `--dry-run` 只读。需要 root、Bash 4.4+、GNU coreutils/tar、flock、OpenSSH、ss、正常运行的 systemd；防火墙操作还需要所选管理器的命令和持久化服务。缺少依赖时给出 apt/dnf 提示，不会安装软件。

目标发行版为 Debian 11+、Ubuntu 22.04+、Rocky/AlmaLinux/RHEL 8+、CentOS Stream 9+；CentOS 7 明确拒绝。此版本已做隔离 Bash 事务和命令适配器验证，**尚未完成这些发行版上的真实公网 SSH、重启及防火墙内核验收**。不能据此承诺绝不掉线。实际使用前应准备云厂商救援控制台，并先在云安全组放行新端口；工具不能修改云安全组。

## 使用

以下命令在 Linux Bash 执行。sudo 必须保留真实 SSH 会话环境；工具不会在环境丢失时猜测 22 端口。

### 中文终端菜单

进入已校验、解压的 `server-guard` 目录，在 SSH 交互终端运行一条命令即可打开中文菜单：

```bash
sudo --preserve-env=SSH_CONNECTION bash ./server-guard.sh
```

菜单提供端口查看/添加/修改/删除、SSH 端口切换、状态及 Fail2ban 查看/启停、防火墙关闭/清空/还原、事务确认与回退。状态同时区分 Fail2ban 服务与本工具的 SSH jail。输入编号选择功能；普通变更前会显示只读预览，输入“确认”才执行；手工回退须输入有效事务编号并再次确认。执行后若出现待确认事务，须从同一管理来源新建 SSH 连接，再在菜单选择“确认变更”并输入事务编号；切换 SSH 端口时必须通过新端口连接。超时仍由现有独立任务回退。退出菜单输入 `0`。菜单只接受 `--lang zh/en`，不接受 `--dry-run` 等其它选项；非交互环境请继续使用下列明确的子命令。英文菜单可用 `bash ./server-guard.sh menu --lang en`。

菜单 `7 启用 Fail2ban` 和 `8 停用 Fail2ban` 不要求先启用 UFW/firewalld。若选择端口、防火墙或 SSH 变更时提示“未检测到受支持防火墙”，先确认当前 SSH 端口在云安全组中放行、保持现有 SSH 会话并准备救援控制台，再按系统配置一个管理器：Debian/Ubuntu 使用 UFW，RHEL/Rocky/Alma 使用 firewalld。启用管理器前须在其规则中放行当前 SSH 端口；完成后重新运行菜单。脚本不会替用户安装或启动防火墙，也不会自动改动云安全组。

The no-argument entry point opens an interactive terminal menu in Chinese. Choose a numbered action, review its plan, then type `确认` to apply. The English menu is available with `menu --lang en`. Non-interactive automation should use the commands below.

### 自动化子命令

```bash
sudo --preserve-env=SSH_CONNECTION bash scripts/server-guard/server-guard.sh status
sudo --preserve-env=SSH_CONNECTION bash scripts/server-guard/server-guard.sh ports
sudo --preserve-env=SSH_CONNECTION bash scripts/server-guard/server-guard.sh plan firewall-allow --port 8443
sudo --preserve-env=SSH_CONNECTION bash scripts/server-guard/server-guard.sh apply firewall-allow --port 8443 --apply
sudo --preserve-env=SSH_CONNECTION bash scripts/server-guard/server-guard.sh apply firewall-edit --port 8443 --to-port 8543 --apply
sudo --preserve-env=SSH_CONNECTION bash scripts/server-guard/server-guard.sh apply firewall-delete --port 8543 --apply
sudo --preserve-env=SSH_CONNECTION bash scripts/server-guard/server-guard.sh apply ssh-port --port 2299 --timeout 180 --apply
```

每次变更输出一个事务编号。在同一管理来源地址、同一服务器地址的**新 SSH 连接**中确认；SSH 端口变更必须经新端口建立连接。连接元组还须存在于 `ss` 的已建立连接列表中。旧连接不能确认。旧端口默认保留，工具不默认禁用密码或 root 登录。

```bash
# 在新SSH连接中，将事务编号替换为真实输出：
sudo --preserve-env=SSH_CONNECTION bash scripts/server-guard/server-guard.sh confirm --id 20261030120000-0123456789abcdef --apply
# 手工回退无需SSH环境，救援控制台也可使用：
sudo bash scripts/server-guard/server-guard.sh rollback --id 20261030120000-0123456789abcdef --apply
```

`--timeout` 范围 30–3600 秒，默认 180 秒。一台机器同时只允许一个待确认事务；先确认或回退再继续。`--backend nftables|iptables|ufw|firewalld` 可明确选择后端，但不能绕过已有管理器冲突检查。

## 动作与范围

| 动作 | 默认范围及行为 | `--scope all` |
| --- | --- | --- |
| `firewall-allow --port N` | 放行 TCP 端口；保留以前自有放行及现有无关规则 | 不用于此动作 |
| `ports` | 只读列出受保护 SSH 端口及本工具放行的普通 TCP 端口 | 不适用 |
| `firewall-edit --port OLD --to-port NEW` | 将本工具自有普通端口改为新端口；原端口须完整存在于运行与持久规则 | 不用于此动作 |
| `firewall-delete --port N` | 删除本工具自有普通端口；受保护 SSH 端口不可删除 | 不用于此动作 |
| `firewall-clear` | 移除自有普通端口规则，重新保留全部受保护 SSH 端口和已有连接 | 清空所支持的整机过滤规则并改为放行；必须显式指定 |
| `firewall-disable` | 同上，仅撤销自有普通端口规则 | nftables/iptables 改为持久的放行策略；UFW/firewalld 关闭其防火墙管理器 |
| `firewall-restore --id ID` | 从选定事务的**变更前**备份还原防火墙运行和持久状态，并补回当前 SSH 保护；本次还原本身也是可回退事务 | 不用于此动作 |
| `ssh-port --port N` | 先保护新旧端口，再预置全局 Port、`sshd -t` 校验并 reload；保留原配置和 Include | 不用于此动作 |
| `fail2ban-enable` / `fail2ban-disable` | 仅管理 `server-guard-sshd` jail 的专属文件；启用前后校验配置 | 不用于此动作 |

`firewall-disable --scope all` 在 nftables/iptables 上保留持久化服务，但有效过滤策略为放行；这样不会误停止一个服务并遗留旧规则。UFW 全量清空使用其 reset/default 命令建立持久放行策略；关闭则保持禁用。firewalld 全量清空先将所有区域的永久 target 设为 ACCEPT，再 reload，随后清理服务/端口条目；关闭使用 stop/disable，预检要求 `CleanupOnExit` 为默认值或 yes。

## 后端覆盖与拒绝边界

| 后端 | 已实现动作 | 安全支持范围 | 预检拒绝 |
| --- | --- | --- | --- |
| nftables | 放行、自有/全部清空、放行策略关闭、还原 | 唯一 `inet filter` 表，唯一普通优先级 input base chain；可含 forward；output 只允许无过滤的 ACCEPT 路径；IPv4/IPv6 一并保护 | 额外表/base chain、早期 hook、非标准链、jump/goto、map/set/include、输出过滤等无法确定安全路径的结构 |
| iptables | 放行、自有/全部清空、放行策略关闭、还原 | IPv4/IPv6 两套 filter 表，INPUT 前置保护链及 OUTPUT 已有连接链；Debian 使用 netfilter-persistent，RHEL 使用 iptables/ip6tables services | raw/mangle/nat/security 表、竞争 nft 表、缺少任一双栈命令或持久化服务 |
| UFW | 放行、自有/全部清空、关闭、还原 | 标准 before.rules/before6.rules、filter 表、`IPV6=yes`；分别在 `ufw-before-input/output` 和 `ufw6-before-input/output` 的最前方保护；校验备份支持停用态还原 | 非 filter 早期表、竞争管理器、缺少标准链/IPv6开关；更早的 before-logging 链存在非日志/返回路径；after/user 文件重定义保护链 |
| firewalld | 放行、自有/全部清空、关闭、还原 | 原生 nftables 后端、唯一 `inet firewalld` 表；逐区域处理，包含非默认区域；运行/永久的端口、服务、接口、来源分别恢复 | direct/passthrough、自定义 policy、复杂 rich rule、端口转发/伪装等、运行/永久 target 或 forward 不一致、缺少可靠 introspection 的旧版本；默认 `allow-host-ipv6` 只接受受限的纯 IPv6 ICMP accept 规则 |

未知规则布局应由管理员先审查，不用 `--backend` 强行覆盖。工具假设防火墙由检测到的管理器独占管理；不会接管 Docker/Kubernetes、额外网络命名空间、tc/XDP 或其他进程并发写入的规则。以上是明确的支持子集，不代表任意防火墙配置均受支持。系统服务单位应使用发行版标准持久化配置路径；自定义加载路径需人工适配。

批量撤销自有普通端口放行使用显式 `firewall-clear`/`firewall-disable`；`firewall-edit`/`firewall-delete` 只移除指定旧端口的放行，保留其他普通端口。SSH、Fail2ban 及追加放行动作保留已经确认的普通端口；restore 保留目标备份内已有的自有端口。UFW 预检同时审视运行规则及 before/after/user 双栈持久文件，因为 before-logging 链早于 before 链，且 user 文件可在后续加载中重置链。无法证明安全的早期跳转或链覆盖直接拒绝。

UFW/firewalld 已确认整机关闭后，可直接 `apply firewall-restore --id ID --apply`，后端从校验通过的备份确定，不需要手工启动管理器。工具先快照当前停用状态并建立持久回退，再为目标持久配置补充当前 SSH 端口，最后启用加载。firewalld 使用 `firewall-offline-cmd --system-config … --check-config/--zone/--add-port`，缺少命令明确拒绝；停用态存在其他防火墙规则也会拒绝。还原失败或超时会恢复此前的停用状态。仍未完成真实机器的关闭→重启→还原验收。

SSH 保护端口取并集：`SSH_CONNECTION` 的服务器端口、`sshd -T` 的有效 Port、`ss -ltnp` 中实际 sshd 监听端口、新请求端口。任何关键发现失败都会拒绝。SSH socket 激活（包括已启用但未启动的 socket）暂不支持。SELinux Enforcing/Permissive 的端口事务已实现并通过受控模型验证，真实 Enforcing 内核与发行版服务仍待验收。

普通端口的查看、添加、修改、删除均是独立脚本命令；变更仍需 `--apply`，并按原有新连接确认或超时回退。修改和删除只接受工具自有且运行/持久状态一致的普通 TCP 端口，禁止改删受保护 SSH 端口；firewalld 对外部已有放行或所有权记录异常会拒绝。`ports` 不创建事务。English: `ports` lists protected SSH and tool-owned TCP ports. `firewall-allow`, `firewall-edit`, and `firewall-delete` manage only supported tool-owned rules; edits and deletes reject protected SSH ports and inconsistent ownership. Mutations still require `--apply` and the existing confirmation or rollback flow.

### SELinux 端口事务 / SELinux port transactions

Disabled 不需要 semanage。Enforcing/Permissive 需要 `getenforce`、`semanage`、`seinfo`、`restorecon`、`matchpathcon`、`chcon`；Debian/Ubuntu 对应 `selinux-utils`、`policycoreutils`、`policycoreutils-python-utils`、`setools`、`coreutils`，RHEL 家族的 `seinfo` 通常来自 `setools-console`，其余为 `libselinux-utils`、`policycoreutils`、`policycoreutils-python-utils`、`coreutils`。不会自动安装。缺少 getenforce 时必须从可读的活动内核文件系统/挂载信息确认 SELinux 未初始化；查询失败或状态未知直接拒绝。

读取 `LC_ALL=C semanage port -l -n`、`-l -n -C`、`-E`，并通过只读 `seinfo --portcon -x --flat /sys/fs/selinux/policy` 核对活动完整上下文，按协议、精确键、范围和本地覆盖交叉校验；查询不可用或数据不一致即拒绝。已有 `ssh_port_t` 单端口或不歧义范围复用且不删除。只有基础策略的已知通用默认范围（`port_t` 1–65535、`unreserved_port_t` 1024–65535、`reserved_port_t` 1–511 或 1–1023、`hi_reserved_port_t` 512–1023）可被新 SSH 单端口覆盖；基础或本地目标的非默认 MLS/MCS、其他服务类型、歧义范围、格式不完整均拒绝。UDP 同号端口不与 TCP 冲突。要求可读的标准 selinuxfs 路径 `/sys/fs/selinux/mls`。MLS 开启时只接受目标 `s0`，关闭时必须没有范围；该内核状态随快照保存并在后续核对。新增请求 `s0`，无 MLS 内核按官方语义忽略范围，按无范围记录验证。不支持自定义 MLS/MCS 级别迁移。

受保护快照包含完整/本地策略、活动上下文、原 SSH 文件上下文与摘要。配置归档和恢复使用 GNU tar `--selinux`，保留所重建文件及目录的原标签；独立 timer/boot runner 准备并落盘后再次核对目标策略，持久记录新增意图，才执行 `semanage port -a -t ssh_port_t -p tcp -r s0 N` 并读回验证，随后修改 SSH 配置及 reload。文件标签恢复/校验失败时停止；新 runner 与 unit 使用 restorecon/matchpathcon，SSH 文件恢复原上下文。确认还要复核授权，保留新增授权。失败或未确认恢复先还原 SSH 配置/标签并 reload，再精确 `semanage port -d -p tcp N`。只删除本事务新增授权，绝不修改其他服务类型、关闭 SELinux 或导入整库策略。

写入后报错与已删后的重试均由落盘意图和读回状态判断。目标的类型、端口范围或 MLS 被外部修改时保留 pending 并报告冲突，由管理员核查后重试；无关端口的外部变更保留。旧格式事务没有新增授权所有权。工具只锁自己的事务，**要求变更期间没有其他管理器并发写同一端口或更新隐藏的基础策略**，不声称拥有 SELinux 策略库的跨进程事务锁。真实内核加载、systemd 重启与公网 SSH 尚未验证。

首次 SELinux 版本的 schema-2 待确认事务仍可用新版命令确认或回退：按其原快照核对精确本地授权及新增意图，只删除本事务新增的映射；该旧快照没有活动基础策略完整 MLS 记录，不能追溯核对。新建事务使用包含活动上下文的 schema-3。English: Pending schema-2 transactions remain confirmable and recoverable using their original checksummed ownership evidence; only an exact mapping added by that transaction may be deleted. Their missing active base context cannot be reconstructed. New transactions use schema-3 checks.

English: Enforcing and Permissive preserve their mode. Server Guard compares full/local listings and the local export against complete active `seinfo --portcon` contexts; missing or nondefault base MLS/MCS data fails closed. It reuses existing SSH mappings, rejects service conflicts and customized generic ranges, and adds only one exact TCP `ssh_port_t` mapping at `s0`. The readable kernel MLS mode is captured and rechecked. GNU tar `--selinux` saves and restores labels for rebuilt configuration trees before services start. A durable recovery runner and checksummed snapshot precede the durable add intent and policy write. Authorization is verified before SSH reload and again before confirmation. Rollback restores the original SSH configuration/context and reloads SSH before deleting only its own exact mapping. Failed deletes retain pending state for retry; unrelated changes survive. Nonstandard MLS/MCS migration and concurrent writers are unsupported. Tests use a controlled policy model, not a real Enforcing kernel or public SSH connection.

Fail2ban 写入 `/etc/fail2ban/jail.d/server-guard.local`，只包含 `[server-guard-sshd]`，使用 sshd filter/systemd backend。端口覆盖所有受保护端口，ignoreip 包含当前管理来源及环回地址；不会清空或改写用户的其他 jail。用户已有 jail 的封禁策略由用户自行管理。

Fail2ban 服务能够启动与实际封禁生效是两件事；封禁仍取决于机器上可用的 Fail2ban `banaction` 和内核过滤规则。完成变更后，可从新的 SSH 连接确认事务，并用菜单 `6 查看状态` 或 `fail2ban-client status server-guard-sshd` 核对 jail；实际封禁效果留待真实服务器验收。

## 回退与数据

状态目录固定为 `/var/lib/server-guard`，要求 root 所有、0700；备份/元数据 0600，使用 flock 排他锁。参数、事务 ID、端口、来源地址和路径经过校验；不 eval、不 source 用户参数。固定模块来自已校验的同一工具包。拒绝符号链接状态和可被其他用户修改的状态树。

systemd 单位目录内的正常启用链接可保留；工具只严格校验自己写入的三个 unit、相应父路径及两个启用链接的目标，不递归拒绝整个系统 unit 目录。测试适配器实际创建/移除 enable/disable 链接，并维护管理器运行状态。

事务先保存运行规则、相关 `/etc` 配置、服务启用/运行状态，再落盘独立 runner、`server-guard-rollback.service/.timer` 和 `server-guard-boot.service`。timer 使用 `OnCalendar`、`Persistent=true`；启动检查服务发现待确认事务即回退。必须验证 timer active、下一次触发时间确在未来、启动检查已启用，才能开始网络写入。service 的失败重启用于重试，故不依赖原 SSH shell。时钟严重异常、损坏的系统盘或不可用的 systemd 仍需救援控制台处理。

失败补偿会恢复配置、服务状态及独立运行规则；firewalld 先恢复永久文件并 reload，再重建原运行差异，**不使用 runtime-to-permanent**。回退失败保留 pending、备份与回退任务，供服务重试或管理员再次执行 rollback。只有确认成功或回退完成后才撤销回退调度。审计只记时间、动作和编号，不记口令。禁用后的 unit/runner 保留供审计；勿在有待确认事务时删除状态目录。

## 固定版本分发

目前没有指定发布仓库，也没有自行发布。`fetch.sh` 只下载、校验和解包，不执行下载内容。在线模式要求用户指定 `--repo`、固定 release `--version` 和从可信渠道取得的 `--sha256`；拒绝 latest/main/master/HEAD。校验整个多文件包，限制成员清单，拒绝软/硬链接、设备文件、重复成员及覆盖目标目录。

```bash
# 用真实仓库、固定发布版本和SHA256替换尖括号内容：
bash scripts/server-guard/fetch.sh --repo '<owner>/<repo>' --version '<fixed-release>' --sha256 '<64-hex-digest>' --output ./verified-server-guard
# 离线方式：
bash scripts/server-guard/fetch.sh --archive ./server-guard.tar.gz --sha256 '<64-hex-digest>' --output ./verified-server-guard
```

发布包根目录为 `server-guard/`，必须包含 `server-guard.sh`、`backends.sh`、`selinux.sh`、`fetch.sh`，可附 `SERVER_GUARD.md`。GitHub 地址由参数明确构造为 `https://github.com/<repo>/releases/download/<version>/server-guard.tar.gz`；它不是当前已经存在的发布承诺。SHA256 固定内容身份，即使发布标签被更改也不能绕过校验。审阅解包文件后再用 Bash 执行。

## 本地验证

```bash
bash scripts/server-guard/tests/guard_test.sh
GUARD_TEST_FOCUS=selinux bash scripts/server-guard/tests/guard_test.sh
GUARD_TEST_FOCUS=ports bash scripts/server-guard/tests/guard_test.sh
bash -n scripts/server-guard/server-guard.sh
```

夹具需要 root 和预先准备的独立 `TMPDIR`，其 Unix 权限必须实际有效。测试根有专用 marker 且为 root 0700；先 realpath 再校验，`//`、`/./` 无法绕过生产路径限制。所有网络/服务命令经过严格适配器，未知命令直接失败。测试运行真实 Bash、文件备份、锁和状态机，并只读调用 systemd-analyze 校验生成 unit；没有调用宿主真实防火墙、SSH 或 systemd 写操作。暂未执行真实内核防火墙、真实重启或公网连接验收。

语义依据：[firewalld 运行与永久配置](https://firewalld.org/documentation/configuration/runtime-versus-permanent.html)、[firewall-cmd](https://firewalld.org/documentation/man-pages/firewall-cmd.html)、[firewall-offline-cmd](https://firewalld.org/documentation/man-pages/firewall-offline-cmd.html)、[UFW 加载顺序](https://sources.debian.org/src/ufw/0.36-1/src/ufw-init-functions/)、[nftables 链与 hook](https://wiki.netfilter.org/wiki-nftables/index.php/Configuring_chains)、[systemd.timer](https://www.freedesktop.org/software/systemd/man/247/systemd.timer.html)。

SELinux 依据：[Red Hat SSH 端口配置](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/securing_networks/using-secure-communications-between-two-systems-with-openssh)、[官方 semanage-port 手册](https://github.com/SELinuxProject/selinux/blob/3.6/python/semanage/semanage-port.8)、[portRecords 源码（精确键、列表与 MLS 导出）](https://github.com/SELinuxProject/selinux/blob/3.6/python/semanage/seobject.py)、[SETools seinfo 源码](https://github.com/SELinuxProject/setools/blob/main/seinfo)、[GNU tar SELinux 上下文说明](https://www.gnu.org/software/tar/manual/tar.html)、[基础策略默认范围](https://github.com/SELinuxProject/refpolicy/blob/RELEASE_2_20240226/policy/modules/kernel/corenetwork.te.in)、[内核 selinuxfs 初始化与 MLS 状态](https://github.com/torvalds/linux/blob/v6.6/security/selinux/selinuxfs.c)。
