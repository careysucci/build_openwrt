#!/bin/bash
#
# File name: fix-kmod-nf-ipt-linux612.sh
# Description: Fix kmod-nf-ipt conflicts for Linux 6.12+
# This script automatically removes kmod-nf-ipt dependencies for Linux 6.12
to prevent build failures with firewall4
#

set -e

TARGET_DIR="${1:-.}"

if [ ! -f "$TARGET_DIR/.config" ]; then
    echo "Error: .config file not found in $TARGET_DIR"
    exit 1
fi

echo "Checking Linux version..."
LINUX_VERSION=$(grep "CONFIG_LINUX_KCONFIG_VERSION" "$TARGET_DIR/.config" 2>/dev/null || echo "")

# Check if using Linux 6.12 or later
if grep -q "LINUX_6_12\|LINUX_6_13\|LINUX_7_" "$TARGET_DIR/.config" 2>/dev/null; then
    echo "Detected Linux 6.12 or later. Disabling kmod-nf-ipt to prevent conflicts..."
    
    # Remove conflicting iptables-based modules
    sed -i '/^CONFIG_PACKAGE_kmod-nf-ipt=/d' "$TARGET_DIR/.config"
    sed -i '/^CONFIG_PACKAGE_kmod-nf-ipt6=/d' "$TARGET_DIR/.config"
    sed -i '/^CONFIG_PACKAGE_kmod-ipt-core=/d' "$TARGET_DIR/.config"
    sed -i '/^CONFIG_PACKAGE_kmod-iptables=/d' "$TARGET_DIR/.config"
    sed -i '/^CONFIG_PACKAGE_kmod-ip6tables=/d' "$TARGET_DIR/.config"
    
    # Ensure nftables modules are enabled (for firewall4)
    if ! grep -q "CONFIG_PACKAGE_kmod-nft-core=" "$TARGET_DIR/.config"; then
        echo "CONFIG_PACKAGE_kmod-nft-core=y" >> "$TARGET_DIR/.config"
    fi
    
    if ! grep -q "CONFIG_PACKAGE_kmod-nft-nat=" "$TARGET_DIR/.config"; then
        echo "CONFIG_PACKAGE_kmod-nft-nat=y" >> "$TARGET_DIR/.config"
    fi
    
    if ! grep -q "CONFIG_PACKAGE_kmod-nft-fib=" "$TARGET_DIR/.config"; then
        echo "CONFIG_PACKAGE_kmod-nft-fib=y" >> "$TARGET_DIR/.config"
    fi
    
    echo "✓ Fixed: Disabled kmod-nf-ipt modules for Linux 6.12+"
    echo "✓ Ensured nftables modules are enabled for firewall4"
else
    echo "✓ Skipped: Not using Linux 6.12+, no fixes needed"
fi

exit 0