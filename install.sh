#!/bin/bash

# ==========================================================
#  Xiaokail BBR v3 Kernel Manager
#  Support: Debian / Ubuntu (ARM64 & AMD64)
# ==========================================================

# ------------------ 颜色定义 ------------------
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
BOLD="\033[1m"
RESET="\033[0m"

# ------------------ 系统环境检测 ------------------
if ! command -v apt-get &>/dev/null; then
    echo -e "${RED}❌ 此脚本仅支持基于 Debian/Ubuntu 的系统！${RESET}"
    exit 1
fi

# ------------------ 依赖检查 ------------------
REQUIRED_CMDS=(curl wget dpkg awk sed sysctl jq tar)
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${YELLOW}⚠️  缺少依赖：$cmd，正在安装...${RESET}"
        sudo apt-get update && sudo apt-get install -y "$cmd" >/dev/null 2>&1
    fi
done

# ------------------ 架构检测 ------------------
ARCH=$(uname -m)
case "$ARCH" in
    aarch64) ARCH_TAG="arm64" ;;
    x86_64)  ARCH_TAG="amd64" ;;
    *)
        echo -e "${RED}(￣□￣)！仅支持 ARM64 / x86_64，当前架构：$ARCH${RESET}"
        exit 1
        ;;
esac

# ------------------ 当前系统状态 ------------------
CURRENT_ALGO=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
CURRENT_QDISC=$(sysctl net.core.default_qdisc | awk '{print $3}')

SYSCTL_CONF="/etc/sysctl.d/99-jXiaokail.conf"
MODULES_CONF="/etc/modules-load.d/Xiaokail-qdisc.conf"

KERNEL_VERSION_URL="https://raw.githubusercontent.com/Xiaokailnol/Kernel-BBRv3/refs/heads/master/kernel-version"
DOWNLOAD_BASE="https://github.com/Xiaokailnol/Kernel-BBRv3/releases/download"

# ==========================================================
#                    内核相关函数
# ==========================================================

get_latest_kernel_version() {
    VERSION=$(curl -fsSL "$KERNEL_VERSION_URL")
    [[ -z "$VERSION" ]] && {
        echo -e "${RED}❌ 获取 kernel-version 失败${RESET}"
        return 1
    }
}

get_installed_version() {
    dpkg -l | grep linux-image | grep joeyblog \
        | awk '{print $2}' | sed 's/linux-image-//' | head -n 1
}

update_bootloader() {
    echo -e "${BLUE}🔄 更新引导加载程序...${RESET}"
    if command -v update-grub &>/dev/null; then
        sudo update-grub
    else
        echo -e "${YELLOW}⚠️  未检测到 GRUB（ARM / U-Boot 通常无需处理）${RESET}"
    fi
}

install_packages() {
    if ! ls /tmp/linux-*.deb &>/dev/null; then
        echo -e "${RED}❌ 未找到内核 deb 文件${RESET}"
        return 1
    fi

    OLD_PKGS=$(dpkg -l | grep joeyblog | awk '{print $2}')
    [[ -n "$OLD_PKGS" ]] && sudo apt-get remove --purge -y $OLD_PKGS >/dev/null 2>&1

    sudo dpkg -i /tmp/linux-*.deb || sudo apt -f install -y
    update_bootloader

    echo
    read -rp "${YELLOW}需要重启以加载新内核，是否立即重启？(y/n): ${RESET}" REBOOT
    [[ "$REBOOT" =~ ^[Yy]$ ]] && sudo reboot
}

# ==========================================================
#                  下载 & 解压逻辑
# ==========================================================
download_and_extract_tar() {
    local VERSION="$1"

    TAR_NAME="${VERSION}.tar.gz"
    TAR_URL="${DOWNLOAD_BASE}/kernel_${ARCH_TAG}_stable/${TAR_NAME}"

    echo -e "${BLUE}⬇️  下载内核包：$TAR_URL${RESET}"

    rm -rf /tmp/kernel /tmp/linux-*.deb /tmp/kernel.tar.gz
    mkdir -p /tmp/kernel

    wget -O /tmp/kernel.tar.gz "$TAR_URL" || {
        echo -e "${RED}❌ 下载失败${RESET}"
        return 1
    }

    tar -xzf /tmp/kernel.tar.gz -C /tmp/kernel

    if ! ls /tmp/kernel/rom/linux-*.deb &>/dev/null; then
        echo -e "${RED}❌ rom 目录中未找到内核 deb${RESET}"
        return 1
    fi

    cp /tmp/kernel/rom/linux-*.deb /tmp/
}

