#!/usr/bin/env bash
# shellcheck shell=bash
# ssh-safekit - Linux SSH 安全加固工具
# https://github.com/DsureD/ssh-safekit
# License: MIT
set -euo pipefail

# ===== 全局变量 =====
SAFEKIT_VERSION="1.1.0"
LOG_FILE="${SSH_SAFEKIT_LOG:-/var/log/ssh-safekit.log}"
BACKUP_DIR="/etc/ssh/backups"
BACKUP_KEEP=20
MAX_LOG_SIZE=$((10 * 1024 * 1024))
SSH_CONFIG="/etc/ssh/sshd_config"
DROPIN_DIR="/etc/ssh/sshd_config.d"
DROPIN_FILE="99-ssh-safekit.conf"
OS_FAMILY=""
PKG_MGR=""
SSH_SERVICE=""
CURRENT_SSH_PORT=""
SKIP_PAUSE=0
RUN_MODE="menu"

# ===== 颜色 =====
if tput colors &>/dev/null && [[ $(tput colors) -ge 8 ]]; then
    RED=$(tput setaf 1); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4); BOLD=$(tput bold); RESET=$(tput sgr0)
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; RESET=""
fi

# ===== 清理与信号处理 =====
cleanup() {
    stty echo 2>/dev/null || true
}
trap cleanup EXIT

# ===== 工具函数 =====
log_info()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*" >> "$LOG_FILE" 2>/dev/null; echo "${GREEN}[INFO]${RESET} $*"; }
log_warn()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $*" >> "$LOG_FILE" 2>/dev/null; echo "${YELLOW}[WARN]${RESET} $*"; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >> "$LOG_FILE" 2>/dev/null; echo "${RED}[ERROR]${RESET} $*" >&2; }
confirm() {
    local prompt="${1:-确认执行?}"
    local answer
    read -rp "${BOLD}${prompt} [y/N]: ${RESET}" answer
    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

press_enter() {
    if [[ $SKIP_PAUSE -ne 0 ]]; then
        SKIP_PAUSE=0
        return
    fi
    echo ""
    read -rp "按 Enter 返回菜单..." _
}

skip_pause() { SKIP_PAUSE=1; }

validate_uint() {
    local val="$1" min="${2:-1}" max="${3:-2147483647}"
    [[ "$val" =~ ^[0-9]+$ ]] && [[ "$val" -ge "$min" ]] && [[ "$val" -le "$max" ]]
}

read_uint() {
    local prompt="$1" default="$2" min="${3:-1}" max="${4:-2147483647}"
    local val
    while true; do
        read -rp "$prompt" val
        if [[ -z "$val" && -z "$default" ]]; then
            return 1
        fi
        val="${val:-$default}"
        if validate_uint "$val" "$min" "$max"; then
            echo "$val"
            return 0
        else
            if [[ -n "$default" ]]; then
                echo "  ${YELLOW}请输入 ${min}-${max} 之间的整数（留空使用默认值 ${default}）${RESET}" >&2
            else
                echo "  ${YELLOW}请输入 ${min}-${max} 之间的整数（留空取消）${RESET}" >&2
            fi
        fi
    done
}

validate_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS=.
        local -a parts=($ip)
        local p
        for p in "${parts[@]}"; do
            [[ "$p" -le 255 ]] || return 1
        done
        return 0
    fi
    if [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] && [[ "$ip" == *:* ]]; then
        return 0
    fi
    return 1
}

get_user_home() {
    local user="$1"
    getent passwd "$user" | cut -d: -f6
}

get_sshd_version() {
    local ver
    ver=$(sshd -V 2>&1 | grep -oP 'OpenSSH_\K[0-9]+\.[0-9]+' || echo "0.0")
    echo "$ver"
}

disable_kbd_interactive() {
    local ver
    ver=$(get_sshd_version)
    local major minor
    major=$(echo "$ver" | cut -d. -f1)
    minor=$(echo "$ver" | cut -d. -f2)
    if [[ "$major" -gt 8 ]] || { [[ "$major" -eq 8 ]] && [[ "$minor" -ge 7 ]]; }; then
        apply_sshd_setting "KbdInteractiveAuthentication" "no"
    else
        apply_sshd_setting "ChallengeResponseAuthentication" "no"
    fi
}
selinux_add_port() {
    local port="$1"
    if ! command -v getenforce &>/dev/null; then return 0; fi
    if ! getenforce 2>/dev/null | grep -qi enforcing; then return 0; fi
    if ! command -v semanage &>/dev/null; then
        log_warn "SELinux 为 enforcing 但 semanage 未安装，尝试安装 policycoreutils-python-utils..."
        install_pkg "policycoreutils-python-utils" || {
            log_warn "无法安装 semanage，请手动执行: semanage port -a -t ssh_port_t -p tcp ${port}"
            return 0
        }
    fi
    if semanage port -l 2>/dev/null | grep -q "ssh_port_t.*tcp.*\b${port}\b"; then
        return 0
    fi
    semanage port -a -t ssh_port_t -p tcp "$port" 2>/dev/null || \
        semanage port -m -t ssh_port_t -p tcp "$port" 2>/dev/null || {
            log_warn "SELinux 端口策略设置失败，请手动执行: semanage port -a -t ssh_port_t -p tcp ${port}"
        }
}

rotate_log() {
    if [[ ! -f "$LOG_FILE" ]]; then return; fi
    local size
    size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if [[ "$size" -gt "$MAX_LOG_SIZE" ]]; then
        mv "$LOG_FILE" "${LOG_FILE}.1"
        touch "$LOG_FILE"
        chmod 600 "$LOG_FILE"
    fi
}

