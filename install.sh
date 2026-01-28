#!/bin/bash

# ================= 样式定义 =================
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
PURPLE='\033[1;35m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
RESET='\033[0m'
HR="════════════════════════════════════════════════════════════════"

# 打印带样式的分隔线
print_hr() {
    echo -e "${PURPLE}${HR}${RESET}"
}

# 打印标题
print_title() {
    echo -e "\n${PURPLE}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${PURPLE}${BOLD}  $1${RESET}"
    echo -e "${PURPLE}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}\n"
}

# 打印信息
print_info() {
    echo -e "${CYAN}✦ $1${RESET}"
}

print_success() {
    echo -e "${GREEN}✓ $1${RESET}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${RESET}"
}

print_error() {
    echo -e "${RED}✗ $1${RESET}"
}

# 等待用户输入（带样式）
read_input() {
    echo -ne "${CYAN}└── ${BOLD}请选择操作 (1-8): ${RESET}"
}

# 等待用户确认
read_confirm() {
    echo -ne "${YELLOW}└── ${BOLD}$1 (y/N): ${RESET}"
}

# ================= 主脚本开始 =================

# 限制脚本仅支持基于 Debian/Ubuntu 的系统
if ! command -v apt-get &> /dev/null; then
    print_error "此脚本仅支持基于 Debian/Ubuntu 的系统，请在支持 apt-get 的系统上运行！"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    exit 1
fi

# 检查并安装必要的依赖
REQUIRED_CMDS=("curl" "wget" "dpkg" "awk" "sed" "sysctl" "jq" "tar")
MISSING_CMDS=()

for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v $cmd &> /dev/null; then
        MISSING_CMDS+=("$cmd")
    fi
done

