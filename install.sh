#!/bin/bash

# 限制脚本仅支持基于 Debian/Ubuntu 的系统
if ! command -v apt-get &> /dev/null; then
    echo -e "\033[31m此脚本仅支持基于 Debian/Ubuntu 的系统，请在支持 apt-get 的系统上运行！\033[0m"
    exit 1
fi

# 检查并安装必要的依赖
REQUIRED_CMDS=("curl" "wget" "dpkg" "awk" "sed" "sysctl" "jq" "tar")
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "\033[33m缺少依赖：$cmd，正在安装...\033[0m"
        sudo apt-get update && sudo apt-get install -y $cmd > /dev/null 2>&1
    fi
done

# 检测系统架构
ARCH=$(uname -m)
if [[ "$ARCH" != "aarch64" && "$ARCH" != "x86_64" ]]; then
    echo -e "\033[31m(￣□￣)哇！这个脚本只支持 ARM 和 x86_64 架构哦~ 您的系统架构是：$ARCH\033[0m"
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
    VERSION=$(curl -fsSL "$KERNEL_VERSION_URL")
    if [[ -z "$VERSION" ]]; then
        echo -e "\033[31m获取 kernel-version 失败\033[0m"
        return 1
    fi
}

get_installed_version() {
    dpkg -l | grep "linux-image" | grep "joeyblog" | awk '{print $2}' | sed 's/linux-image-//' | head -n 1
}

update_bootloader() {
    echo -e "\033[36m正在更新引导加载程序...\033[0m"
    if command -v update-grub &> /dev/null; then
        sudo update-grub
    else
        echo -e "\033[33m未检测到 GRUB，ARM/U-Boot 系统通常无需手动更新。\033[0m"
    fi
}

install_packages() {
    if ! ls /tmp/linux-*.deb &>/dev/null; then
        echo -e "\033[31m错误：未找到内核 deb 文件\033[0m"
        return 1
    fi

    OLD_PKGS=$(dpkg -l | grep "joeyblog" | awk '{print $2}')
    [[ -n "$OLD_PKGS" ]] && sudo apt-get remove --purge -y $OLD_PKGS > /dev/null 2>&1

    sudo dpkg -i /tmp/linux-*.deb || sudo apt -f install -y
    update_bootloader

    echo -n -e "\033[33m需要重启系统来加载新内核，是否立即重启？ (y/n): \033[0m"
    read -r REBOOT
    [[ "$REBOOT" =~ ^[Yy]$ ]] && sudo reboot
}

# ================= 新的下载 + 解压逻辑 =================

download_and_extract_tar() {
    local VERSION="$1"

    TAR_NAME="${VERSION}.tar.gz"
    TAR_URL="${DOWNLOAD_BASE}/kernel_${ARCH_TAG}_stable/${TAR_NAME}"

    echo -e "\033[36m下载内核包：$TAR_URL\033[0m"

    rm -rf /tmp/kernel /tmp/linux-*.deb /tmp/kernel.tar.gz
    mkdir -p /tmp/kernel

    wget -O /tmp/kernel.tar.gz "$TAR_URL" || {
        echo -e "\033[31m下载失败\033[0m"
        return 1
    }

    tar -xzf /tmp/kernel.tar.gz -C /tmp/kernel

    if ! ls /tmp/kernel/rom/linux-*.deb &>/dev/null; then
        echo -e "\033[31mrom 目录中未找到内核 deb 文件\033[0m"
        return 1
    fi

    cp /tmp/kernel/rom/linux-*.deb /tmp/
}

# ================= 安装最新版本 =================

install_latest_version() {
    echo -e "\033[36m正在获取最新内核版本...\033[0m"
    get_latest_kernel_version || return 1

    echo -e "\033[36m检测到最新版本：\033[1;32m$VERSION\033[0m"

    INSTALLED_VERSION=$(get_installed_version)
    echo -e "\033[36m当前已安装版本：\033[1;32m${INSTALLED_VERSION:-未安装}\033[0m"

    [[ "$INSTALLED_VERSION" == "$VERSION"* ]] && {
        echo -e "\033[1;32m(o'▽'o) 已是最新版本，无需更新！\033[0m"
        return 0
    }

    download_and_extract_tar "$VERSION" || return 1
    install_packages
}

# ================= 安装指定版本 =================

install_specific_version() {
    echo -n -e "\033[36m请输入要安装的内核版本号（例如 6.18.7）：\033[0m"
    read -r VERSION

    [[ -z "$VERSION" ]] && { echo "版本号不能为空"; return 1; }

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
    load_qdisc_module "$QDISC"
    sudo sysctl -w net.core.default_qdisc="$QDISC"
    sudo sysctl -w net.ipv4.tcp_congestion_control="$ALGO"

    echo -n -e "\033[36m是否永久保存配置？(y/n): \033[0m"
    read -r SAVE
    [[ "$SAVE" =~ ^[Yy]$ ]] || return

    clean_sysctl_conf
    echo "net.core.default_qdisc=$QDISC" | sudo tee -a "$SYSCTL_CONF"
    echo "net.ipv4.tcp_congestion_control=$ALGO" | sudo tee -a "$SYSCTL_CONF"
    sudo sysctl --system >/dev/null
}

# ================= 菜单 =================

clear
echo "=============================================="
echo "             Xiaokail BBR v3 管理脚本         "
echo "=============================================="
echo "当前算法：$CURRENT_ALGO"
echo "当前队列：$CURRENT_QDISC"
echo
echo "1. 🚀 安装 / 更新 BBR v3（最新版）"
echo "2. 📦 安装指定版本"
echo "3. 🔍 检查 BBR 状态"
echo "4. ⚡ 启用 BBR + FQ"
echo "5. ⚡ 启用 BBR + FQ_CODEL"
echo "6. ⚡ 启用 BBR + FQ_PIE"
echo "7. ⚡ 启用 BBR + CAKE"
echo "8. 🗑️  卸载 BBR 内核"
echo
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
    *) echo "无效选项" ;;
esac
