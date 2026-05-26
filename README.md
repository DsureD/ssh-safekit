# ssh-safekit

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

Linux 服务器 SSH 安全一键加固脚本。交互式菜单操作，广泛兼容主流 Linux 发行版。

## 功能

- **SSH 配置管理** — Root 登录策略、密码认证开关、端口修改（自定义/随机高位端口）、认证限制、空闲超时、root 密码管理
- **SSH 密钥管理** — 服务器端生成密钥对（ed25519/RSA 4096）、导入已有公钥
- **Fail2ban** — 一键安装、配置 SSH 防暴力破解规则、解封 IP
- **防火墙** — 自适应 ufw（Debian 系）/ firewalld（RHEL 系），IPv4+IPv6 双栈
- **一键推荐加固** — 7 步引导式加固流程，每步可跳过
- **安全状态总览** — 一键查看 SSH、防火墙、Fail2ban、监听端口等状态
- **配置还原** — 从自动备份中恢复 SSH 配置
- **CLI 参数** — 支持 `--status`、`--quick` 等非交互模式

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

| 发行版 | 版本 | 防火墙 |
|--------|------|--------|
| Ubuntu | 18.04+ | ufw |
| Debian | 10+ | ufw |
| CentOS | 7+ | firewalld |
| Rocky Linux | 8+ | firewalld |
| AlmaLinux | 8+ | firewalld |
| Fedora | 33+ | firewalld |
| Alibaba Cloud Linux | 2+ | firewalld |
| Amazon Linux | 2+ | firewalld |
| TencentOS Server | 2+ | firewalld |
| openEuler | 20.03+ | firewalld |
| 龙蜥 OpenAnolis | 8+ | firewalld |
| 银河麒麟 Kylin | V10 | firewalld |
| 统信 UOS | 20+ | firewalld |

- 需要 root 权限或 sudo
- 需要 systemd
- 需要 bash 4.0+

## 使用建议

1. 首次运行建议先选菜单 `6) 查看当前安全状态`，了解服务器现状
2. 使用 `5) 一键推荐加固` 可快速完成全套加固
3. **操作全程不要关闭当前 SSH 会话**，新开一个终端验证连接成功后再退出
4. 如果改了端口，记得用新端口连接：`ssh -p <新端口> user@server`

## 许可证

MIT
