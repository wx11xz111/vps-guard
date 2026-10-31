# 独立服务器保护工具 / Server Guard

VPS Guard 提供防火墙端口、SSH 端口及 Fail2ban 管理，不依赖面板或数据库。操作前预览并输入 Y/y 才执行；**成功后立即生效**，没有变更后的二次确认、待确认锁定、超时回退或手工回退入口。同一 SSH 会话可以连续执行操作。

## 安装与启动

在 Linux SSH 交互终端运行，需要 root 或 sudo、Bash 4.4+、curl、GNU coreutils/tar、flock、OpenSSH、ss 和发行版服务管理工具：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wx11xz111/vps-guard/main/bootstrap.sh)
vps-guard
```

安装器校验固定提交及 SHA256 后安装脚本，不启用防火墙或修改 SSH 配置。已有旧版时重新执行上述安装命令即可更新。普通用户启动时通过 sudo 提权，保留 SSH_CONNECTION 与 NO_COLOR。

支持 Debian 11+、Ubuntu 22.04+、Rocky/AlmaLinux/RHEL 8+、CentOS Stream 9+；不支持 CentOS 7。需要修改防火墙时，还需相应管理器命令及持久化服务；只读查询不要求持久化组件。菜单 1 可安装防火墙，菜单 7/17 可安装 Fail2ban。

## 菜单与颜色

| 编号 | 功能 |
| --- | --- |
| 1 | 安装并启用防火墙 |
| 2 / 3 / 4 / 5 | 查看、添加、修改、删除本工具端口 |
| 6 | 切换 SSH 端口，保留原端口 |
| 7 / 8 | 安装并启用、停用本工具 Fail2ban jail |
| 9 | 查看状态 |
| 10 | 关闭防火墙 |
| 11 / 12 | 清空本工具端口、清空受支持的整机规则 |
| 16 | 查看实际防火墙规则 |
| 17 | 配置防爆破参数 |
| 18 | 查看配置备份及执行结果 |
| 0 | 退出 |

原编号 13/14/15 的恢复、确认和回退功能已移除，其他编号保留。操作前仍有 `[y/N]`：Y/y 执行，N/n、回车或输入结束取消；其他输入重新提示。没有执行后的确认步骤。

青蓝色用于标题和查看信息，绿色用于启用及成功状态，黄色用于提醒或执行前确认，红色用于错误、删除和清空，紫色用于输入，灰色用于退出或取消。重定向、管道、TERM=dumb 或非空 NO_COLOR 使用纯文本；错误颜色按 stderr 是否连接终端判断。例如 `NO_COLOR=1 vps-guard`。

## 立即执行与旧版迁移

端口、SSH及Fail2ban变更使用进程锁防止同时运行，保存配置和运行规则备份后执行。完成后显示“已生效”和备份编号，不创建 pending、回退 timer、启动回退 service 或独立 runner。不需要新 SSH 会话，也不会因为上一笔操作未确认而拒绝下一笔操作。

失败时记录 `failed` 并报告备份编号，**不自动恢复之前的配置或规则**；部分已完成的步骤会保留当前结果。SSH 候选配置在修改防火墙和主配置前先运行 `sshd -t` 校验；安装阶段清理临时服务 mask 的行为仍保留。

升级后首次进入菜单或执行变更时，会在锁内停用本工具旧版的 `server-guard-rollback.timer`、`server-guard-rollback.service` 和 `server-guard-boot.service`，将旧 pending 记录归档为 `/var/lib/server-guard/legacy-pending.*`，保留当前配置及原备份。停止旧任务失败时中止新操作，不悄悄删记录。只读 status/ports/rules/backups 不执行迁移。

旧 confirm、rollback、firewall-restore 和 --timeout/--id 参数已移除。`recover --apply` 仅作为兼容入口停用旧任务并归档记录，不会恢复防火墙、SSH 或 SELinux 配置。

## 命令行

菜单只接受 `--lang zh/en`，默认中文。非交互使用明确的子命令，写操作必须加 --apply：

```bash
sudo --preserve-env=SSH_CONNECTION bash ./server-guard.sh ports
sudo bash ./server-guard.sh rules
sudo bash ./server-guard.sh backups
sudo bash ./server-guard.sh status
sudo --preserve-env=SSH_CONNECTION bash ./server-guard.sh plan firewall-allow --port 8443
sudo --preserve-env=SSH_CONNECTION bash ./server-guard.sh apply firewall-allow --port 8443 --apply
sudo --preserve-env=SSH_CONNECTION bash ./server-guard.sh apply firewall-edit --port 8443 --to-port 8543 --apply
sudo --preserve-env=SSH_CONNECTION bash ./server-guard.sh apply firewall-delete --port 8543 --apply
sudo --preserve-env=SSH_CONNECTION bash ./server-guard.sh apply ssh-port --port 54411 --apply
sudo --preserve-env=SSH_CONNECTION bash ./server-guard.sh apply fail2ban-enable --maxretry 5 --findtime 600 --bantime 3600 --apply
```

plan 和 --dry-run 仅预览，不安装、不创建备份、不迁移旧任务。ports 列出 SSH 保护端口及本工具普通 TCP 端口；rules 显示实际管理器规则，包括本工具之外的规则。UFW 同时显示编号规则和 show raw；iptables 输出双栈运行快照；nftables 输出运行规则；firewalld 输出运行与永久区域。

菜单 2 单独显示 UFW 实际 active/inactive 状态，避免把 ufw.service 的活动状态等同于启用过滤。UFW 后端同时通过 systemd 和 ufw status 检测。只读查询不会因为停用 UFW、其他 Fail2ban nft 表或缺少 iptables 持久化组件而单独拒绝。UFW show raw 可能初始化两张没有链或规则的空 ip/ip6 filter 表，不会因此启用 UFW。

## Fail2ban 安装与配置

菜单 7/17 在缺少客户端时，先预览，输入 Y 后通过系统软件源安装：Debian/Ubuntu 使用 `apt-get update` 和 `apt-get -y install fail2ban python3-systemd`；RHEL 家族使用 `dnf -y install fail2ban-server python3-systemd`。RHEL 系列需预先配置提供软件包的仓库（通常为 EPEL），工具不自动添加仓库。

安装期间临时 mask Fail2ban，防止软件包安装提前启动封禁；尊重管理员已有 mask。完成后校验现有配置，备份、写入本工具 jail、设置开机启动、启动或重新加载服务，并最多等待 10 秒验证 jail 就绪。失败时保留已安装的软件包；仅清理安装阶段的临时 mask，不执行配置回退。

只写 `/etc/fail2ban/jail.d/server-guard.local` 中的 `[server-guard-sshd]`，使用 sshd filter/systemd backend，覆盖识别出的全部 SSH 端口，ignoreip 包含当前管理来源和环回地址，不改写其他 jail。已有其他 jail 无效时需先修复。

菜单 17 回车使用 5 次失败、600 秒统计窗口、3600 秒封禁；--maxretry 范围 1–100，--findtime 为 1–604800 秒，--bantime 为 1–31536000 秒。命令未指定的值保留本工具已有设置，首次启用继承系统默认值。停用再启用不会丢失这些参数。

启用 Fail2ban 不要求先启用 UFW/firewalld。jail 启动与实际封禁效果需要分别验证，后者取决于系统可用的 banaction 和过滤规则。包信息见 [Ubuntu](https://packages.ubuntu.com/noble/fail2ban)、[EPEL](https://packages.fedoraproject.org/pkgs/fail2ban/fail2ban-server/epel-9.html)。

## 防火墙与 SSH 范围

| 后端 | 持久化与支持边界 |
| --- | --- |
| nftables | 唯一 inet filter 表，普通优先级 input base chain；拒绝额外 hook、复杂 jump/map/set/include 或输出过滤 |
| iptables | 双栈 filter 表；Debian 需要 netfilter-persistent，RHEL 需要 iptables/ip6tables services；拒绝 raw/mangle/nat/security 表及竞争管理器 |
| UFW | 标准 before.rules/before6.rules、IPV6=yes；保护链放在 before-input/output 前方；拒绝不明确的早期拒绝或后续覆盖链 |
| firewalld | 原生 nftables 后端及唯一 inet firewalld 表；逐区域处理；拒绝复杂 direct、policy、rich、转发/伪装及无法可靠查询的配置 |

实际变更继续执行上述检查，--backend 不能绕过管理器冲突。不会接管 Docker/Kubernetes、额外命名空间、tc/XDP 或其他进程并发写入的规则。只读查看的限制比写操作少。

SSH 保护端口取当前 SSH_CONNECTION、sshd -T、ss -ltnp 实际 sshd 监听端口和请求新端口的并集；不能识别时拒绝，环境丢失不会猜测 22。禁止修改或删除 SSH 保护端口。socket 激活 SSH 暂不支持端口切换。旧 SSH 端口保留，工具不默认关闭密码或 root 登录。

菜单 1 是首次安装/启用准备入口，不创建编号备份；根据发行版安装 UFW/firewalld，先准备全部识别出的 SSH 放行，再启用并验证。已有其他管理器或不支持的过滤规则时拒绝安装。其他业务端口需单独放行，云安全组由管理员维护。

SELinux 保留 Enforcing/Permissive 状态，校验完整/本地策略、活动上下文、端口范围及 MLS/MCS，拒绝其他服务类型或不明确的覆盖。Disabled 不需要 semanage；其他模式需要 getenforce、semanage、seinfo、restorecon、matchpathcon、chcon。只新增确有必要的 SSH 单端口授权，不导入整库或修改其他服务类型。保存策略快照及新增意图，立即读回核对并保留 SSH 文件上下文；失败时不自动删除新增授权。备份使用 GNU tar --selinux 保留标签。

## 备份与结果

状态目录 `/var/lib/server-guard` 为 root 0700，备份及元数据为 0600，拒绝符号链接状态树。为了兼容旧版，备份仍存储在 `transactions/编号/`，其目录名不是待确认流程。latest 记录最近准备执行的备份编号，result 为 running/applied/failed，audit.log 记录执行结果。日志不记录密码。

backups 验证备份校验和并显示动作、后端和结果，不显示保存的 SSH 会话地址。编号前 14 位是 UTC 创建时间。备份保存操作前状态；损坏或不完整的备份显示 integrity=invalid。保留旧 schema-2/3 的只读校验，新备份使用 schema-4。没有脚本内恢复入口。

## 分发与验证

bootstrap 固定同一提交的文件并校验 SHA256。fetch.sh 只下载、校验、解包固定 release 或离线包，不执行下载内容，拒绝链接、设备文件、重复或非预期成员；在线模式需要明确 --repo、固定 --version 和可信 --sha256，不能使用 main/latest/HEAD。

Linux 隔离夹具需要 root 和独立 TMPDIR，真实 Unix 权限必须有效。网络及服务命令经过严格适配器，断言写入前已备份，不会操作宿主真实防火墙或 SSH。测试命令：

```bash
TMPDIR=/path/to/isolated-tmp bash tests/guard_test.sh
TMPDIR=/path/to/isolated-tmp GUARD_TEST_FOCUS=operations bash tests/guard_test.sh
TMPDIR=/path/to/isolated-tmp GUARD_TEST_FOCUS=fail2ban bash tests/guard_test.sh
```

已有 Ubuntu 24.04 公网登录及只读菜单验证记录；本次立即生效流程使用函数级命令适配器验证，完整 Linux 回归需在可用测试机复跑。真实规则变更、SSH 切换、系统重启及 Enforcing 内核不属于已有实机验证结论。

## 外部参考

参考 [avsba001/vps-secure](https://raw.githubusercontent.com/avsba001/vps-secure/refs/heads/main/vps-secure.sh) 的执行前提示、分步操作和配置备份思路，独立实现立即生效流程。未引入远程自动执行、内核替换、CAKE、MSS、地域/ASN 限制或聚合网段封禁。