# ==========================================================
#                  安装相关操作
# ==========================================================
install_latest_version() {
    echo -e "${BLUE}🔍 获取最新内核版本...${RESET}"
    get_latest_kernel_version || return 1

    echo -e "${BLUE}最新版本：${GREEN}${BOLD}$VERSION${RESET}"

    INSTALLED_VERSION=$(get_installed_version)
    echo -e "${BLUE}当前版本：${GREEN}${BOLD}${INSTALLED_VERSION:-未安装}${RESET}"

    [[ "$INSTALLED_VERSION" == "$VERSION"* ]] && {
        echo -e "${GREEN}${BOLD}✔ 已是最新版本，无需更新${RESET}"
        return 0
    }

    download_and_extract_tar "$VERSION" || return 1
    install_packages
}

install_specific_version() {
    read -rp "${BLUE}请输入内核版本号（如 6.18.7）：${RESET}" VERSION
    [[ -z "$VERSION" ]] && { echo "版本号不能为空"; return 1; }

    download_and_extract_tar "$VERSION" || return 1
    install_packages
}

# ==========================================================
#                  qdisc / BBR 设置
# ==========================================================
clean_sysctl_conf() {
    sudo touch "$SYSCTL_CONF"
    sudo sed -i '/net.core.default_qdisc/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_congestion_control/d' "$SYSCTL_CONF"
}

load_qdisc_module() {
    local qdisc="$1"
    local module="sch_$qdisc"

    sudo sysctl -w net.core.default_qdisc="$qdisc" &>/dev/null && {
        sudo sysctl -w net.core.default_qdisc="$CURRENT_QDISC" &>/dev/null
        return 0
    }

    sudo modprobe "$module" 2>/dev/null
}

ask_to_save() {
    load_qdisc_module "$QDISC"
    sudo sysctl -w net.core.default_qdisc="$QDISC"
    sudo sysctl -w net.ipv4.tcp_congestion_control="$ALGO"

    read -rp "${BLUE}是否永久保存配置？(y/n): ${RESET}" SAVE
    [[ "$SAVE" =~ ^[Yy]$ ]] || return

    clean_sysctl_conf
    echo "net.core.default_qdisc=$QDISC" | sudo tee -a "$SYSCTL_CONF"
    echo "net.ipv4.tcp_congestion_control=$ALGO" | sudo tee -a "$SYSCTL_CONF"
    sudo sysctl --system >/dev/null
}

# ==========================================================
#                       菜单
# ==========================================================
clear
cat <<EOF
${BOLD}${BLUE}====================================================${RESET}
        🚀 Xiaokail BBR v3 管理脚本
${BOLD}${BLUE}====================================================${RESET}
 当前算法 : ${GREEN}${CURRENT_ALGO}${RESET}
 当前队列 : ${GREEN}${CURRENT_QDISC}${RESET}

 1. 🚀 安装 / 更新 BBR v3（最新版）
 2. 📦 安装指定版本
 3. 🔍 检查 BBR 状态
 4. ⚡ 启用 BBR + FQ
 5. ⚡ 启用 BBR + FQ_CODEL
 6. ⚡ 启用 BBR + FQ_PIE
 7. ⚡ 启用 BBR + CAKE
 8. 🗑️  卸载 BBR 内核
${BOLD}${BLUE}====================================================${RESET}
EOF

read -rp "请选择 (1-8): " ACTION

case "$ACTION" in
    1) install_latest_version ;;
    2) install_specific_version ;;
    3)
        sysctl net.ipv4.tcp_congestion_control
        modinfo tcp_bbr | grep version
        ;;
    4) ALGO="bbr"; QDISC="fq"; ask_to_save ;;
    5) ALGO="bbr"; QDISC="fq_codel"; ask_to_save ;;
    6) ALGO="bbr"; QDISC="fq_pie"; ask_to_save ;;
    7) ALGO="bbr"; QDISC="cake"; ask_to_save ;;
    8)
        PKGS=$(dpkg -l | grep joeyblog | awk '{print $2}')
        [[ -n "$PKGS" ]] && sudo apt-get remove --purge -y $PKGS && update_bootloader
        ;;
    *) echo -e "${RED}❌ 无效选项${RESET}" ;;
esac
