#!/bin/bash
#
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
# Supports both Official OpenWrt and LEDE
#
# Copyright (c) 2019-2024
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

set -e

TARGET_DIR="${TARGET_MATRIX:-.}"
echo "[DIY-P2] Starting DIY Part 2 for: $TARGET_DIR"

if [ ! -d "$TARGET_DIR" ]; then
    echo "[ERROR] Target directory not found: $TARGET_DIR"
    exit 1
fi

# ===== Fix kmod-nf-ipt conflicts for Linux 6.12+ =====
echo "[DIY-P2] Checking for kmod-nf-ipt fix..."
if [ -f "$GITHUB_WORKSPACE/fix-kmod-nf-ipt-linux612.sh" ]; then
    echo "[DIY-P2] Running firewall4/nftables fix script..."
    chmod +x "$GITHUB_WORKSPACE/fix-kmod-nf-ipt-linux612.sh"
    "$GITHUB_WORKSPACE/fix-kmod-nf-ipt-linux612.sh" || echo "[DIY-P2] Fix script completed with warnings"
fi

# ===== Clean duplicate packages from small feed =====
echo "[DIY-P2] Cleaning duplicate packages from small feed..."
rm -rf "$TARGET_DIR"/feeds/small/luci-app-passwall 2>/dev/null || true
rm -rf "$TARGET_DIR"/feeds/small/luci-app-passwall2 2>/dev/null || true
rm -rf "$TARGET_DIR"/feeds/small/mihomo 2>/dev/null || true
rm -rf "$TARGET_DIR"/feeds/small/luci-app-mihomo 2>/dev/null || true

# ===== Fix Rust LLVM issue (universal) =====
echo "[DIY-P2] Fixing Rust LLVM configuration..."
if [ -f "$TARGET_DIR/feeds/packages/lang/rust/Makefile" ]; then
    sed -i 's/--set=llvm.download-ci-llvm=true/--set=llvm.download-ci-llvm=false/g' "$TARGET_DIR/feeds/packages/lang/rust/Makefile" || true
fi

# ===== Modify default theme (universal) =====
echo "[DIY-P2] Updating default theme to argon..."
if [ -f "$TARGET_DIR/feeds/luci/collections/luci/Makefile" ]; then
    sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' "$TARGET_DIR/feeds/luci/collections/luci/Makefile" || true
elif [ -f "$TARGET_DIR/feeds/luci/Makefile" ]; then
    sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' "$TARGET_DIR/feeds/luci/Makefile" || true
fi

# ===== Customize banner and release info =====
echo "[DIY-P2] Customizing system banner..."
if [ -d "$TARGET_DIR/package/base-files/files/etc" ]; then
    if [ -f "diy/banner" ]; then
        cp -f diy/banner "$TARGET_DIR/package/base-files/files/etc/banner" || true
        sed -i "s/%D %V, %C/OpenWrt by ${AUTHORED_BY} $(date +'%Y-%m-%d')/g" "$TARGET_DIR/package/base-files/files/etc/banner" || true
    fi
fi

# ===== Get git commit ID =====
echo "[DIY-P2] Getting git commit ID..."
pushd "$TARGET_DIR" || exit
SHORT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
echo "[DIY-P2] Short commit ID: $SHORT_COMMIT"
popd || exit

# ===== Update OpenWrt release info =====
echo "[DIY-P2] Updating OpenWrt release info..."
if [ -f "$TARGET_DIR/package/base-files/files/etc/openwrt_release" ]; then
    sed -i "s/%D/${RELEASE_NAME}/g" "$TARGET_DIR/package/base-files/files/etc/openwrt_release" || true
    sed -i "s/%V/${DATE4}/g" "$TARGET_DIR/package/base-files/files/etc/openwrt_release" || true
    sed -i "s/%C/git-${SHORT_COMMIT}/g" "$TARGET_DIR/package/base-files/files/etc/openwrt_release" || true
    sed -i "s/Openwrt/${RELEASE_NAME}/g" "$TARGET_DIR/package/base-files/files/etc/openwrt_release" || true
fi

# ===== Update OS release info =====
echo "[DIY-P2] Updating OS release info..."
if [ -f "$TARGET_DIR/package/base-files/files/usr/lib/os-release" ]; then
    sed -i "s/%D/${RELEASE_NAME}/g" "$TARGET_DIR/package/base-files/files/usr/lib/os-release" || true
    sed -i "s/%V/${DATE4}/g" "$TARGET_DIR/package/base-files/files/usr/lib/os-release" || true
    sed -i "s/%C/git-${SHORT_COMMIT}/g" "$TARGET_DIR/package/base-files/files/usr/lib/os-release" || true
fi

# ===== Update mkversion for LuCI (target-specific) =====
echo "[DIY-P2] Updating LuCI version info..."
case "$TARGET_DIR" in
  "lede")
    echo "[DIY-P2] LEDE build detected - updating mkversion for LEDE..."
    if [ -f "$TARGET_DIR/package/feeds/luci/luci-lua-runtime/src/mkversion.sh" ]; then
        sed -i "s/\${2:-Git}/${SHORT_COMMIT}/g" "$TARGET_DIR/package/feeds/luci/luci-lua-runtime/src/mkversion.sh" || true
    fi
    ;;
  "official")
    echo "[DIY-P2] Official OpenWrt build detected - updating mkversion for official..."
    if [ -f "$TARGET_DIR/feeds/luci/feeds/luci/luci-lua-runtime/src/mkversion.sh" ]; then
        sed -i "s/\${2:-Git}/${SHORT_COMMIT}/g" "$TARGET_DIR/feeds/luci/feeds/luci/luci-lua-runtime/src/mkversion.sh" || true
    elif [ -f "$TARGET_DIR/feeds/base/feeds/luci/luci-lua-runtime/src/mkversion.sh" ]; then
        sed -i "s/\${2:-Git}/${SHORT_COMMIT}/g" "$TARGET_DIR/feeds/base/feeds/luci/luci-lua-runtime/src/mkversion.sh" || true
    fi
    ;;
