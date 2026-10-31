# VPS Guard

VPS Guard 是独立的中文服务器加固工具，提供 SSH 端口、防火墙端口及 Fail2ban 管理菜单。工具基于 Bash，支持 Debian、Ubuntu、Rocky、AlmaLinux 和 RHEL 的说明中列出的版本。

功能和限制详见 [操作手册](MANUAL.md)。脚本源于 VPS Manager 项目，采用 [GPL-3.0](LICENSE)。

本项目已经过隔离环境测试，真实公网服务器、系统重启及 SELinux 内核仍需实机验收。使用前请保留云厂商救援入口，并确保云安全组允许当前 SSH 端口。