if [ ${#MISSING_CMDS[@]} -gt 0 ]; then
    print_warning "检测到缺少以下依赖: ${MISSING_CMDS[*]}"
    echo -e "${CYAN}└── 正在安装依赖...${RESET}"
    sudo apt-get update > /dev/null 2>&1
    for cmd in "${MISSING_CMDS[@]}"; do
        sudo apt-get install -y $cmd > /dev/null 2>&1 && \
        echo -e "  ${GREEN}✓ ${cmd} 安装完成${RESET}"
    done
fi

# 检测系统架构
ARCH=$(uname -m)
if [[ "$ARCH" != "aarch64" && "$ARCH" != "x86_64" ]]; then
    print_error "此脚本仅支持 ARM 和 x86_64 架构"
    echo -e "${YELLOW}└── 当前系统架构: $ARCH${RESET}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    exit 1
fi

ARCH_TAG=""
[[ "$ARCH" == "aarch64" ]] && ARCH_TAG="arm64"
[[ "$ARCH" == "x86_64" ]] && ARCH_TAG="amd64"

# 当前状态
CURRENT_ALGO=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
CURRENT_QDISC=$(sysctl net.core.default_qdisc | awk '{print $3}')

SYSCTL_CONF="/etc/sysctl.d/99-jXiaokail.conf"
MODULES_CONF="/etc/modules-load.d/Xiaokail-qdisc.conf"

KERNEL_VERSION_URL="https://raw.githubusercontent.com/Xiaokailnol/Kernel-BBRv3/refs/heads/master/kernel-version"
DOWNLOAD_BASE="https://github.com/Xiaokailnol/Kernel-BBRv3/releases/download"

# ================= 内核相关函数 =================

get_latest_kernel_version() {
    print_info "正在获取最新内核版本信息..."
    VERSION=$(curl -fsSL "$KERNEL_VERSION_URL")
    if [[ -z "$VERSION" ]]; then
        print_error "获取 kernel-version 失败"
        echo -e "${YELLOW}└── 请检查网络连接或仓库状态${RESET}"
        return 1
    fi
}

get_installed_version() {
    dpkg -l | grep "linux-image" | grep "joeyblog" | awk '{print $2}' | sed 's/linux-image-//' | head -n 1
}

update_bootloader() {
    print_info "正在更新引导加载程序..."
    if command -v update-grub &> /dev/null; then
        sudo update-grub > /dev/null 2>&1 && \
        print_success "GRUB 引导程序已更新"
    else
        print_warning "未检测到 GRUB，ARM/U-Boot 系统通常无需手动更新"
    fi
}

install_packages() {
    if ! ls /tmp/linux-*.deb &>/dev/null; then
        print_error "未找到内核安装包"
        return 1
    fi

    OLD_PKGS=$(dpkg -l | grep "joeyblog" | awk '{print $2}')
    if [[ -n "$OLD_PKGS" ]]; then
        print_info "正在清理旧版本内核..."
        sudo apt-get remove --purge -y $OLD_PKGS > /dev/null 2>&1
    fi

    print_info "正在安装新内核..."
    sudo dpkg -i /tmp/linux-*.deb 2>/dev/null || sudo apt -f install -y > /dev/null 2>&1
    update_bootloader

    print_success "内核安装完成！"
    echo -e "${YELLOW}══════════════════════════════════════════════════════${RESET}"
    
    read_confirm "需要重启系统来加载新内核，是否立即重启？"
    read -r REBOOT
    if [[ "$REBOOT" =~ ^[Yy]$ ]]; then
        print_info "系统即将重启..."
        sleep 2
        sudo reboot
    else
        print_info "请稍后手动重启系统以完成内核更新"
    fi
}

# ================= 新的下载 + 解压逻辑 =================

download_and_extract_tar() {
    local VERSION="$1"
    
    TAR_NAME="${VERSION}.tar.gz"
    TAR_URL="${DOWNLOAD_BASE}/kernel_${ARCH_TAG}_stable/${TAR_NAME}"

    print_info "下载内核包: ${VERSION}"
    echo -e "${CYAN}└── 下载地址: $TAR_URL${RESET}"

    rm -rf /tmp/kernel /tmp/linux-*.deb /tmp/kernel.tar.gz
    mkdir -p /tmp/kernel

    print_info "正在下载内核包..."
    if ! wget -q --show-progress -O /tmp/kernel.tar.gz "$TAR_URL"; then
        print_error "下载失败"
        return 1
    fi

    print_info "正在解压文件..."
    tar -xzf /tmp/kernel.tar.gz -C /tmp/kernel

    if ! ls /tmp/kernel/rom/linux-*.deb &>/dev/null; then
        print_error "未找到内核安装文件"
        return 1
    fi

    cp /tmp/kernel/rom/linux-*.deb /tmp/
    print_success "文件准备完成"
}

# ================= 安装最新版本 =================

install_latest_version() {
    print_title "安装最新版内核"
    
    get_latest_kernel_version || return 1

    echo -e "${CYAN}┌──────────────────────────────────────────────────────${RESET}"
    echo -e "${CYAN}  最新版本: ${GREEN}${BOLD}${VERSION}${RESET}"
    
    INSTALLED_VERSION=$(get_installed_version)
    if [[ -n "$INSTALLED_VERSION" ]]; then
        echo -e "${CYAN}  当前版本: ${YELLOW}${INSTALLED_VERSION}${RESET}"
    else
        echo -e "${CYAN}  当前版本: ${YELLOW}未安装${RESET}"
    fi
    echo -e "${CYAN}└──────────────────────────────────────────────────────${RESET}"

    if [[ "$INSTALLED_VERSION" == "$VERSION"* ]]; then
        print_success "已是最新版本，无需更新！"
        echo -e "${GREEN}╰──────────────────────────────────────────────────────${RESET}"
        return 0
    fi

    download_and_extract_tar "$VERSION" || return 1
    install_packages
}

# ================= 安装指定版本 =================

install_specific_version() {
    print_title "安装指定版本内核"
    
    echo -ne "${CYAN}└── ${BOLD}请输入要安装的内核版本号（例如 6.18.7）: ${RESET}"
    read -r VERSION

    [[ -z "$VERSION" ]] && {
        print_error "版本号不能为空"
        return 1
    }

    print_info "准备安装版本: ${GREEN}${VERSION}${RESET}"
    
    download_and_extract_tar "$VERSION" || return 1
    install_packages
}

# ================= qdisc / BBR 相关 =================

clean_sysctl_conf() {
    sudo touch "$SYSCTL_CONF"
    sudo sed -i '/net.core.default_qdisc/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_congestion_control/d' "$SYSCTL_CONF"
}

load_qdisc_module() {
    local qdisc_name="$1"
    local module_name="sch_$qdisc_name"

    sudo sysctl -w net.core.default_qdisc="$qdisc_name" >/dev/null 2>&1 && {
        sudo sysctl -w net.core.default_qdisc="$CURRENT_QDISC" >/dev/null 2>&1
        return 0
    }

    sudo modprobe "$module_name" 2>/dev/null
}

ask_to_save() {
    local ALGO="$1"
    local QDISC="$2"
    
    print_info "正在应用临时配置..."
    load_qdisc_module "$QDISC"
    sudo sysctl -w net.core.default_qdisc="$QDISC" >/dev/null 2>&1
    sudo sysctl -w net.ipv4.tcp_congestion_control="$ALGO" >/dev/null 2>&1
    
    print_success "临时配置已生效"
    echo -e "${CYAN}┌──────────────────────────────────────────────────────${RESET}"
    echo -e "${CYAN}  算法: ${GREEN}${ALGO}${RESET}"
    echo -e "${CYAN}  队列: ${GREEN}${QDISC}${RESET}"
    echo -e "${CYAN}└──────────────────────────────────────────────────────${RESET}"

    read_confirm "是否永久保存此配置？"
    read -r SAVE
    
    if [[ "$SAVE" =~ ^[Yy]$ ]]; then
        print_info "正在保存配置到配置文件..."
        clean_sysctl_conf
        echo "net.core.default_qdisc=$QDISC" | sudo tee -a "$SYSCTL_CONF"
        echo "net.ipv4.tcp_congestion_control=$ALGO" | sudo tee -a "$SYSCTL_CONF"
        sudo sysctl --system >/dev/null 2>&1
        print_success "配置已永久保存"
    else
        print_info "配置将在重启后恢复原状"
    fi
}

# ================= 卸载内核 =================

uninstall_kernel() {
    print_title "卸载 BBR 内核"
    
    PKGS=$(dpkg -l | grep joeyblog | awk '{print $2}')
    if [[ -z "$PKGS" ]]; then
        print_warning "未找到需要卸载的内核包"
        return
    fi

    print_info "找到以下内核包:"
    for pkg in $PKGS; do
        echo -e "  ${YELLOW}•${RESET} $pkg"
    done
    
    read_confirm "确认要卸载这些内核包吗？"
    read -r CONFIRM
    
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        print_info "正在卸载..."
        sudo apt-get remove --purge -y $PKGS > /dev/null 2>&1
        update_bootloader
        print_success "内核卸载完成"
    else
        print_info "取消卸载"
    fi
}

# ================= 显示状态 =================

show_status() {
    print_title "当前 BBR 状态"
    
    echo -e "${CYAN}┌──────────────────────────────────────────────────────${RESET}"
    ALGO_STATUS=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null || echo "未启用")
    QDISC_STATUS=$(sysctl net.core.default_qdisc 2>/dev/null || echo "未设置")
    
    echo -e "${CYAN}  拥塞控制算法: ${GREEN}$ALGO_STATUS${RESET}"
    echo -e "${CYAN}  队列调度器:    ${GREEN}$QDISC_STATUS${RESET}"
    echo -e "${CYAN}└──────────────────────────────────────────────────────${RESET}"
    
    print_info "内核模块信息:"
    if modinfo tcp_bbr &>/dev/null; then
        BBR_VERSION=$(modinfo tcp_bbr | grep -i version | head -1 | awk '{print $2}')
        echo -e "  ${GREEN}✓${RESET} BBR 版本: ${BBR_VERSION:-未知}"
    else
        echo -e "  ${RED}✗${RESET} BBR 模块未加载"
    fi
}

# ================= 主菜单 =================

show_menu() {
    clear
    echo -e "${PURPLE}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                                                              ║"
    echo "║              🚀 Xiaokail BBR v3 管理脚本                     ║"
    echo "║                                                              ║"
    echo "╚══════════════════════════════════════════════════════════════╝${RESET}"
    
    echo -e "${CYAN}${BOLD}"
    echo "┌──────────────────────────────────────────────────────────────┐"
    echo "  系统信息"
    echo "├──────────────────────────────────────────────────────────────┤"
    echo "  架构: ${ARCH} | 算法: ${CURRENT_ALGO} | 队列: ${CURRENT_QDISC}"
    echo "└──────────────────────────────────────────────────────────────┘${RESET}"
    
    echo -e "\n${BLUE}${BOLD}请选择操作:${RESET}"
    echo -e "${WHITE}  ${BOLD}1.${RESET} 🚀 安装/更新 BBR v3 (最新版)"
    echo -e "${WHITE}  ${BOLD}2.${RESET} 📦 安装指定版本内核"
    echo -e "${WHITE}  ${BOLD}3.${RESET} 🔍 查看当前 BBR 状态"
    echo -e "${WHITE}  ${BOLD}4.${RESET} ⚡ 启用 BBR + FQ"
    echo -e "${WHITE}  ${BOLD}5.${RESET} ⚡ 启用 BBR + FQ_CODEL"
    echo -e "${WHITE}  ${BOLD}6.${RESET} ⚡ 启用 BBR + FQ_PIE"
    echo -e "${WHITE}  ${BOLD}7.${RESET} ⚡ 启用 BBR + CAKE"
    echo -e "${WHITE}  ${BOLD}8.${RESET} 🗑️  卸载 BBR 内核"
    echo -e "${WHITE}  ${BOLD}0.${RESET} 📤 退出脚本"
    echo -e "${YELLOW}══════════════════════════════════════════════════════════════${RESET}"
}

# ================= 主循环 =================

while true; do
    show_menu
    read_input
    read -r ACTION
    
    case "$ACTION" in
        1) 
            install_latest_version
            echo -e "\n${YELLOW}按 Enter 键继续...${RESET}"
            read -r
            ;;
        2) 
            install_specific_version
            echo -e "\n${YELLOW}按 Enter 键继续...${RESET}"
            read -r
            ;;
        3) 
            show_status
            echo -e "\n${YELLOW}按 Enter 键继续...${RESET}"
            read -r
            ;;
        4) 
            ask_to_save "bbr" "fq"
            echo -e "\n${YELLOW}按 Enter 键继续...${RESET}"
            read -r
            ;;
        5) 
            ask_to_save "bbr" "fq_codel"
            echo -e "\n${YELLOW}按 Enter 键继续...${RESET}"
            read -r
            ;;
        6) 
            ask_to_save "bbr" "fq_pie"
            echo -e "\n${YELLOW}按 Enter 键继续...${RESET}"
            read -r
            ;;
        7) 
            ask_to_save "bbr" "cake"
            echo -e "\n${YELLOW}按 Enter 键继续...${RESET}"
            read -r
            ;;
        8) 
            uninstall_kernel
            echo -e "\n${YELLOW}按 Enter 键继续...${RESET}"
            read -r
            ;;
        0) 
            echo -e "\n${GREEN}感谢使用，再见！ 👋${RESET}"
            exit 0
            ;;
        *) 
            print_error "无效选项，请重新输入"
            sleep 1
            ;;
    esac
done
