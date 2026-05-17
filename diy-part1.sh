#!/bin/bash
#
# File name: diy-part1.sh
# Description: OpenWrt DIY script part 1 (Before Update feeds)
# Supports both Official OpenWrt and LEDE
#
# Copyright (c) 2019-2024
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

set -e

TARGET_DIR="${TARGET_MATRIX:-.}"
echo "[DIY-P1] Starting DIY Part 1 for: $TARGET_DIR"

# enter openwrt folder
if [ ! -d "$TARGET_DIR" ]; then
    echo "[ERROR] Target directory not found: $TARGET_DIR"
    exit 1
fi

pushd "$TARGET_DIR" || exit
echo "[DIY-P1] Entering OpenWrt folder: $TARGET_DIR"

# ===== Remove conflicting plugins (both official and LEDE) =====
echo "[DIY-P1] Cleaning conflicting plugins..."
rm -rf feeds/packages/luci/{*passwall*,*bypass*,*homeproxy*,*mihomo*,*openclash*} 2>/dev/null || true

# ===== Handle theme (LEDE-specific path) =====
if [ -d "package/lean" ]; then
    echo "[DIY-P1] LEDE detected - cleaning lean-specific theme..."
    rm -rf package/lean/luci-theme-argon
    rm -rf package/lean/luci-app-argon-config
fi

# ===== Add homeproxy feed (both official and LEDE) =====
echo "[DIY-P1] Adding homeproxy feed..."
HOMEPROXY_PATH="feeds/luci/applications/luci-app-homeproxy"

# Check if already exists and is a valid git repo
if [ -d "$HOMEPROXY_PATH/.git" ]; then
    echo "[DIY-P1] homeproxy already exists - updating..."
    cd "$HOMEPROXY_PATH" || exit
    if git pull origin master 2>/dev/null; then
        echo "[DIY-P1] homeproxy updated successfully"
    else
        echo "[WARNING] Failed to update homeproxy - existing version may be stale"
    fi
    cd - || exit
elif [ -d "$HOMEPROXY_PATH" ]; then
    echo "[DIY-P1] homeproxy directory exists but is not a git repo - removing and cloning fresh..."
    rm -rf "$HOMEPROXY_PATH"
    if git clone -b master https://github.com/immortalwrt/homeproxy.git "$HOMEPROXY_PATH" 2>&1; then
        echo "[DIY-P1] homeproxy cloned successfully"
    else
        echo "[ERROR] Failed to clone homeproxy - check network connection or repository availability"
        exit 1
    fi
else
    echo "[DIY-P1] Cloning homeproxy fresh..."
    mkdir -p "$(dirname "$HOMEPROXY_PATH")"
    if git clone -b master https://github.com/immortalwrt/homeproxy.git "$HOMEPROXY_PATH" 2>&1; then
        echo "[DIY-P1] homeproxy cloned successfully"
    else
        echo "[ERROR] Failed to clone homeproxy - check network connection or repository availability"
        exit 1
    fi
fi

# ===== Clean a feed source =====
echo "[DIY-P1] Cleaning helloworld feed source..."
sed -i "/helloworld/d" "feeds.conf.default" 2>/dev/null || true

# ===== Add feed sources (universal for both) =====
echo "[DIY-P1] Adding custom feed sources..."
{
  echo "src-git kenzo https://github.com/kenzok8/openwrt-packages"
  echo "src-git small https://github.com/kenzok8/small"
  echo "src-git netspeedtest https://github.com/sirpdboy/netspeedtest"
  echo "src-git diskman https://github.com/careysucci/luci-app-diskman"
  echo "src-git OpenClash https://github.com/vernesong/OpenClash"
  echo "src-git sbwml https://github.com/sbwml/openwrt_pkgs.git;main"
} >> "feeds.conf.default"

echo "[DIY-P1] Feed sources added successfully"

# back to root folder
popd || exit
echo "[DIY-P1] DIY Part 1 completed successfully"