prune_backups() {
    if [[ ! -d "$BACKUP_DIR" ]]; then return; fi
    local -a backups=()
    while IFS= read -r f; do
        backups+=("$f")
    done < <(ls -1t "${BACKUP_DIR}"/sshd_config.bak.* 2>/dev/null | grep -v '\.dropin$')
    if [[ ${#backups[@]} -le $BACKUP_KEEP ]]; then return; fi
    local i
    for ((i=BACKUP_KEEP; i<${#backups[@]}; i++)); do
        rm -f "${backups[$i]}" "${backups[$i]}.dropin"
    done
    log_info "已清理旧备份，保留最近 ${BACKUP_KEEP} 份"
}
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要 root 权限运行，请使用 sudo 或 root 用户执行"
        exit 1
    fi
}

detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "无法检测操作系统（缺少 /etc/os-release）"
        exit 1
    fi
    # shellcheck source=/dev/null
    source /etc/os-release
    case "${ID,,}" in
        ubuntu|debian|linuxmint|pop)
            OS_FAMILY="debian"
            PKG_MGR="apt"
            SSH_SERVICE="ssh"
            ;;
        centos|rhel|rocky|almalinux|fedora|ol|alinux|amzn|openeuler|anolis|tencentos|bclinux|kylin|uos)
            OS_FAMILY="rhel"
            if command -v dnf &>/dev/null; then
                PKG_MGR="dnf"
            else
                PKG_MGR="yum"
            fi
            SSH_SERVICE="sshd"
            ;;
        *)
            log_error "不支持的发行版: ${ID}。目前支持 Debian/Ubuntu 和 RHEL/CentOS/Rocky/Alma/Fedora/AliLinux/Amazon Linux/openEuler"
            exit 1
            ;;
    esac
    log_info "检测到系统: ${PRETTY_NAME:-$ID} (${OS_FAMILY}系, 包管理器: ${PKG_MGR})"
}

detect_ssh_port() {
    CURRENT_SSH_PORT=$(sshd -T 2>/dev/null | grep -i "^port " | awk '{print $2}')
    if [[ -z "$CURRENT_SSH_PORT" ]]; then
        CURRENT_SSH_PORT=$(grep -E "^\s*Port\s+" "$SSH_CONFIG" 2>/dev/null | awk '{print $2}' | tail -1)
    fi
    CURRENT_SSH_PORT="${CURRENT_SSH_PORT:-22}"
}
install_pkg() {
    local pkg="$1"
    log_info "正在安装 ${pkg}..."
    local ret=0
    case "$PKG_MGR" in
        apt)  apt-get update -qq && apt-get install -y -qq "$pkg" || ret=$? ;;
        dnf)  dnf install -y -q "$pkg" || ret=$? ;;
        yum)  yum install -y -q "$pkg" || ret=$? ;;
    esac
    if [[ $ret -eq 0 ]]; then
        log_info "${pkg} 安装成功"
    else
        log_error "${pkg} 安装失败"
        return 1
    fi
}

backup_sshd() {
    mkdir -p "$BACKUP_DIR"
    local backup_file="${BACKUP_DIR}/sshd_config.bak.$(date '+%Y%m%d_%H%M%S')"
    cp "$SSH_CONFIG" "$backup_file"
    if [[ -d "$DROPIN_DIR" && -f "${DROPIN_DIR}/${DROPIN_FILE}" ]]; then
        cp "${DROPIN_DIR}/${DROPIN_FILE}" "${backup_file}.dropin"
    fi
    log_info "已备份 sshd_config 到 ${backup_file}"
    prune_backups
    echo "$backup_file"
}

validate_sshd() {
    if sshd -t 2>/dev/null; then
        return 0
    else
        log_error "sshd 配置校验失败"
        return 1
    fi
}

reload_sshd() {
    if validate_sshd; then
        systemctl reload "$SSH_SERVICE"
        log_info "SSH 服务已重载"
        return 0
    else
        log_error "配置校验失败，未重载服务"
        return 1
    fi
}
rollback_sshd() {
    local backup_file="$1"
    if [[ -f "$backup_file" ]]; then
        cp "$backup_file" "$SSH_CONFIG"
        if [[ -f "${backup_file}.dropin" ]]; then
            mkdir -p "$DROPIN_DIR"
            cp "${backup_file}.dropin" "${DROPIN_DIR}/${DROPIN_FILE}"
        else
            rm -f "${DROPIN_DIR}/${DROPIN_FILE}"
        fi
        reload_sshd
        log_warn "已从备份还原: ${backup_file}"
    else
        log_error "备份文件不存在: ${backup_file}"
    fi
}

apply_sshd_setting() {
    local key="$1" value="$2"
    local backup
    backup=$(backup_sshd)

    if [[ -d "$DROPIN_DIR" ]]; then
        local dropin="${DROPIN_DIR}/${DROPIN_FILE}"
        if [[ -f "$dropin" ]] && grep -qE "^\s*${key}\s+" "$dropin"; then
            sed -i "s|^\s*${key}\s.*|${key} ${value}|" "$dropin"
        else
            echo "${key} ${value}" >> "$dropin"
        fi
    else
        if grep -qE "^\s*#?\s*${key}\s+" "$SSH_CONFIG"; then
            sed -i "s|^\s*#\?\s*${key}\s.*|${key} ${value}|" "$SSH_CONFIG"
        else
            echo "${key} ${value}" >> "$SSH_CONFIG"
        fi
    fi

    if validate_sshd; then
        reload_sshd
        log_info "已设置 ${key} = ${value}"
    else
        rollback_sshd "$backup"
        log_error "设置 ${key} 失败，已回滚"
        return 1
    fi
}

random_high_port() {
    local port
    while true; do
        if command -v shuf &>/dev/null; then
            port=$(shuf -i 10000-65535 -n 1)
        else
            port=$(( (RANDOM * 32768 + RANDOM) % 55536 + 10000 ))
        fi
        if ! ss -tlnp | grep -q ":${port} "; then
            echo "$port"
            return
        fi
    done
}
get_target_user() {
    local default_user="${SUDO_USER:-root}"
    local user
    read -rp "目标用户 [${default_user}]: " user
    user="${user:-$default_user}"
    if ! id "$user" &>/dev/null; then
        log_error "用户 ${user} 不存在"
        return 1
    fi
    echo "$user"
}

check_authorized_keys() {
    local user="$1"
    local home
    home=$(get_user_home "$user")
    local auth_file="${home}/.ssh/authorized_keys"
    if [[ -f "$auth_file" ]] && [[ -s "$auth_file" ]]; then
        local valid_lines
        valid_lines=$(grep -cE "^(ssh-|ecdsa-)" "$auth_file" 2>/dev/null || true)
        if [[ "$valid_lines" -gt 0 ]]; then
            return 0
        fi
    fi
    return 1
}

