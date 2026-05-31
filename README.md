# ssh-safekit

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

Linux 服务器 SSH 安全一键加固脚本。交互式菜单操作，广泛兼容主流 Linux 发行版。

## 功能

- **SSH 配置管理** — Root 登录策略、密码认证开关、端口修改（自定义/随机高位端口）、认证限制、空闲超时、root 密码管理
- **SSH 密钥管理** — 服务器端生成密钥对（ed25519/RSA 4096）、导入已有公钥
- **Fail2ban** — 一键安装、配置 SSH 防暴力破解规则、解封 IP
- **防火墙** — 自适应 ufw（Debian 系）/ firewalld（RHEL 系）/ iptables（Alpine/Arch 等），IPv4+IPv6 双栈
- **一键推荐加固** — 7 步引导式加固流程，每步可跳过
- **安全状态总览** — 一键查看 SSH、防火墙、Fail2ban、监听端口等状态
- **配置还原** — 从自动备份中恢复 SSH 配置
- **CLI 参数** — 支持 `--status`、`--quick` 等非交互模式
- **广泛兼容** — 基于能力检测，自动适配不同发行版的包管理器、防火墙和 init 系统

## 新特性 (v1.2.0)

- ✨ **基于能力检测的系统识别** — 不再依赖硬编码的发行版列表，自动识别包管理器和工具
- ✨ **Alpine Linux 完整支持** — 支持 apk 包管理器、OpenRC init 系统和 iptables 防火墙
- ✨ **Arch Linux 支持** — 支持 pacman 包管理器
- ✨ **openSUSE 支持** — 支持 zypper 包管理器
- ✨ **多 init 系统支持** — 兼容 systemd、OpenRC 和 SysVinit
- ✨ **iptables 防火墙支持** — 适用于轻量级系统和容器环境
- ✨ **智能用户选择** — 在纯 root 环境下自动查找普通用户或使用 root
- 🔧 **统一服务管理** — 抽象层自动适配不同 init 系统的服务管理命令

## 菜单结构

```
ssh-safekit 主菜单
├── 1) SSH 配置管理
│   ├── 1) Root 登录设置 (yes / prohibit-password / no)
│   ├── 2) 密码认证开关 (启用 / 禁用，带公钥检查)
│   ├── 3) 修改 SSH 端口 (自定义 / 随机高位 / 恢复22)
│   ├── 4) 认证限制 (MaxAuthTries / LoginGraceTime)
│   ├── 5) 空闲超时 (ClientAliveInterval / ClientAliveCountMax)
│   ├── 6) 修改 root 密码 (passwd)
│   ├── 7) 锁定 root 密码 (passwd -l)
│   └── 0) 返回主菜单
├── 2) SSH 密钥管理
│   ├── 1) 生成新密钥对 (ed25519 / RSA 4096)
│   ├── 2) 导入已有公钥 (粘贴)
│   ├── 3) 查看当前 authorized_keys
│   └── 0) 返回主菜单
├── 3) Fail2ban 管理
│   ├── 1) 安装 Fail2ban
│   ├── 2) 配置 SSH 防护规则 (bantime / findtime / maxretry)
│   ├── 3) 查看状态
│   ├── 4) 解封 IP
│   └── 0) 返回主菜单
├── 4) 防火墙管理 (自适应 ufw / firewalld)
│   ├── 1) 放行端口 (TCP / UDP / TCP+UDP)
│   ├── 2) 关闭端口
│   ├── 3) 设置默认策略 (拒绝入站 / 允许所有)
│   ├── 4) 启用防火墙
│   ├── 5) 禁用防火墙
│   ├── 6) 查看状态
│   └── 0) 返回主菜单
├── 5) 一键推荐加固
│   ├── 步骤 1. 检测系统环境
│   ├── 步骤 2. SSH 端口设置 (保持 / 自定义 / 随机)
│   ├── 步骤 3. SSH 密钥配置 (生成 / 粘贴公钥)
│   ├── 步骤 4. 防火墙配置
│   ├── 步骤 5. 安装 Fail2ban
│   ├── 步骤 6. 禁用密码登录
│   └── 步骤 7. 限制 root 登录 + 锁定 root 密码
├── 6) 查看当前安全状态
│   ├── 系统信息
│   ├── SSH 配置 (含空闲超时)
│   ├── Root 密码状态
│   ├── 防火墙规则
│   ├── Fail2ban 状态
│   ├── 当前 SSH 会话
│   └── 监听端口
├── 7) 从备份还原 SSH 配置
└── 0) 退出
```

## 安全保护

- 禁用密码登录前强制检查 `authorized_keys` 是否有有效公钥，防止锁死
- 修改 SSH 端口前自动在防火墙放行新端口
- RHEL 系自动处理 SELinux 端口策略（`semanage port`），避免改端口后 sshd 启动失败
- 启用防火墙前强制放行当前 SSH 端口
- 所有 SSH 配置变更前 `sshd -t` 校验，失败自动回滚
- 仅使用 `systemctl reload`，不中断现有会话
- 每次修改前自动备份到带时间戳的文件，自动保留最近 20 份
- 自动适配 OpenSSH 版本，新版使用 `KbdInteractiveAuthentication`，旧版使用 `ChallengeResponseAuthentication`
- 日志文件超过 10MB 时自动轮转

