#!/bin/bash
#
# File name: fix-kmod-nf-ipt-linux612.sh
# Description: Fix kmod-nf-ipt conflicts for Linux 6.12+
#
# Supports both Official OpenWrt and LEDE (Lean's) OpenWrt
# Detects kernel version from OpenWrt source, not .config
#

set -e

TARGET_DIR="${TARGET_MATRIX:-.}"
CONFIG_FILE="$GITHUB_WORKSPACE/${CONFIG_FILE}"
OPENWRT_DIR="$GITHUB_WORKSPACE/$TARGET_DIR"

echo "[INFO] Fixing kernel configuration for firewall4 (nftables)..."
echo "[INFO] Target: $TARGET_DIR (official or lede)"

# Check if .config exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] Config file not found: $CONFIG_FILE"
    exit 1
fi

# ===== UNIVERSAL KERNEL VERSION DETECTION =====
# Works for both Official OpenWrt and LEDE
KERNEL_VERSION=""

# Method 1: include/kernel-version.mk (both official and LEDE)
if [ -f "$OPENWRT_DIR/include/kernel-version.mk" ]; then
    KERNEL_VERSION=$(grep "KERNEL_VERSION" "$OPENWRT_DIR/include/kernel-version.mk" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1)
    if [ -n "$KERNEL_VERSION" ]; then
        echo "[INFO] Kernel from kernel-version.mk: $KERNEL_VERSION"
    fi
fi

# Method 2: target/linux/generic/Makefile.defaults (official)
if [ -z "$KERNEL_VERSION" ] && [ -f "$OPENWRT_DIR/target/linux/generic/Makefile.defaults" ]; then
    KERNEL_VERSION=$(grep -i "KERNEL_VERSION" "$OPENWRT_DIR/target/linux/generic/Makefile.defaults" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1)
    if [ -n "$KERNEL_VERSION" ]; then
        echo "[INFO] Kernel from Makefile.defaults: $KERNEL_VERSION"
    fi
fi

# Method 3: target/linux/x86/Makefile (x86 specific)
if [ -z "$KERNEL_VERSION" ] && [ -f "$OPENWRT_DIR/target/linux/x86/Makefile" ]; then
    KERNEL_VERSION=$(grep "KERNEL" "$OPENWRT_DIR/target/linux/x86/Makefile" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1)
    if [ -n "$KERNEL_VERSION" ]; then
        echo "[INFO] Kernel from x86/Makefile: $KERNEL_VERSION"
    fi
fi

# Method 4: Fallback - check .config after defconfig
if [ -z "$KERNEL_VERSION" ] && [ -f "$CONFIG_FILE" ]; then
    # Check for CONFIG_LINUX_KERNEL_VERSION (official)
    KERNEL_VERSION=$(grep "CONFIG_LINUX_KERNEL_VERSION" "$CONFIG_FILE" | cut -d'=' -f2 | tr -d '"' 2>/dev/null || echo "")
    if [ -n "$KERNEL_VERSION" ]; then
        echo "[INFO] Kernel from .config (CONFIG_LINUX_KERNEL_VERSION): $KERNEL_VERSION"
    fi

    # Check for comment format (both official and LEDE)
    if [ -z "$KERNEL_VERSION" ]; then
        KERNEL_VERSION=$(grep "^# Linux" "$CONFIG_FILE" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1)
        if [ -n "$KERNEL_VERSION" ]; then
            echo "[INFO] Kernel from .config comment: $KERNEL_VERSION"
        fi
    fi
fi

# Method 5: Check build directory (last resort, after initial make)
if [ -z "$KERNEL_VERSION" ] && [ -d "$OPENWRT_DIR/build_dir" ]; then
    echo "[INFO] Checking build directory for kernel version..."
    KERNEL_VERSION=$(find "$OPENWRT_DIR/build_dir" -type d -name "linux-*" 2>/dev/null | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1)
    if [ -n "$KERNEL_VERSION" ]; then
        echo "[INFO] Found kernel in build_dir: $KERNEL_VERSION"
    fi
fi

echo "[INFO] Final detected kernel version: ${KERNEL_VERSION:-unknown}"