# ===== 模块 1: SSH 配置管理 =====
toggle_root_login() {
    echo ""
    local current
    current=$(sshd -T 2>/dev/null | grep -i permitrootlogin | awk '{print $2}')
    echo "当前 PermitRootLogin: ${BOLD}${current}${RESET}"
    echo ""
    echo "  1) yes              - 允许 root 密码和密钥登录$(
        [[ "$current" == "yes" ]] && echo " ${GREEN}← 当前${RESET}")"
    echo "  2) prohibit-password - 仅允许 root 密钥登录（推荐）$(
        [[ "$current" == "prohibit-password" || "$current" == "without-password" ]] && echo " ${GREEN}← 当前${RESET}")"
    echo "  3) no               - 完全禁止 root 登录$(
        [[ "$current" == "no" ]] && echo " ${GREEN}← 当前${RESET}")"
    echo "  0) 返回"
    echo ""
    local choice
    read -rp "选择: " choice
    case "$choice" in
        1) apply_sshd_setting "PermitRootLogin" "yes" ;;
        2) apply_sshd_setting "PermitRootLogin" "prohibit-password" ;;
        3)
            log_warn "完全禁止 root 登录前，请确保有其他用户可以 sudo"
            if confirm "确认禁止 root 登录?"; then
                apply_sshd_setting "PermitRootLogin" "no"
            else
                skip_pause
            fi
            ;;
        0) skip_pause; return ;;
        *) log_warn "无效选择" ;;
    esac
}
toggle_password_auth() {
    echo ""
    local current
    current=$(sshd -T 2>/dev/null | grep -i passwordauthentication | awk '{print $2}')
    echo "当前 PasswordAuthentication: ${BOLD}${current}${RESET}"
    echo ""
    echo "  1) 启用密码登录$(
        [[ "$current" == "yes" ]] && echo " ${GREEN}← 当前${RESET}")"
    echo "  2) 禁用密码登录（仅密钥）$(
        [[ "$current" == "no" ]] && echo " ${GREEN}← 当前${RESET}")"
    echo "  0) 返回"
    echo ""
    local choice
    read -rp "选择: " choice
    case "$choice" in
        1) apply_sshd_setting "PasswordAuthentication" "yes" ;;
        2)
            local user
            user=$(get_target_user) || return
            if ! check_authorized_keys "$user"; then
                log_error "用户 ${user} 的 authorized_keys 中没有有效公钥！"
                log_error "禁用密码登录将导致无法登录，操作已取消"
                return 1
            fi
            if confirm "已确认 ${user} 有有效公钥，禁用密码登录?"; then
                apply_sshd_setting "PasswordAuthentication" "no"
                disable_kbd_interactive
            else
                skip_pause
            fi
            ;;
        0) skip_pause; return ;;
        *) log_warn "无效选择" ;;
    esac
}

change_ssh_port() {
    detect_ssh_port
    echo ""
    echo "当前 SSH 端口: ${CURRENT_SSH_PORT}"
    echo ""
    echo "  1) 输入自定义端口"
    echo "  2) 随机生成高位端口 (10000-65535)"
    echo "  3) 恢复为 22"
    echo "  0) 返回"
    echo ""
    local choice new_port
    read -rp "选择: " choice
    case "$choice" in
        1)
            new_port=$(read_uint "输入新端口 (1024-65535): " "" 1024 65535) || return
            ;;
        2)
            new_port=$(random_high_port)
            echo "生成的随机端口: ${new_port}"
            if ! confirm "使用此端口?"; then skip_pause; return; fi
            ;;
        3) new_port=22 ;;
        0) skip_pause; return ;;
        *) log_warn "无效选择"; return ;;
    esac
    if ss -tlnp | grep -q ":${new_port} " && [[ "$new_port" != "$CURRENT_SSH_PORT" ]]; then
        log_error "端口 ${new_port} 已被占用"
        return 1
    fi

    log_info "正在放行新端口 ${new_port} 到防火墙..."
    fw_allow_port_internal "$new_port" "tcp"
    selinux_add_port "$new_port"

    if apply_sshd_setting "Port" "$new_port"; then
        log_info "SSH 端口已更改为 ${new_port}"
        log_warn "请立即使用新端口测试连接: ssh -p ${new_port} user@host"
        log_warn "如果是云服务器，还需要在云厂商控制台的安全组中放行端口 ${new_port}/TCP"
        CURRENT_SSH_PORT="$new_port"
    fi
}

set_auth_limits() {
    echo ""
    local current_max current_grace
    current_max=$(sshd -T 2>/dev/null | grep -i maxauthtries | awk '{print $2}')
    current_grace=$(sshd -T 2>/dev/null | grep -i logingracetime | awk '{print $2}')
    echo "当前 MaxAuthTries: ${current_max:-6}"
    echo "当前 LoginGraceTime: ${current_grace:-120}"
    echo ""
    local max_tries grace_time
    max_tries=$(read_uint "MaxAuthTries (最大尝试次数) [3]: " "3" 1 100)
    grace_time=$(read_uint "LoginGraceTime (登录超时秒数) [60]: " "60" 1 3600)

    apply_sshd_setting "MaxAuthTries" "$max_tries"
    apply_sshd_setting "LoginGraceTime" "$grace_time"
}

set_idle_timeout() {
    echo ""
    local current_interval current_count
    current_interval=$(sshd -T 2>/dev/null | grep -i clientaliveinterval | awk '{print $2}')
    current_count=$(sshd -T 2>/dev/null | grep -i clientalivecountmax | awk '{print $2}')
    echo "当前 ClientAliveInterval: ${current_interval:-0} 秒"
    echo "当前 ClientAliveCountMax: ${current_count:-3}"
    echo ""
    echo "说明: 空闲超时 = Interval × CountMax"
    echo "  例: 300 × 3 = 900 秒 (15 分钟) 无响应后断开"
    echo ""
    local interval count
    interval=$(read_uint "ClientAliveInterval (秒, 0=禁用) [300]: " "300" 0 86400)
    count=$(read_uint "ClientAliveCountMax [3]: " "3" 1 100)

    apply_sshd_setting "ClientAliveInterval" "$interval"
    apply_sshd_setting "ClientAliveCountMax" "$count"
}
disable_root_password() {
    echo ""
    local status
    status=$(passwd -S root 2>/dev/null | awk '{print $2}')
    echo "当前 root 密码状态: ${status} (L=锁定, P=有密码, NP=无密码)"
    echo ""
    if [[ "$status" == "L" ]]; then
        log_info "root 密码已经是锁定状态"
        return
    fi
    log_warn "锁定 root 密码后，将无法通过密码切换到 root（sudo 不受影响）"
    if confirm "确认锁定 root 密码?"; then
        passwd -l root
        log_info "root 密码已锁定"
    else
        skip_pause
    fi
}