esac

# ===== Customize network configuration =====
echo "[DIY-P2] Customizing network configuration..."
if [ -f "$TARGET_DIR/package/base-files/files/bin/config_generate" ]; then
    sed -i 's/192.168.1.1/172.16.3.18/g' "$TARGET_DIR/package/base-files/files/bin/config_generate" || true
    sed -i 's/255.255.255.0/255.255.248.0/g' "$TARGET_DIR/package/base-files/files/bin/config_generate" || true
    sed -i "s/OpenWrt/${AUTHORED_BY}/g" "$TARGET_DIR/package/base-files/files/bin/config_generate" || true
fi

# ===== Install network optimization script =====
echo "[DIY-P2] Installing network optimization script..."
if [ -f "diy/common/netopt.sh" ] && [ -d "$TARGET_DIR/package/base-files/files/etc/init.d" ]; then
    cp -f diy/common/netopt.sh "$TARGET_DIR/package/base-files/files/etc/init.d/netopt" || true
    chmod +x "$TARGET_DIR/package/base-files/files/etc/init.d/netopt" || true
    # Create rc.d symlink so netopt auto-starts on boot (START=99, after network)
    mkdir -p "$TARGET_DIR/package/base-files/files/etc/rc.d"
    ln -sf /etc/init.d/netopt "$TARGET_DIR/package/base-files/files/etc/rc.d/S99netopt" || true
    echo "[DIY-P2] netopt installed and enabled (S99netopt symlink created)"
fi

# ===== Install first-boot default settings =====
# zzz-default-settings runs last (alphabetical order in uci-defaults) to override
# any settings from OpenWrt/LEDE packages (timezone, flow offload, netopt enable, etc.)
echo "[DIY-P2] Installing zzz-default-settings..."
mkdir -p "$TARGET_DIR/package/base-files/files/etc/uci-defaults"
if [ -f "diy/common/zzz-default-settings" ]; then
    cp -f diy/common/zzz-default-settings \
        "$TARGET_DIR/package/base-files/files/etc/uci-defaults/zzz-default-settings" || true
    chmod +x "$TARGET_DIR/package/base-files/files/etc/uci-defaults/zzz-default-settings" || true
    echo "[DIY-P2] zzz-default-settings installed"
fi

# ===== Pre-download Clash Meta (mihomo) core =====
# Baking the core binary into the image means OpenClash works immediately after flash.
# core_version=linux-amd64-v1 (UCI) → use "compatible" build (broadest x86_64 support,
# works on CPUs without SSE4.2/AVX2 — covers 4th gen Intel and all modern AMD).
# OpenClash expects the binary at /etc/openclash/core/clash_meta (no version suffix).
echo "[DIY-P2] Pre-downloading Clash Meta (mihomo) core..."
CORE_DIR="$TARGET_DIR/package/base-files/files/etc/openclash/core"
mkdir -p "$CORE_DIR"

MIHOMO_VER=$(curl -fsSL \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" \
    | grep '"tag_name"' | head -1 | cut -d'"' -f4)

if [ -n "$MIHOMO_VER" ]; then
    echo "[DIY-P2] Latest mihomo version: ${MIHOMO_VER}"
    MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VER}/mihomo-linux-amd64-compatible-${MIHOMO_VER}.gz"
    if curl -fsSL -o "/tmp/clash_meta.gz" "$MIHOMO_URL"; then
        gzip -d "/tmp/clash_meta.gz" \
            && mv "/tmp/clash_meta" "$CORE_DIR/clash_meta" \
            && chmod +x "$CORE_DIR/clash_meta" \
            && echo "[DIY-P2] Clash Meta core ${MIHOMO_VER} (compatible/amd64-v1) installed" \
            || echo "[WARNING] Failed to extract clash_meta"
    else
        echo "[WARNING] Failed to download: $MIHOMO_URL"
        # Fallback: try standard amd64 build
        MIHOMO_URL_FB="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VER}/mihomo-linux-amd64-${MIHOMO_VER}.gz"
        if curl -fsSL -o "/tmp/clash_meta.gz" "$MIHOMO_URL_FB"; then
            gzip -d "/tmp/clash_meta.gz" \
                && mv "/tmp/clash_meta" "$CORE_DIR/clash_meta" \
                && chmod +x "$CORE_DIR/clash_meta" \
                && echo "[DIY-P2] Clash Meta core ${MIHOMO_VER} (standard amd64) installed (fallback)" \
                || echo "[WARNING] Failed to extract clash_meta (fallback)"
        else
            echo "[WARNING] Both downloads failed — core will be downloaded on first run by OpenClash"
        fi
    fi
else
    echo "[WARNING] Could not determine latest mihomo version — core will be downloaded by OpenClash at runtime"
fi

echo "[DIY-P2] DIY Part 2 completed successfully"