# ===== CONFIGURATION LOGIC =====
if [ -n "$KERNEL_VERSION" ]; then
    MAJOR=$(echo "$KERNEL_VERSION" | cut -d'.' -f1)
    MINOR=$(echo "$KERNEL_VERSION" | cut -d'.' -f2)

    if [ "$MAJOR" -gt 6 ] || ([ "$MAJOR" -eq 6 ] && [ "$MINOR" -ge 12 ]); then
        echo "[ACTION] Linux ${MAJOR}.${MINOR} detected (>= 6.12) - Configuring for firewall4..."

        # Remove any conflicting iptables configs
        echo "[ACTION] Cleaning iptables package configurations..."
        sed -i '/CONFIG_PACKAGE_kmod-nf-ipt=/d' "$CONFIG_FILE" 2>/dev/null || true
        sed -i '/CONFIG_PACKAGE_kmod-nf-ipt6=/d' "$CONFIG_FILE" 2>/dev/null || true
        sed -i '/CONFIG_PACKAGE_kmod-ipt-core=/d' "$CONFIG_FILE" 2>/dev/null || true
        sed -i '/CONFIG_PACKAGE_kmod-iptables=/d' "$CONFIG_FILE" 2>/dev/null || true
        sed -i '/CONFIG_PACKAGE_kmod-ip6tables=/d' "$CONFIG_FILE" 2>/dev/null || true

        # Remove kernel-level iptables configs if present
        echo "[ACTION] Cleaning kernel-level iptables configurations..."
        sed -i '/CONFIG_IP_NF_IPTABLES=/d' "$CONFIG_FILE" 2>/dev/null || true
        sed -i '/CONFIG_IP_NF_FILTER=/d' "$CONFIG_FILE" 2>/dev/null || true
        sed -i '/CONFIG_IP_NF_MANGLE=/d' "$CONFIG_FILE" 2>/dev/null || true
        sed -i '/CONFIG_IP_NF_TARGET_REJECT=/d' "$CONFIG_FILE" 2>/dev/null || true
        sed -i '/CONFIG_IP_NF_NAT=/d' "$CONFIG_FILE" 2>/dev/null || true
        sed -i '/CONFIG_IP6_NF_IPTABLES=/d' "$CONFIG_FILE" 2>/dev/null || true
        sed -i '/CONFIG_IP6_NF_FILTER=/d' "$CONFIG_FILE" 2>/dev/null || true
        sed -i '/CONFIG_IP6_NF_MANGLE=/d' "$CONFIG_FILE" 2>/dev/null || true

        # Append firewall4 (nftables) configurations
        echo "[ACTION] Adding firewall4 (nftables) configurations..."
        cat >> "$CONFIG_FILE" << 'FIREWALL_CONFIG'

# ===== Linux 6.12+ Firewall4 (nftables) Configuration =====
# Disable iptables at kernel compilation level
CONFIG_IP_NF_IPTABLES=n
CONFIG_IP_NF_FILTER=n
CONFIG_IP_NF_MANGLE=n
CONFIG_IP_NF_TARGET_REJECT=n
CONFIG_IP_NF_TARGET_REJECT_SNAT=n
CONFIG_IP_NF_NAT=n
CONFIG_IP_NF_TARGET_MASQUERADE=n
CONFIG_IP6_NF_IPTABLES=n
CONFIG_IP6_NF_FILTER=n
CONFIG_IP6_NF_MANGLE=n

# Enable nftables modules
CONFIG_NF_TABLES=y
CONFIG_NF_TABLES_NETDEV=y
CONFIG_NF_TABLES_INET=y
CONFIG_NF_TABLES_IPV4=y
CONFIG_NF_TABLES_IPV6=y

FIREWALL_CONFIG

        echo "[SUCCESS] Configured for Linux ${MAJOR}.${MINOR} with firewall4 (nftables)"
        echo "[INFO] ✓ iptables disabled at kernel level"
        echo "[INFO] ✓ nftables enabled for firewall4"
    else
        echo "[INFO] Linux ${MAJOR}.${MINOR} detected (< 6.12) - No changes needed"
        echo "[INFO] LEDE typically uses older kernels - skipping firewall4 optimization"
    fi
else
    echo "[WARNING] Could not detect kernel version"
    echo "[INFO] Applying default firewall4 (nftables) configuration as fallback..."

    # Remove old configs if present
    sed -i '/CONFIG_IP_NF_IPTABLES=/d' "$CONFIG_FILE" 2>/dev/null || true
    sed -i '/CONFIG_IP6_NF_IPTABLES=/d' "$CONFIG_FILE" 2>/dev/null || true

    # Apply firewall4 as default
    cat >> "$CONFIG_FILE" << 'FIREWALL_CONFIG'

# ===== Default firewall4 (nftables) configuration =====
# Applied when kernel version cannot be detected
CONFIG_IP_NF_IPTABLES=n
CONFIG_IP6_NF_IPTABLES=n
CONFIG_NF_TABLES=y
CONFIG_NF_TABLES_NETDEV=y
CONFIG_NF_TABLES_INET=y

FIREWALL_CONFIG

    echo "[INFO] Default firewall4 config applied"
fi

echo "[INFO] Kernel configuration fix complete"