change_root_password() {
    echo ""
    local status
    status=$(passwd -S root 2>/dev/null | awk '{print $2}')
    echo "当前 root 密码状态: ${status} (L=锁定, P=有密码, NP=无密码)"
    echo ""
    if [[ "$status" == "L" ]]; then
        log_warn "root 密码当前为锁定状态，设置新密码会自动解锁"
        if ! confirm "继续修改 root 密码?"; then
            skip_pause
            return
        fi
    fi

    local pr
    pr=$(sshd -T 2>/dev/null | grep -i permitrootlogin | awk '{print $2}')
    local pa
    pa=$(sshd -T 2>/dev/null | grep -i passwordauthentication | awk '{print $2}')
    if [[ "$pr" == "no" ]]; then
        log_warn "提示: 当前 PermitRootLogin=no，root 无法通过 SSH 登录（修改密码不影响 sudo）"
    elif [[ "$pr" == "prohibit-password" || "$pr" == "without-password" ]] && [[ "$pa" == "no" ]]; then
        log_warn "提示: 当前 SSH 仅允许 root 密钥登录，新密码不能用于 SSH 登录（仅可用于本地/sudo）"
    fi
    echo ""

    if ! confirm "确认修改 root 密码?"; then
        log_info "已取消修改 root 密码"
        skip_pause
        return
    fi

    if passwd root; then
        log_info "root 密码已修改"
    else
        log_error "root 密码修改失败"
        return 1
    fi
}

menu_ssh_config() {
    while true; do
        echo ""
        echo "${BOLD}====== SSH 配置管理 ======${RESET}"
        echo "  1) Root 登录设置"
        echo "  2) 密码认证开关"
        echo "  3) 修改 SSH 端口"
        echo "  4) 认证限制 (MaxAuthTries/LoginGraceTime)"
        echo "  5) 空闲超时 (ClientAliveInterval)"
        echo "  6) 修改 root 密码 (passwd)"
        echo "  7) 锁定 root 密码 (passwd -l)"
        echo "  0) 返回主菜单"
        echo ""
        local choice
        read -rp "选择: " choice
        case "$choice" in
            1) toggle_root_login ;;
            2) toggle_password_auth ;;
            3) change_ssh_port ;;
            4) set_auth_limits ;;
            5) set_idle_timeout ;;
            6) change_root_password ;;
            7) disable_root_password ;;
            0) return ;;
            *) log_warn "无效选择"; continue ;;
        esac
        press_enter
    done
}
# ===== 模块 2: SSH 密钥管理 =====
generate_keypair() {
    local user
    user=$(get_target_user) || return
    local home
    home=$(get_user_home "$user")
    local ssh_dir="${home}/.ssh"

    echo ""
    echo "  1) ed25519（推荐，更安全更短）"
    echo "  2) RSA 4096"
    echo ""
    local algo_choice key_type key_file
    read -rp "选择算法 [1]: " algo_choice
    algo_choice="${algo_choice:-1}"
    case "$algo_choice" in
        1) key_type="ed25519"; key_file="${ssh_dir}/id_ed25519" ;;
        2) key_type="rsa"; key_file="${ssh_dir}/id_rsa" ;;
        *) key_type="ed25519"; key_file="${ssh_dir}/id_ed25519" ;;
    esac

    if [[ -f "$key_file" ]]; then
        log_warn "密钥文件已存在: ${key_file}"
        if ! confirm "覆盖现有密钥?"; then skip_pause; return; fi
    fi

    local passphrase=""
    read -rsp "输入密钥密码 (留空则无密码): " passphrase
    echo ""

    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    chown "${user}:$(id -gn "$user")" "$ssh_dir"

    if [[ "$key_type" == "ed25519" ]]; then
        ssh-keygen -t ed25519 -f "$key_file" -N "$passphrase" -C "${user}@$(hostname)-$(date +%Y%m%d)"
    else
        ssh-keygen -t rsa -b 4096 -f "$key_file" -N "$passphrase" -C "${user}@$(hostname)-$(date +%Y%m%d)"
    fi

    chmod 600 "$key_file"
    chmod 644 "${key_file}.pub"
    chown "${user}:$(id -gn "$user")" "$key_file" "${key_file}.pub"

    log_info "密钥对已生成:"
    echo "  私钥: ${key_file}"
    echo "  公钥: ${key_file}.pub"
    echo ""
    echo "${BOLD}公钥内容:${RESET}"
    cat "${key_file}.pub"
    echo ""

    if confirm "是否将公钥添加到 ${user} 的 authorized_keys?"; then
        local auth_file="${ssh_dir}/authorized_keys"
        cat "${key_file}.pub" >> "$auth_file"
        chmod 600 "$auth_file"
        chown "${user}:$(id -gn "$user")" "$auth_file"
        log_info "公钥已添加到 ${auth_file}"
    fi

    echo ""
    log_warn "请立即将私钥 ${key_file} 下载到本地，然后从服务器删除私钥"
    log_warn "命令: scp -P ${CURRENT_SSH_PORT:-22} ${user}@server:${key_file} ~/.ssh/"
}

import_pubkey() {
    local user
    user=$(get_target_user) || return
    local home
    home=$(get_user_home "$user")
    local ssh_dir="${home}/.ssh"
    local auth_file="${ssh_dir}/authorized_keys"

    echo ""
    echo "请粘贴公钥内容（以 ssh-ed25519、ssh-rsa 或 ecdsa- 开头）:"
    echo "粘贴后按 Enter 确认:"
    echo ""
    local pubkey
    read -r pubkey

    if ! echo "$pubkey" | grep -qE "^(ssh-ed25519|ssh-rsa|ecdsa-sha2-)"; then
        log_error "无效的公钥格式，应以 ssh-ed25519、ssh-rsa 或 ecdsa-sha2- 开头"
        return 1
    fi

    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    chown "${user}:$(id -gn "$user")" "$ssh_dir"

    if grep -qF "$pubkey" "$auth_file" 2>/dev/null; then
        log_warn "该公钥已存在于 authorized_keys 中"
        return
    fi

    echo "$pubkey" >> "$auth_file"
    chmod 600 "$auth_file"
    chown "${user}:$(id -gn "$user")" "$auth_file"
    log_info "公钥已添加到 ${auth_file}"
}

