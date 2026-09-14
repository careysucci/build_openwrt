#!/bin/bash
#
# File name: diy/cr8806/diy-ap.sh
# Description: Build-time customization for the CR8806 ImmortalWrt AP build
#
# Standalone script — the shared diy-part1.sh / diy-part2.sh are NOT
# touched, so LEDE and official builds keep working exactly as before.
#
# What it does:
#   1. Brand the banner / openwrt_release / os-release
#   2. Install 99-ap-bridge (first-boot bridged-AP provisioning)
#   3. Install netopt.sh (boot-time tuning: CPU governor, GRO, bridge-nf)
#
# Requires env: TARGET_MATRIX, AUTHORED_BY, RELEASE_NAME, DATE4
# (all provided by the workflow env + 'Get current date' step)
#

set -e

TARGET_DIR="${TARGET_MATRIX:-.}"
echo "[DIY-AP] Starting AP customization for: $TARGET_DIR"

if [ ! -d "$TARGET_DIR" ]; then
    echo "[ERROR] Target directory not found: $TARGET_DIR"
    exit 1
fi

# ===== Git commit ID (for release branding) =====
SHORT_COMMIT=$(git -C "$TARGET_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
echo "[DIY-AP] Source commit: $SHORT_COMMIT"

# ===== Customize banner =====
if [ -f "diy/banner" ] && [ -d "$TARGET_DIR/package/base-files/files/etc" ]; then
    cp -f diy/banner "$TARGET_DIR/package/base-files/files/etc/banner"
    sed -i "s/%D %V, %C/OpenWrt AP by ${AUTHORED_BY} $(date +'%Y-%m-%d')/g" \
        "$TARGET_DIR/package/base-files/files/etc/banner" || true
    echo "[DIY-AP] banner installed"
fi

# ===== Brand openwrt_release =====
if [ -f "$TARGET_DIR/package/base-files/files/etc/openwrt_release" ]; then
    sed -i "s/%D/${RELEASE_NAME}/g" "$TARGET_DIR/package/base-files/files/etc/openwrt_release" || true
    sed -i "s/%V/${DATE4}/g" "$TARGET_DIR/package/base-files/files/etc/openwrt_release" || true
    sed -i "s/%C/git-${SHORT_COMMIT}/g" "$TARGET_DIR/package/base-files/files/etc/openwrt_release" || true
    sed -i "s/Openwrt/${RELEASE_NAME}/g" "$TARGET_DIR/package/base-files/files/etc/openwrt_release" || true
    echo "[DIY-AP] openwrt_release branded: ${RELEASE_NAME} ${DATE4} git-${SHORT_COMMIT}"
fi

# ===== Brand os-release =====
if [ -f "$TARGET_DIR/package/base-files/files/usr/lib/os-release" ]; then
    sed -i "s/%D/${RELEASE_NAME}/g" "$TARGET_DIR/package/base-files/files/usr/lib/os-release" || true
    sed -i "s/%V/${DATE4}/g" "$TARGET_DIR/package/base-files/files/usr/lib/os-release" || true
    sed -i "s/%C/git-${SHORT_COMMIT}/g" "$TARGET_DIR/package/base-files/files/usr/lib/os-release" || true
fi

# ===== Install first-boot AP provisioning =====
mkdir -p "$TARGET_DIR/package/base-files/files/etc/uci-defaults"
if [ -f "diy/cr8806/99-ap-bridge" ]; then
    cp -f diy/cr8806/99-ap-bridge \
        "$TARGET_DIR/package/base-files/files/etc/uci-defaults/99-ap-bridge"
    chmod +x "$TARGET_DIR/package/base-files/files/etc/uci-defaults/99-ap-bridge"
    echo "[DIY-AP] 99-ap-bridge installed (bridged AP + WiFi roaming at first boot)"
else
    echo "[ERROR] diy/cr8806/99-ap-bridge not found"
    exit 1
fi

# ===== Install network optimization (boot-time, exits after tuning) =====
# Benefits for an AP: CPU governor=performance, GRO on ethernet ports,
# bridge-nf-call disabled (bridged frames skip netfilter → less CPU).
if [ -f "diy/common/netopt.sh" ] && [ -d "$TARGET_DIR/package/base-files/files/etc/init.d" ]; then
    cp -f diy/common/netopt.sh "$TARGET_DIR/package/base-files/files/etc/init.d/netopt"
    chmod +x "$TARGET_DIR/package/base-files/files/etc/init.d/netopt"
    mkdir -p "$TARGET_DIR/package/base-files/files/etc/rc.d"
    ln -sf /etc/init.d/netopt "$TARGET_DIR/package/base-files/files/etc/rc.d/S99netopt"
    echo "[DIY-AP] netopt installed and enabled (S99netopt)"
fi

echo "[DIY-AP] AP customization completed"