## 快速开始

### GitHub下载并运行（推荐）

使用 `curl`：

```bash
curl -fsSL https://raw.githubusercontent.com/DsureD/ssh-safekit/main/ssh-safekit.sh -o ssh-safekit.sh && chmod +x ssh-safekit.sh && sudo ./ssh-safekit.sh
```

使用 `wget`：

```bash
wget -qO ssh-safekit.sh https://raw.githubusercontent.com/DsureD/ssh-safekit/main/ssh-safekit.sh && chmod +x ssh-safekit.sh && sudo ./ssh-safekit.sh
```

### 一键脚本（直接运行）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DsureD/ssh-safekit/main/ssh-safekit.sh)
```

> 注意：管道执行需要 root 权限，建议先下载审查后再运行。

### 手动安装

```bash
git clone https://github.com/DsureD/ssh-safekit.git
cd ssh-safekit
chmod +x ssh-safekit.sh
sudo ./ssh-safekit.sh
```

## 自定义日志路径

默认日志写入 `/var/log/ssh-safekit.log`，可通过环境变量覆盖：

```bash
sudo SSH_SAFEKIT_LOG=/var/log/my-ssh-audit.log ./ssh-safekit.sh
```

## CLI 参数

除交互式菜单外，还支持以下命令行参数：

```bash
sudo ./ssh-safekit.sh --help      # 显示帮助
sudo ./ssh-safekit.sh --version   # 显示版本号
sudo ./ssh-safekit.sh --status    # 非交互式查看安全状态
sudo ./ssh-safekit.sh --quick     # 直接进入一键加固流程
```

## 系统要求

**支持的发行版：**

脚本采用**基于能力检测**的设计，自动识别包管理器、防火墙工具和 init 系统，理论上支持所有主流 Linux 发行版：

| 发行版系列 | 包管理器 | 防火墙 | Init 系统 | 测试状态 |
|-----------|---------|--------|----------|---------|
| **Debian/Ubuntu** | apt | ufw | systemd | ✅ 完全支持 |
| Debian 10+ | apt | ufw | systemd | ✅ 完全支持 |
| Ubuntu 18.04+ | apt | ufw | systemd | ✅ 完全支持 |
| Linux Mint | apt | ufw | systemd | ✅ 完全支持 |
| **RHEL/CentOS** | dnf/yum | firewalld | systemd | ✅ 完全支持 |
| CentOS 7+ | yum | firewalld | systemd | ✅ 完全支持 |
| Rocky Linux 8+ | dnf | firewalld | systemd | ✅ 完全支持 |
| AlmaLinux 8+ | dnf | firewalld | systemd | ✅ 完全支持 |
| Fedora 33+ | dnf | firewalld | systemd | ✅ 完全支持 |
| **云厂商定制版** | dnf/yum | firewalld | systemd | ✅ 完全支持 |
| Alibaba Cloud Linux 2+ | yum | firewalld | systemd | ✅ 完全支持 |
| Amazon Linux 2+ | yum | firewalld | systemd | ✅ 完全支持 |
| TencentOS Server 2+ | yum | firewalld | systemd | ✅ 完全支持 |
| openEuler 20.03+ | dnf | firewalld | systemd | ✅ 完全支持 |
| 龙蜥 OpenAnolis 8+ | dnf | firewalld | systemd | ✅ 完全支持 |
| **国产操作系统** | dnf/yum | firewalld | systemd | ✅ 完全支持 |
| 银河麒麟 Kylin V10 | yum | firewalld | systemd | ✅ 完全支持 |
| 统信 UOS 20+ | apt | ufw | systemd | ✅ 完全支持 |
| **Alpine Linux** | apk | iptables | openrc | ✅ 完全支持 |
| Alpine 3.x | apk | iptables | openrc | ✅ 完全支持 |
| **Arch Linux** | pacman | iptables | systemd | ✅ 理论支持 |
| Arch Linux | pacman | iptables | systemd | ⚠️ 未充分测试 |
| Manjaro | pacman | iptables | systemd | ⚠️ 未充分测试 |
| **openSUSE** | zypper | firewalld | systemd | ✅ 理论支持 |
| openSUSE Leap | zypper | firewalld | systemd | ⚠️ 未充分测试 |
| openSUSE Tumbleweed | zypper | firewalld | systemd | ⚠️ 未充分测试 |

**最低要求：**
- root 权限或 sudo
- bash 4.0+
- OpenSSH Server

**可选组件：**
- systemd / openrc / sysvinit（服务管理）
- ufw / firewalld / iptables（防火墙）
- fail2ban（防暴力破解）

## 使用建议

1. 首次运行建议先选菜单 `6) 查看当前安全状态`，了解服务器现状
2. 使用 `5) 一键推荐加固` 可快速完成全套加固
3. **操作全程不要关闭当前 SSH 会话**，新开一个终端验证连接成功后再退出
4. 如果改了端口，记得用新端口连接：`ssh -p <新端口> user@server`
5. **云服务器用户注意**：修改 SSH 端口后，除了本机防火墙，还需要在云厂商控制台的**安全组**中放行新端口（TCP），否则仍然无法连接

## 许可证

MIT