list_authorized_keys() {
    local user
    user=$(get_target_user) || return
    local home
    home=$(get_user_home "$user")
    local auth_file="${home}/.ssh/authorized_keys"

    echo ""
    if [[ -f "$auth_file" && -s "$auth_file" ]]; then
        echo "${BOLD}${user} 的 authorized_keys:${RESET}"
        echo "---"
        local i=1
        while IFS= read -r line; do
            if [[ -n "$line" && ! "$line" =~ ^# ]]; then
                local key_type key_comment
                key_type=$(echo "$line" | awk '{print $1}')
                key_comment=$(echo "$line" | awk '{print $NF}')
                echo "  ${i}) [${key_type}] ${key_comment}"
                ((i++))
            fi
        done < "$auth_file"
        echo "---"
        echo "共 $((i-1)) 个密钥"
    else
        log_warn "用户 ${user} 没有 authorized_keys 或文件为空"
    fi
}

menu_ssh_keys() {
    while true; do
        echo ""
        echo "${BOLD}====== SSH 密钥管理 ======${RESET}"
        echo "  1) 生成新密钥对（服务器端）"
        echo "  2) 导入已有公钥（粘贴）"
        echo "  3) 查看当前 authorized_keys"
        echo "  0) 返回主菜单"
        echo ""
        local choice
        read -rp "选择: " choice
        case "$choice" in
            1) generate_keypair ;;
            2) import_pubkey ;;
            3) list_authorized_keys ;;
            0) return ;;
            *) log_warn "无效选择"; continue ;;
        esac
        press_enter
    done
}
# ===== 模块 3: Fail2ban =====
install_fail2ban() {
    if command -v fail2ban-client &>/dev/null; then
        log_info "fail2ban 已安装"
        return 0
    fi
    if confirm "安装 fail2ban?"; then
        install_pkg "fail2ban" || return 1
        systemctl enable fail2ban
        systemctl start fail2ban
    else
        skip_pause
        return 1
    fi
}

configure_fail2ban_jail() {
    detect_ssh_port
    local jail_dir="/etc/fail2ban/jail.d"
    local jail_file="${jail_dir}/sshd-ssh-safekit.local"

    echo ""
    echo "${BOLD}配置 Fail2ban SSH 防护${RESET}"
    echo ""
    local bantime findtime maxretry
    bantime=$(read_uint "封禁时长 (秒, 默认 3600 即 1 小时): " "3600" 60 31536000)
    findtime=$(read_uint "检测时间窗口 (秒, 默认 600 即 10 分钟): " "600" 60 86400)
    maxretry=$(read_uint "最大失败次数 (默认 5): " "5" 1 100)

    mkdir -p "$jail_dir"
    cat > "$jail_file" <<EOF
[sshd]
enabled = true
port = ${CURRENT_SSH_PORT}
filter = sshd
backend = systemd
bantime = ${bantime}
findtime = ${findtime}
maxretry = ${maxretry}
banaction = %(banaction_allports)s
EOF

    log_info "Fail2ban 配置已写入 ${jail_file}"
    systemctl restart fail2ban
    log_info "Fail2ban 已重启，等待 jail 激活..."
    echo ""

    local i jail_ok=0
    for i in 1 2 3 4 5; do
        if fail2ban-client status sshd &>/dev/null; then
            jail_ok=1
            break
        fi
        sleep 1
    done

    if [[ $jail_ok -eq 1 ]]; then
        fail2ban-client status sshd
    else
        log_warn "sshd jail 尚未激活，可稍后用以下命令检查："
        echo ""
        echo "  sudo fail2ban-client status sshd"
        echo "  sudo systemctl status fail2ban"
        echo "  sudo tail -f /var/log/fail2ban.log"
    fi
}

show_fail2ban_status() {
    echo ""
    if ! command -v fail2ban-client &>/dev/null; then
        log_warn "fail2ban 未安装"
        return
    fi
    echo "${BOLD}Fail2ban 状态:${RESET}"
    fail2ban-client status 2>/dev/null
    echo ""
    fail2ban-client status sshd 2>/dev/null || log_warn "sshd jail 未运行"
}

unban_ip() {
    if ! command -v fail2ban-client &>/dev/null; then
        log_warn "fail2ban 未安装"
        return
    fi
    local ip
    read -rp "输入要解封的 IP (留空取消): " ip
    if [[ -z "$ip" ]]; then
        skip_pause
        return
    fi
    if ! validate_ip "$ip"; then
        log_error "无效的 IP 地址格式: ${ip}"
        return 1
    fi
    fail2ban-client set sshd unbanip "$ip" && log_info "已解封 ${ip}" || log_error "解封失败（可能该 IP 未被封禁）"
}

menu_fail2ban() {
    while true; do
        echo ""
        echo "${BOLD}====== Fail2ban 管理 ======${RESET}"
        echo "  1) 安装 Fail2ban"
        echo "  2) 配置 SSH 防护规则"
        echo "  3) 查看状态"
        echo "  4) 解封 IP"
        echo "  0) 返回主菜单"
        echo ""
        local choice
        read -rp "选择: " choice
        case "$choice" in
            1) install_fail2ban ;;
            2) configure_fail2ban_jail ;;
            3) show_fail2ban_status ;;
            4) unban_ip ;;
            0) return ;;
            *) log_warn "无效选择"; continue ;;
        esac
        press_enter
    done
}
# ===== 模块 4: 防火墙 =====
fw_allow_port_internal() {
    local port="$1" proto="${2:-tcp}"
    case "$OS_FAMILY" in
        debian)
            command -v ufw &>/dev/null || install_pkg ufw
            ufw allow "${port}/${proto}" >/dev/null 2>&1
            ;;
        rhel)
            firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1
            firewall-cmd --reload >/dev/null 2>&1
            ;;
    esac
}

fw_deny_port_internal() {
    local port="$1" proto="${2:-tcp}"
    case "$OS_FAMILY" in
        debian)
            ufw delete allow "${port}/${proto}" >/dev/null 2>&1
            ;;
        rhel)
            firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null 2>&1
            firewall-cmd --reload >/dev/null 2>&1
            ;;
    esac
}

fw_allow_port() {
    local port proto
    port=$(read_uint "端口号 (1-65535): " "" 1 65535) || return
    echo "  1) TCP"
    echo "  2) UDP"
    echo "  3) TCP+UDP"
    read -rp "协议 [1]: " proto
    case "${proto:-1}" in
        1) fw_allow_port_internal "$port" "tcp"; log_info "已放行 ${port}/tcp" ;;
        2) fw_allow_port_internal "$port" "udp"; log_info "已放行 ${port}/udp" ;;
        3) fw_allow_port_internal "$port" "tcp"; fw_allow_port_internal "$port" "udp"; log_info "已放行 ${port}/tcp+udp" ;;
        *) log_warn "无效选择，未做任何更改" ;;
    esac
}

