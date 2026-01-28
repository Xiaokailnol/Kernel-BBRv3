#!/bin/bash
# ==================================================
#  Kernel-BBRv3 Installer
# ==================================================

set -e

### ========= Root 检查 =========

if [[ $EUID -ne 0 ]]; then
  echo "请使用 root 运行（sudo bash install.sh）"
  exit 1
fi

### ========= 系统检查 =========

if ! command -v apt &>/dev/null; then
  echo "仅支持 Debian / Ubuntu"
  exit 1
fi

### ========= 架构判断 =========

ARCH_RAW=$(uname -m)
case "$ARCH_RAW" in
  x86_64) ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  *)
    echo "不支持的架构：$ARCH_RAW"
    exit 1
    ;;
esac

### ========= 仓库配置 =========

REPO="Xiaokailnol/Kernel-BBRv3"
KERNEL_VERSION_URL="https://raw.githubusercontent.com/${REPO}/refs/heads/master/kernel-version"
DOWNLOAD_BASE="https://github.com/${REPO}/releases/download"
ARCH_DIR="kernel_${ARCH}_stable"

TMP_TAR="/tmp/kernel.tar.gz"
TMP_DIR="/tmp/kernel"

### ========= 依赖 =========

need_cmd() {
  command -v "$1" &>/dev/null || {
    apt update
    apt install -y "$1"
  }
}

for c in curl wget tar dpkg sysctl; do
  need_cmd "$c"
done

### ========= 获取版本 =========

get_kernel_version() {
  KERNEL_VERSION=$(curl -fsSL "$KERNEL_VERSION_URL")
  if [[ -z "$KERNEL_VERSION" ]]; then
    echo "获取 kernel-version 失败"
    exit 1
  fi
}

### ========= 下载并解压 =========

download_and_extract() {
  get_kernel_version

  TAR_NAME="${KERNEL_VERSION}.tar.gz"
  TAR_URL="${DOWNLOAD_BASE}/${ARCH_DIR}/${TAR_NAME}"

  echo "======================================"
  echo " 架构     : $ARCH"
  echo " 版本     : $KERNEL_VERSION"
  echo " 下载地址 : $TAR_URL"
  echo "======================================"

  rm -rf "$TMP_DIR" /tmp/linux-*.deb "$TMP_TAR"
  mkdir -p "$TMP_DIR"

  echo "下载内核包..."
  wget -O "$TMP_TAR" "$TAR_URL"

  echo "解压内核包..."
  tar -xzf "$TMP_TAR" -C "$TMP_DIR"

  # 🔴 关键修正点：rom 目录
  if ! ls "$TMP_DIR"/rom/linux-*.deb &>/dev/null; then
    echo "未在 rom/ 目录中找到 linux-*.deb"
    exit 1
  fi

  cp "$TMP_DIR"/rom/linux-*.deb /tmp/
}

### ========= 安装内核 =========

install_kernel() {
  echo "安装内核..."
  dpkg -i /tmp/linux-*.deb || apt -f install -y

  echo "更新引导..."
  if command -v update-grub &>/dev/null; then
    update-grub
  fi
}

### ========= 启用 BBR =========

enable_bbr() {
  echo "启用 BBR v3..."

  modprobe tcp_bbr || true

  cat >/etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

  sysctl --system >/dev/null
}

### ========= 状态 =========

show_status() {
  echo
  echo "当前内核：$(uname -r)"
  echo "拥塞算法：$(sysctl -n net.ipv4.tcp_congestion_control)"
  echo "队列算法：$(sysctl -n net.core.default_qdisc)"
  echo
}

### ========= 菜单 =========

while true; do
  clear
  echo "======================================"
  echo " Kernel-BBRv3 安装脚本"
  echo "======================================"
  echo " 1. 安装 / 更新 内核"
  echo " 2. 启用 BBR v3"
  echo " 3. 查看当前状态"
  echo " 0. 退出"
  echo "--------------------------------------"
  read -rp "请选择: " menu

  case "$menu" in
    1)
      download_and_extract
      install_kernel
      echo
      echo "✔ 内核安装完成，请重启生效"
      read -rp "按回车返回菜单"
      ;;
    2)
      enable_bbr
      echo "✔ BBR 已启用"
      read -rp "按回车返回菜单"
      ;;
    3)
      show_status
      read -rp "按回车返回菜单"
      ;;
    0)
      exit 0
      ;;
    *)
      echo "无效选项"
      sleep 1
      ;;
  esac
done
