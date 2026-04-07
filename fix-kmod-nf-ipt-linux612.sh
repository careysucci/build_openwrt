#!/bin/bash
#
# File name: fix-kmod-nf-ipt-linux612.sh
# Description: Fix kmod-nf-ipt conflicts for Linux 6.12+
#
# This script automatically removes conflicting iptables modules
# that are incompatible with Linux 6.12 when using firewall4 (nftables)
#

set -e

# Get the target OpenWrt directory
TARGET_DIR="${TARGET_MATRIX:-.}"
CONFIG_FILE="$GITHUB_WORKSPACE/${CONFIG_FILE}"

echo "[INFO] Checking for Linux 6.12+ kernel compatibility..."

# Check if .config exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] Config file not found: $CONFIG_FILE"
    exit 1
fi

# Detect kernel version from config
KERNEL_VERSION=$(grep "CONFIG_LINUX_KERNEL_VERSION" "$CONFIG_FILE" | cut -d'=' -f2 | tr -d '"' 2>/dev/null || echo "")

if [ -z "$KERNEL_VERSION" ]; then
    KERNEL_VERSION=$(grep "^# Linux" "$CONFIG_FILE" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1 2>/dev/null || echo "")
fi

echo "[INFO] Detected kernel version: ${KERNEL_VERSION:-unknown}"

# Check if Linux 6.12 or later
if [ -n "$KERNEL_VERSION" ]; then
    MAJOR=$(echo "$KERNEL_VERSION" | cut -d'.' -f1)
    MINOR=$(echo "$KERNEL_VERSION" | cut -d'.' -f2)

    if [ "$MAJOR" -gt 6 ] || ([ "$MAJOR" -eq 6 ] && [ "$MINOR" -ge 12 ]); then
        echo "[INFO] Linux 6.12+ detected - Removing incompatible iptables modules..."

        # Remove conflicting kmod-nf-ipt packages
        sed -i '/CONFIG_PACKAGE_kmod-nf-ipt=/d' "$CONFIG_FILE"
        sed -i '/CONFIG_PACKAGE_kmod-nf-ipt6=/d' "$CONFIG_FILE"
        sed -i '/CONFIG_PACKAGE_kmod-ipt-core=/d' "$CONFIG_FILE"
        sed -i '/CONFIG_PACKAGE_kmod-iptables=/d' "$CONFIG_FILE"
        sed -i '/CONFIG_PACKAGE_kmod-ip6tables=/d' "$CONFIG_FILE"
        sed -i '/CONFIG_PACKAGE_kmod-ipt-.*=/d' "$CONFIG_FILE"

        # Explicitly add the nftables modules (safe for firewall4)
        echo "CONFIG_PACKAGE_kmod-nft-core=y" >> "$CONFIG_FILE"
        echo "CONFIG_PACKAGE_kmod-nft-fib=y" >> "$CONFIG_FILE"
        echo "CONFIG_PACKAGE_kmod-nft-nat=y" >> "$CONFIG_FILE"
        echo "CONFIG_PACKAGE_kmod-nft-offload=y" >> "$CONFIG_FILE"

        echo "[SUCCESS] Removed conflicting iptables modules for Linux 6.12+"
        echo "[INFO] Kept nftables modules for firewall4"
    else
        echo "[INFO] Linux ${MAJOR}.${MINOR} - No conflicts to fix"
    fi
else
    echo "[WARNING] Could not detect kernel version, skipping fix"
fi

echo "[INFO] Configuration fix complete"