fw_deny_port() {
    local port proto
    port=$(read_uint "端口号 (1-65535): " "" 1 65535) || return
    detect_ssh_port
    if [[ "$port" == "$CURRENT_SSH_PORT" ]]; then
        log_error "不能关闭当前 SSH 端口 ${CURRENT_SSH_PORT}！"
        return 1
    fi
    echo "  1) TCP"
    echo "  2) UDP"
    echo "  3) TCP+UDP"
    read -rp "协议 [1]: " proto
    case "${proto:-1}" in
        1) fw_deny_port_internal "$port" "tcp"; log_info "已关闭 ${port}/tcp" ;;
        2) fw_deny_port_internal "$port" "udp"; log_info "已关闭 ${port}/udp" ;;
        3) fw_deny_port_internal "$port" "tcp"; fw_deny_port_internal "$port" "udp"; log_info "已关闭 ${port}/tcp+udp" ;;
        *) log_warn "无效选择，未做任何更改" ;;
    esac
}
fw_set_default() {
    echo ""
    local current_policy="unknown" raw_value="未启用"
    case "$OS_FAMILY" in
        debian)
            if command -v ufw &>/dev/null; then
                local incoming
                incoming=$(ufw status verbose 2>/dev/null | grep -i "^Default:" | grep -oP 'deny|reject|allow' | head -1)
                if [[ -n "$incoming" ]]; then
                    raw_value="incoming=${incoming}"
                    [[ "$incoming" == "allow" ]] && current_policy="allow" || current_policy="deny"
                fi
            fi
            ;;
        rhel)
            if systemctl is-active firewalld &>/dev/null; then
                local zone
                zone=$(firewall-cmd --get-default-zone 2>/dev/null)
                if [[ -n "$zone" ]]; then
                    raw_value="default-zone=${zone}"
                    [[ "$zone" == "trusted" ]] && current_policy="allow" || current_policy="deny"
                fi
            fi
            ;;
    esac
    echo "当前默认策略: ${BOLD}${raw_value}${RESET}"
    echo ""
    echo "  1) 默认拒绝入站，允许出站（推荐）$(
        [[ "$current_policy" == "deny" ]] && echo " ${GREEN}← 当前${RESET}")"
    echo "  2) 默认允许所有$(
        [[ "$current_policy" == "allow" ]] && echo " ${GREEN}← 当前${RESET}")"
    echo "  0) 返回"
    echo ""
    local choice
    read -rp "选择 [1]: " choice
    case "${choice:-1}" in
        1)
            case "$OS_FAMILY" in
                debian)
                    ufw default deny incoming
                    ufw default allow outgoing
                    ;;
                rhel)
                    firewall-cmd --set-default-zone=drop 2>/dev/null
                    ;;
            esac
            log_info "已设置默认策略: 拒绝入站，允许出站"
            ;;
        2)
            case "$OS_FAMILY" in
                debian)
                    ufw default allow incoming
                    ufw default allow outgoing
                    ;;
                rhel)
                    firewall-cmd --set-default-zone=trusted 2>/dev/null
                    ;;
            esac
            log_info "已设置默认策略: 允许所有"
            ;;
        0) skip_pause; return ;;
        *) log_warn "无效选择，未做任何更改" ;;
    esac
}

fw_enable() {
    detect_ssh_port
    log_warn "启用防火墙前，将自动放行当前 SSH 端口: ${CURRENT_SSH_PORT}"
    fw_allow_port_internal "$CURRENT_SSH_PORT" "tcp"

    if ! confirm "确认启用防火墙? (SSH 端口 ${CURRENT_SSH_PORT} 已放行)"; then
        skip_pause
        return
    fi

    case "$OS_FAMILY" in
        debian)
            command -v ufw &>/dev/null || install_pkg ufw
            ufw --force enable
            systemctl enable ufw
            ;;
        rhel)
            systemctl start firewalld
            systemctl enable firewalld
            ;;
    esac
    log_info "防火墙已启用"
}

fw_disable() {
    log_warn "禁用防火墙将移除所有端口限制"
    if ! confirm "确认禁用防火墙?"; then skip_pause; return; fi
    case "$OS_FAMILY" in
        debian) ufw disable ;;
        rhel) systemctl stop firewalld ;;
    esac
    log_info "防火墙已禁用"
}
fw_status() {
    echo ""
    echo "${BOLD}防火墙状态:${RESET}"
    case "$OS_FAMILY" in
        debian)
            if command -v ufw &>/dev/null; then
                ufw status verbose
            else
                log_warn "ufw 未安装"
            fi
            ;;
        rhel)
            if systemctl is-active firewalld &>/dev/null; then
                firewall-cmd --list-all
            else
                log_warn "firewalld 未运行"
            fi
            ;;
    esac
}

