# VPS Guard

VPS Guard 是独立的中文服务器加固工具，提供防火墙端口管理、SSH 端口切换及 Fail2ban 管理菜单。支持 Debian、Ubuntu、Rocky、AlmaLinux 和 RHEL 家族，具体版本及限制见[操作手册](MANUAL.md)。

## 一键安装并启动

在服务器的 SSH 交互终端执行（需要 curl、Bash、GNU 工具及 root 或 sudo）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wx11xz111/vps-guard/main/bootstrap.sh)
```

安装器校验固定版本的文件，再安装至 `/usr/local/lib/vpsmanager/server-guard`，并打开中文菜单。后续使用：

```bash
vps-guard
```

可在任意目录调用；普通用户会提示 sudo 验证，并保留当前 SSH 会话信息。菜单按“防火墙与端口 → SSH 与防爆破 → 状态与维护”分组。已安装旧版时，重新执行一键安装命令即可更新。

是否执行的提示统一为 `[y/N]`：`Y/y` 执行，`N/n` 或回车取消，默认不执行变更。

菜单 `16 查看完整规则` 显示当前管理器的实际规则，包含工具之外配置的规则；`17 配置防爆破` 设置 SSH 认证失败次数、统计窗口和封禁时长；`18 查看备份` 列出事务编号、动作、状态及备份校验结果，方便在恢复菜单中选择。

安装过程不修改防火墙或 SSH 配置。菜单中的变更需要预览及确认；启用 Fail2ban 不要求先启动防火墙。详细操作、依赖和回退说明见[操作手册](MANUAL.md)。

如服务器尚未安装或启用防火墙，选择 **1 安装并启用防火墙**：Debian/Ubuntu 使用 UFW，RHEL/Rocky/Alma 使用 firewalld。脚本先识别和放行当前会话、配置及监听中的全部 SSH 端口，再启用并核对防火墙；已有其他管理器或不支持的规则会提前拒绝。业务端口需随后按需放行。

## 验证状态

脚本已经过隔离环境测试，并在 Ubuntu 24.04 公网服务器验证了 SSH 登录、只读查询及菜单。真实防火墙/SSH 变更、系统重启和 SELinux 内核仍需实机验收。使用前请保留云厂商救援入口，并确保云安全组允许当前 SSH 端口。

## 来源与许可

本工具来自 VPS Manager 的独立服务器加固模块，基于 Bash 开发，采用 [GPL-3.0](LICENSE)。
