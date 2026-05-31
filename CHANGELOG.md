# 更新日志

## [1.2.0] - 2026-05-31

### 新增
- ✨ **基于能力检测的系统识别** - 不再依赖硬编码的发行版名称列表，通过检测实际可用的包管理器、防火墙工具和 init 系统来判断支持
- ✨ **Alpine Linux 完整支持** - 支持 apk 包管理器、OpenRC init 系统和 iptables 防火墙
- ✨ **Arch Linux 支持** - 支持 pacman 包管理器和 systemd
- ✨ **openSUSE 支持** - 支持 zypper 包管理器和 firewalld
- ✨ **多 init 系统支持** - 新增服务管理抽象层，兼容 systemd、OpenRC 和 SysVinit
- ✨ **iptables 防火墙支持** - 适用于轻量级系统和容器环境，自动处理规则持久化
- ✨ **智能用户选择** - 在纯 root 环境下自动查找第一个普通用户（UID >= 1000），如果没有则使用 root

### 改进
- 🔧 **统一服务管理接口** - 新增 `service_enable`、`service_start`、`service_reload`、`service_restart`、`service_is_active` 函数，自动适配不同 init 系统
- 🔧 **扩展包管理器支持** - `install_pkg()` 函数现在支持 apt、dnf、yum、apk、pacman、zypper
- 🔧 **防火墙工具自动检测** - 新增 `FW_TOOL` 变量，自动检测 ufw、firewalld 或 iptables
- 🔧 **Fail2ban backend 自适应** - 根据 init 系统自动选择 systemd 或 auto backend
- 🔧 **更详细的系统信息输出** - 启动时显示检测到的包管理器、SSH 服务名、防火墙工具和 init 系统

### 技术细节
- 新增全局变量：`FW_TOOL`（防火墙工具）、`INIT_SYSTEM`（init 系统类型）
- 版本号从 1.1.0 升级到 1.2.0
- 所有 `systemctl` 调用已替换为服务管理抽象函数
- 所有基于 `OS_FAMILY` 的防火墙判断已替换为基于 `FW_TOOL` 的判断
- Alpine Linux 的 iptables 规则自动保存到 `/etc/iptables/rules.v4` 并配置开机自启

### 兼容性
- ✅ 向后兼容所有之前支持的发行版（Debian、Ubuntu、CentOS、Rocky、Alma、Fedora 等）
- ✅ 新增支持 Alpine Linux 3.x
- ✅ 新增支持 Arch Linux 和 Manjaro（理论支持，未充分测试）
- ✅ 新增支持 openSUSE Leap 和 Tumbleweed（理论支持，未充分测试）

## [1.1.0] - 2024-XX-XX

### 功能
- SSH 配置管理（Root 登录、密码认证、端口修改等）
- SSH 密钥管理（生成、导入、查看）
- Fail2ban 管理
- 防火墙管理（ufw/firewalld）
- 一键推荐加固
- 安全状态查看
- 配置备份与还原

### 支持的系统
- Debian/Ubuntu 系列
- RHEL/CentOS/Rocky/Alma/Fedora 系列
- 国产操作系统（麒麟、统信 UOS 等）
- 云厂商定制版（阿里云、腾讯云、AWS 等）