menu_firewall() {
    while true; do
        echo ""
        local fw_name
        case "$OS_FAMILY" in
            debian) fw_name="ufw" ;;
            rhel) fw_name="firewalld" ;;
            *) fw_name="防火墙" ;;
        esac
        echo "${BOLD}====== 防火墙管理 (${fw_name}) ======${RESET}"
        echo "  1) 放行端口"
        echo "  2) 关闭端口"
        echo "  3) 设置默认策略"
        echo "  4) 启用防火墙"
        echo "  5) 禁用防火墙"
        echo "  6) 查看状态"
        echo "  0) 返回主菜单"
        echo ""
        local choice
        read -rp "选择: " choice
        case "$choice" in
            1) fw_allow_port ;;
            2) fw_deny_port ;;
            3) fw_set_default ;;
            4) fw_enable ;;
            5) fw_disable ;;
            6) fw_status ;;
            0) return ;;
            *) log_warn "无效选择"; continue ;;
        esac
        press_enter
    done
}
# ===== 模块 5: 一键推荐加固 =====
quick_harden() {
    echo ""
    echo "${BOLD}${BLUE}====== 一键推荐加固 ======${RESET}"
    echo ""
    echo "将按以下顺序执行（每步可跳过）:"
    echo "  1. 检测系统环境"
    echo "  2. SSH 端口设置"
    echo "  3. SSH 密钥配置"
    echo "  4. 防火墙配置"
    echo "  5. 安装 Fail2ban"
    echo "  6. 禁用密码登录"
    echo "  7. 限制 root 登录"
    echo ""
    if ! confirm "开始一键加固?"; then return; fi

    log_info "=== 步骤 1/7: 检测系统环境 ==="
    detect_os
    detect_ssh_port
    echo ""

    log_info "=== 步骤 2/7: SSH 端口设置 ==="
    echo "当前 SSH 端口: ${CURRENT_SSH_PORT}"
    echo "  1) 保持当前端口 ${CURRENT_SSH_PORT}"
    echo "  2) 输入自定义高位端口"
    echo "  3) 随机生成高位端口"
    local port_choice new_port
    read -rp "选择 [1]: " port_choice
    case "${port_choice:-1}" in
        2)
            new_port=$(read_uint "输入新端口 (10000-65535): " "" 10000 65535) || new_port=""
            if [[ -n "$new_port" ]]; then
                fw_allow_port_internal "$new_port" "tcp"
                selinux_add_port "$new_port"
                apply_sshd_setting "Port" "$new_port"
                CURRENT_SSH_PORT="$new_port"
            else
                log_info "已取消，保持当前端口 ${CURRENT_SSH_PORT}"
            fi
            ;;
        3)
            new_port=$(random_high_port)
            log_info "随机端口: ${new_port}"
            fw_allow_port_internal "$new_port" "tcp"
            selinux_add_port "$new_port"
            apply_sshd_setting "Port" "$new_port"
            CURRENT_SSH_PORT="$new_port"
            ;;
        *) log_info "保持当前端口 ${CURRENT_SSH_PORT}" ;;
    esac
    echo ""
    log_info "=== 步骤 3/7: SSH 密钥配置 ==="
    local target_user input_user
    target_user="${SUDO_USER:-root}"
    read -rp "目标用户 [${target_user}]: " input_user
    target_user="${input_user:-$target_user}"

    if check_authorized_keys "$target_user"; then
        log_info "用户 ${target_user} 已有有效公钥"
        if confirm "是否添加更多公钥?"; then
            echo "  1) 服务器端生成新密钥对"
            echo "  2) 粘贴已有公钥"
            local key_choice
            read -rp "选择: " key_choice
            case "$key_choice" in
                1) generate_keypair ;;
                2) import_pubkey ;;
            esac
        fi
    else
        log_warn "用户 ${target_user} 没有有效公钥，需要先配置密钥"
        echo "  1) 服务器端生成新密钥对"
        echo "  2) 粘贴已有公钥"
        local key_choice
        read -rp "选择: " key_choice
        case "$key_choice" in
            1) generate_keypair ;;
            2) import_pubkey ;;
            *) log_warn "跳过密钥配置" ;;
        esac
    fi
    echo ""

    log_info "=== 步骤 4/7: 防火墙配置 ==="
    if confirm "启用防火墙并设置默认拒绝入站?"; then
        fw_allow_port_internal "$CURRENT_SSH_PORT" "tcp"
        case "$OS_FAMILY" in
            debian)
                command -v ufw &>/dev/null || install_pkg ufw
                ufw default deny incoming
                ufw default allow outgoing
                ufw --force enable
                systemctl enable ufw
                ;;
            rhel)
                systemctl start firewalld 2>/dev/null
                systemctl enable firewalld
                firewall-cmd --permanent --add-port="${CURRENT_SSH_PORT}/tcp" >/dev/null 2>&1
                firewall-cmd --reload >/dev/null 2>&1
                ;;
        esac
        log_info "防火墙已启用，SSH 端口 ${CURRENT_SSH_PORT} 已放行"
    fi
    echo ""
    log_info "=== 步骤 5/7: 安装 Fail2ban ==="
    if confirm "安装并配置 Fail2ban?"; then
        if install_fail2ban; then
            local jail_dir="/etc/fail2ban/jail.d"
            mkdir -p "$jail_dir"
            cat > "${jail_dir}/sshd-ssh-safekit.local" <<EOF
[sshd]
enabled = true
port = ${CURRENT_SSH_PORT}
filter = sshd
backend = systemd
bantime = 3600
findtime = 600
maxretry = 5
banaction = %(banaction_allports)s
EOF
            systemctl restart fail2ban
            log_info "Fail2ban 已配置 (bantime=3600s, maxretry=5)"
        fi
    fi
    echo ""

    log_info "=== 步骤 6/7: 禁用密码登录 ==="
    if check_authorized_keys "$target_user"; then
        if confirm "禁用密码登录（仅允许密钥登录）?"; then
            apply_sshd_setting "PasswordAuthentication" "no"
            disable_kbd_interactive
            log_info "密码登录已禁用"
        fi
    else
        log_error "用户 ${target_user} 没有有效公钥，跳过禁用密码登录"
    fi
    echo ""

    log_info "=== 步骤 7/7: 限制 root 登录 ==="
    if confirm "设置 root 仅允许密钥登录 (PermitRootLogin prohibit-password)?"; then
        apply_sshd_setting "PermitRootLogin" "prohibit-password"
    fi
    if confirm "锁定 root 密码 (passwd -l root)?"; then
        passwd -l root
        log_info "root 密码已锁定"
    fi
    echo ""

    # 最终摘要
    echo "${BOLD}${GREEN}====== 加固完成 ======${RESET}"
    echo ""
    echo "  SSH 端口:        ${CURRENT_SSH_PORT}"
    echo "  密码登录:        $(sshd -T 2>/dev/null | grep -i passwordauthentication | awk '{print $2}')"
    echo "  Root 登录:       $(sshd -T 2>/dev/null | grep -i permitrootlogin | awk '{print $2}')"
    echo "  防火墙:          $(fw_status_oneliner)"
    echo "  Fail2ban:        $(systemctl is-active fail2ban 2>/dev/null || echo '未安装')"
    echo ""
    log_warn "请立即用新配置测试 SSH 连接，不要关闭当前会话！"
    log_warn "测试命令: ssh -p ${CURRENT_SSH_PORT} ${target_user}@<服务器IP>"
    if [[ "$CURRENT_SSH_PORT" != "22" ]]; then
        log_warn "如果是云服务器，请确认安全组已放行端口 ${CURRENT_SSH_PORT}/TCP"
    fi
    press_enter
}

fw_status_oneliner() {
    case "$OS_FAMILY" in
        debian)
            if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
                echo "ufw 已启用"
            else
                echo "未启用"
            fi
            ;;
        rhel)
            if systemctl is-active firewalld &>/dev/null; then
                echo "firewalld 已启用"
            else
                echo "未启用"
            fi
            ;;
        *) echo "未知" ;;
    esac
}
# ===== 模块 6: 状态查看 =====
show_status() {
    echo ""
    echo "${BOLD}${BLUE}====== 系统安全状态 ======${RESET}"
    echo ""

    echo "${BOLD}[系统]${RESET}"
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        echo "  发行版: ${PRETTY_NAME:-$ID}"
    fi
    echo "  内核:   $(uname -r)"
    echo "  主机名: $(hostname)"
    echo ""

    echo "${BOLD}[SSH 配置]${RESET}"
    if command -v sshd &>/dev/null; then
        local conf
        conf=$(sshd -T 2>/dev/null)
        echo "  端口:                  $(echo "$conf" | grep -i "^port " | awk '{print $2}' | paste -sd, -)"
        echo "  地址族 (IPv4/v6):      $(echo "$conf" | grep -i "^addressfamily" | awk '{print $2}')"
        echo "  PermitRootLogin:       $(echo "$conf" | grep -i "^permitrootlogin" | awk '{print $2}')"
        echo "  PasswordAuthentication:$(echo "$conf" | grep -i "^passwordauthentication" | awk '{print $2}')"
        echo "  PubkeyAuthentication:  $(echo "$conf" | grep -i "^pubkeyauthentication" | awk '{print $2}')"
        echo "  MaxAuthTries:          $(echo "$conf" | grep -i "^maxauthtries" | awk '{print $2}')"
        echo "  LoginGraceTime:        $(echo "$conf" | grep -i "^logingracetime" | awk '{print $2}')"
        echo "  ClientAliveInterval:   $(echo "$conf" | grep -i "^clientaliveinterval" | awk '{print $2}')"
        echo "  ClientAliveCountMax:   $(echo "$conf" | grep -i "^clientalivecountmax" | awk '{print $2}')"
    else
        log_warn "sshd 未安装"
    fi
    echo ""

    echo "${BOLD}[Root 密码状态]${RESET}"
    if command -v passwd &>/dev/null; then
        local rs
        rs=$(passwd -S root 2>/dev/null | awk '{print $2}')
        case "$rs" in
            L) echo "  root 密码已锁定 (L)" ;;
            P) echo "  root 有可用密码 (P)" ;;
            NP) echo "  root 无密码 (NP)" ;;
            *) echo "  未知状态: $rs" ;;
        esac
    fi
    echo ""

    echo "${BOLD}[防火墙]${RESET}"
    if [[ -z "$OS_FAMILY" ]]; then detect_os; fi
    case "$OS_FAMILY" in
        debian)
            if command -v ufw &>/dev/null; then
                ufw status verbose | sed 's/^/  /'
            else
                echo "  ufw 未安装"
            fi
            ;;
        rhel)
            if systemctl is-active firewalld &>/dev/null; then
                firewall-cmd --list-all | sed 's/^/  /'
            else
                echo "  firewalld 未运行"
            fi
            ;;
    esac
    echo ""
    echo "${BOLD}[Fail2ban]${RESET}"
    if command -v fail2ban-client &>/dev/null; then
        if systemctl is-active fail2ban &>/dev/null; then
            fail2ban-client status sshd 2>/dev/null | sed 's/^/  /' || echo "  sshd jail 未启用"
        else
            echo "  fail2ban 未运行"
        fi
    else
        echo "  fail2ban 未安装"
    fi
    echo ""

    echo "${BOLD}[当前 SSH 会话]${RESET}"
    who | sed 's/^/  /'
    echo ""

    echo "${BOLD}[监听端口]${RESET}"
    ss -tlnp 2>/dev/null | head -20 | sed 's/^/  /'
    echo ""
}

# ===== 模块 7: 从备份还原 =====
restore_backup() {
    echo ""
    if [[ ! -d "$BACKUP_DIR" ]]; then
        log_warn "备份目录不存在: ${BACKUP_DIR}"
        return
    fi

    local backups=()
    while IFS= read -r f; do
        backups+=("$f")
    done < <(ls -1t "${BACKUP_DIR}"/sshd_config.bak.* 2>/dev/null | grep -v '\.dropin$')

    if [[ ${#backups[@]} -eq 0 ]]; then
        log_warn "未找到 sshd_config 备份文件"
        return
    fi

    echo "${BOLD}可用备份:${RESET}"
    local i=1
    for b in "${backups[@]}"; do
        local mtime
        mtime=$(stat -c '%y' "$b" 2>/dev/null | cut -d. -f1)
        echo "  ${i}) $(basename "$b")  [${mtime}]"
        ((i++))
    done
    echo "  0) 取消"
    echo ""
    local choice
    read -rp "选择要还原的备份: " choice
    if [[ "$choice" == "0" || -z "$choice" ]]; then return; fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#backups[@]} ]]; then
        log_error "无效选择"
        return
    fi

    local target="${backups[$((choice-1))]}"
    log_warn "将从 ${target} 还原 sshd 配置"
    if ! confirm "确认还原?"; then return; fi

    rollback_sshd "$target"
    press_enter
}
# ===== 主菜单 =====
print_banner() {
    cat <<EOF
${BOLD}${BLUE}
============================================================
   ssh-safekit  v${SAFEKIT_VERSION}   -  Linux SSH 安全加固工具
   【开源地址】 https://github.com/DsureD/ssh-safekit
============================================================
${RESET}
EOF
    echo "  日志文件: ${LOG_FILE}"
    echo "  备份目录: ${BACKUP_DIR}"
    echo ""
}

main_menu() {
    while true; do
        clear
        print_banner
        echo "${BOLD}主菜单${RESET}"
        echo "  1) SSH 配置管理 (root / 密码 / 端口 / 限制)"
        echo "  2) SSH 密钥管理 (生成 / 导入 / 查看)"
        echo "  3) Fail2ban 管理"
        echo "  4) 防火墙管理 (ufw / firewalld)"
        echo "  5) ${GREEN}一键推荐加固${RESET}"
        echo "  6) 查看当前安全状态"
        echo "  7) 从备份还原 SSH 配置"
        echo "  0) 退出"
        echo ""
        local choice
        read -rp "请选择: " choice
        case "$choice" in
            1) menu_ssh_config ;;
            2) menu_ssh_keys ;;
            3) menu_fail2ban ;;
            4) menu_firewall ;;
            5) quick_harden ;;
            6) show_status; press_enter ;;
            7) restore_backup ;;
            0) log_info "退出"; exit 0 ;;
            *) log_warn "无效选择"; sleep 1 ;;
        esac
    done
}

# ===== CLI 参数与入口 =====
usage() {
    cat <<EOF
ssh-safekit v${SAFEKIT_VERSION} - Linux SSH 安全加固工具

用法: $0 [选项]

选项:
  -h, --help      显示帮助信息
  -v, --version   显示版本号
  --status        显示当前安全状态（非交互）
  --quick         启动一键加固流程

无参数时进入交互式菜单。
EOF
}

init() {
    check_root
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || {
        log_warn "无法写入日志文件 ${LOG_FILE}，将仅输出到终端"
    }
    chmod 600 "$LOG_FILE" 2>/dev/null || true
    rotate_log
    detect_os
    detect_ssh_port
    mkdir -p "$BACKUP_DIR"
}

# 解析 CLI 参数
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    -v|--version) echo "ssh-safekit v${SAFEKIT_VERSION}"; exit 0 ;;
    --status) RUN_MODE="status" ;;
    --quick) RUN_MODE="quick" ;;
    "") RUN_MODE="menu" ;;
    *) echo "未知选项: $1"; usage; exit 1 ;;
esac

init

case "$RUN_MODE" in
    status) show_status ;;
    quick) quick_harden ;;
    menu) main_menu ;;
esac
