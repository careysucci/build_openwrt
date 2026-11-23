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

# ===== Add matching dae backend and LuCI app (official only) =====
# This must run after the first feeds update: creating feeds/packages before
# its git clone would make the update fail. The final feeds update preserves
# these package directories as untracked files in their respective feeds.
import_sparse_package() {
    local repo_url="$1"
    local branch="$2"
    local source_path="$3"
    local destination="$4"
    local temp_dir

    temp_dir=$(mktemp -d)
    git clone --depth 1 --filter=blob:none --sparse -b "$branch" "$repo_url" "$temp_dir"
    git -C "$temp_dir" sparse-checkout set "$source_path"
    mkdir -p "$(dirname "$destination")"
    rm -rf "$destination"
    cp -a "$temp_dir/$source_path" "$destination"
    rm -rf "$temp_dir"
}

if [ "$TARGET_DIR" = "official" ]; then
    echo "[DIY-P2] Adding matching dae backend and LuCI app..."
    DAE_FEED_BRANCH="${REPO_BRANCH:-openwrt-25.12}"
    import_sparse_package "https://github.com/immortalwrt/packages.git" "$DAE_FEED_BRANCH" \
        "net/dae" "$TARGET_DIR/feeds/packages/net/dae"
    import_sparse_package "https://github.com/immortalwrt/luci.git" "$DAE_FEED_BRANCH" \
        "applications/luci-app-dae" "$TARGET_DIR/feeds/luci/applications/luci-app-dae"
fi

# ===== Install the Wy.House dae configuration into the package =====
# Keep upstream example.dae as a reference and install our file separately.
# /etc/dae/config.dae is already a package conffile, so sysupgrade preserves
# the user's subscription and later LuCI edits.
# Only builds that actually ship dae need this section. Official imports the
# package above, so a missing Makefile there stays a hard error; other targets
# without dae skip everything instead of failing on an irrelevant check.
DAE_PKG_DIR="$TARGET_DIR/feeds/packages/net/dae"
DAE_MAKEFILE="$DAE_PKG_DIR/Makefile"
DAE_CONFIG_SRC="${GITHUB_WORKSPACE:-$PWD}/dae-config.dae"
if [ ! -f "$DAE_MAKEFILE" ] && [ "$TARGET_DIR" != "official" ]; then
    echo "[DIY-P2] dae package not present, skipping dae configuration"
else
echo "[DIY-P2] Installing the default dae configuration..."
if [ ! -f "$DAE_MAKEFILE" ] || [ ! -f "$DAE_CONFIG_SRC" ]; then
    echo "[ERROR] dae package Makefile or dae-config.dae is missing"
    exit 1
fi
mkdir -p "$DAE_PKG_DIR/files"
cp -f "$DAE_CONFIG_SRC" "$DAE_PKG_DIR/files/config.dae"

DAE_EXAMPLE_INSTALL='$(INSTALL_CONF) $(PKG_BUILD_DIR)/example.dae $(1)/etc/dae/'
DAE_CUSTOM_INSTALL='$(INSTALL_CONF) $(CURDIR)/files/config.dae $(1)/etc/dae/config.dae'
if ! grep -Fq "$DAE_CUSTOM_INSTALL" "$DAE_MAKEFILE"; then
    if ! grep -Fq "$DAE_EXAMPLE_INSTALL" "$DAE_MAKEFILE"; then
        echo "[ERROR] Unsupported dae Makefile: example.dae install rule not found"
        exit 1
    fi
    awk -v example_line="$DAE_EXAMPLE_INSTALL" '
        index($0, example_line) {
            print
            print "\t$(INSTALL_CONF) $(CURDIR)/files/config.dae $(1)/etc/dae/config.dae"
            next
        }
        { print }
    ' "$DAE_MAKEFILE" > "$DAE_MAKEFILE.dae.tmp"
    mv "$DAE_MAKEFILE.dae.tmp" "$DAE_MAKEFILE"
fi
grep -Fq "$DAE_CUSTOM_INSTALL" "$DAE_MAKEFILE" || {
    echo "[ERROR] Failed to add the dae config.dae install rule"
    exit 1
}
# The matched package's /etc/config/dae already has enabled=0 and points to
# /etc/dae/config.dae. Do not reset that UCI file on every sysupgrade.

# dae requires Linux 5.17 or newer. Reject unsupported branches explicitly
# instead of shipping an eBPF service that cannot load (for example, the
# Linux 5.15 kernel in official 23.05).
DAE_KERNEL_PATCHVER=$(sed -n 's/^KERNEL_PATCHVER:=//p' "$TARGET_DIR/target/linux/x86/Makefile" | head -n 1)
DAE_KERNEL_MAJOR="${DAE_KERNEL_PATCHVER%%.*}"
DAE_KERNEL_MINOR="${DAE_KERNEL_PATCHVER#*.}"
case "$DAE_KERNEL_MAJOR:$DAE_KERNEL_MINOR" in
    *[!0-9:]*|'':*|*:'')
        echo "[ERROR] Cannot parse the x86 kernel version for dae: $DAE_KERNEL_PATCHVER"
        exit 1
        ;;
esac
if [ "$DAE_KERNEL_MAJOR" -lt 5 ] || { [ "$DAE_KERNEL_MAJOR" -eq 5 ] && [ "$DAE_KERNEL_MINOR" -lt 17 ]; }; then
    echo "[ERROR] dae requires Linux >= 5.17; $TARGET_DIR uses $DAE_KERNEL_PATCHVER"
    exit 1
fi

# official 25.12 has no high-level KERNEL_BPF_STREAM_PARSER symbol. Add the
# actual Linux option to the selected x86 target config instead of writing an
# invalid CONFIG_KERNEL_* key that make defconfig would silently discard.
if [ "$TARGET_DIR" = "official" ]; then
    DAE_KERNEL_CONFIG="$TARGET_DIR/target/linux/x86/config-${DAE_KERNEL_PATCHVER}"
    if [ ! -f "$DAE_KERNEL_CONFIG" ]; then
        echo "[ERROR] Cannot locate the official x86 kernel config for dae"
        exit 1
    fi
    if ! grep -q '^CONFIG_BPF_STREAM_PARSER=y$' "$DAE_KERNEL_CONFIG"; then
        if grep -q '^# CONFIG_BPF_STREAM_PARSER is not set$' "$DAE_KERNEL_CONFIG"; then
            sed -i 's/^# CONFIG_BPF_STREAM_PARSER is not set$/CONFIG_BPF_STREAM_PARSER=y/' "$DAE_KERNEL_CONFIG"
        else
            printf '\nCONFIG_BPF_STREAM_PARSER=y\n' >> "$DAE_KERNEL_CONFIG"
        fi
    fi
fi
fi  # end of the dae package-presence gate

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

# ===== Add subscription-driven HomeProxy bootstrap =====
# The stock updater removes stale URLTest nodes but never populates an empty
# URLTest group. Patch it before the final feeds update so a user only needs to
# supply a subscription URL; fail the build if this security-sensitive patch
# no longer matches the selected small feed.
HP_PKG_DIR="$TARGET_DIR/feeds/small/luci-app-homeproxy"
HP_UPDATER="$HP_PKG_DIR/root/etc/homeproxy/scripts/update_subscriptions.uc"
HP_GENERATOR="$HP_PKG_DIR/root/etc/homeproxy/scripts/generate_client.uc"
HP_URLTEST_PATCH="${GITHUB_WORKSPACE:-$PWD}/diy/patches/homeproxy-subscription-bootstrap.patch"
HP_DNS_PATCH="${GITHUB_WORKSPACE:-$PWD}/diy/patches/homeproxy-dns-bootstrap.patch"
HP_DNS_FINAL_PATCH="${GITHUB_WORKSPACE:-$PWD}/diy/patches/homeproxy-dns-final.patch"
HP_DNS_FAILCLOSED_PATCH="${GITHUB_WORKSPACE:-$PWD}/diy/patches/homeproxy-dns-failclosed.patch"
HP_URLTEST_MARKER='Wy.House: opt-in subscription bootstrap.'
HP_DNS_MARKER='Wy.House: encrypted bootstrap DNS.'
HP_DNS_FINAL_MARKER='Wy.House: main DNS is the final resolver.'
HP_DNS_FAILCLOSED_MARKER='Wy.House: fail closed on main DNS errors.'
# Builds without luci-app-homeproxy skip these patches entirely. When the
# package is present every check below stays fatal: these security-sensitive
# DNS/subscription patches must never be silently skipped.
if [ ! -d "$HP_PKG_DIR" ]; then
    echo "[DIY-P2] luci-app-homeproxy not present, skipping HomeProxy patches"
elif [ ! -f "$HP_UPDATER" ] || [ ! -f "$HP_GENERATOR" ] || \
   [ ! -f "$HP_URLTEST_PATCH" ] || [ ! -f "$HP_DNS_PATCH" ] || \
   [ ! -f "$HP_DNS_FINAL_PATCH" ] || [ ! -f "$HP_DNS_FAILCLOSED_PATCH" ]; then
    echo "[ERROR] HomeProxy scripts or bootstrap patches are missing"
    exit 1
fi

apply_homeproxy_patch() {
    local target_file="$1" patch_file="$2" marker="$3" label="$4"
    if grep -Fq "$marker" "$target_file"; then
        return 0
    fi
    echo "[DIY-P2] Applying HomeProxy $label patch..."
    patch --dry-run -d "$HP_PKG_DIR" -p1 < "$patch_file"
    patch -d "$HP_PKG_DIR" -p1 < "$patch_file"
    grep -Fq "$marker" "$target_file" || {
        echo "[ERROR] Failed to apply the HomeProxy $label patch"
        exit 1
    }
}
# Independent transactions also recover correctly from a half-applied tree.
if [ -d "$HP_PKG_DIR" ]; then
    apply_homeproxy_patch "$HP_UPDATER" "$HP_URLTEST_PATCH" "$HP_URLTEST_MARKER" "subscription bootstrap"
    apply_homeproxy_patch "$HP_GENERATOR" "$HP_DNS_PATCH" "$HP_DNS_MARKER" "encrypted bootstrap DNS"
    apply_homeproxy_patch "$HP_GENERATOR" "$HP_DNS_FINAL_PATCH" "$HP_DNS_FINAL_MARKER" "final DNS"
    apply_homeproxy_patch "$HP_GENERATOR" "$HP_DNS_FAILCLOSED_PATCH" "$HP_DNS_FAILCLOSED_MARKER" "fail-closed DNS"
fi

# ===== Fix luci-app-netspeedtest stale dependency (LEDE only) =====
# sirpdboy/netspeedtest still declares +python3-pkg-resources, which no longer
# exists in the packages feed (setuptools dropped pkg_resources). The ipk then
# fails rootfs install (package/install Error 255). Drop the dead dep.
# Runs before the final 'feeds update' (git pull --ff-only), which preserves
# this working-tree edit as long as upstream leaves the Makefile untouched.
if [ "$TARGET_DIR" = "lede" ]; then
    NETSPEEDTEST_MK="$TARGET_DIR/feeds/netspeedtest/luci-app-netspeedtest/Makefile"
    if [ ! -f "$NETSPEEDTEST_MK" ]; then
        echo "[DIY-P2] netspeedtest feed not present, skipping"
    elif ! grep -q '+python3-pkg-resources' "$NETSPEEDTEST_MK"; then
        echo "[DIY-P2] netspeedtest dependency already clean upstream, nothing to do"
    else
        echo "[DIY-P2] Fixing luci-app-netspeedtest stale python3-pkg-resources dependency..."
        sed -i 's/ +python3-pkg-resources//g' "$NETSPEEDTEST_MK"
        if grep -q '+python3-pkg-resources' "$NETSPEEDTEST_MK"; then
            echo "[ERROR] Failed to remove python3-pkg-resources from luci-app-netspeedtest"
            exit 1
        fi
        echo "[DIY-P2] netspeedtest dependency fix applied"
    fi
fi

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

# ===== Customize banner (selectable per build) =====
# BANNER_FILE (workflow dispatch input, default per build family) picks
# the diy/banner* file that ships:
#   banner             - static text -> /etc/banner (legacy path)
#   banner-wyhousewrt  - executable script -> /etc/profile.d/
#                        99-wyhouse-banner.sh: /etc/profile sources it
#                        on each interactive login with stdout kept on
#                        the terminal (true on official main/25.12, Lean
#                        and ImmortalWrt), so it reports live data;
#                        /etc/banner is emptied to avoid a second logo.
BANNER_FILE="${BANNER_FILE:-banner-wyhousewrt}"
if [ -d "$TARGET_DIR/package/base-files/files/etc" ]; then
    if [ -f "diy/${BANNER_FILE}" ]; then
        if [ "${BANNER_FILE}" = "banner-wyhousewrt" ]; then
            mkdir -p "$TARGET_DIR/package/base-files/files/etc/profile.d"
            sed -e "s#__AUTHORED_BY__#${AUTHORED_BY:-Wy.House}#g" \
                -e "s#__BUILD_DATE__#$(date +'%Y-%m-%d')#g" \
                "diy/${BANNER_FILE}" \
                > "$TARGET_DIR/package/base-files/files/etc/profile.d/99-wyhouse-banner.sh" || true
            chmod +x "$TARGET_DIR/package/base-files/files/etc/profile.d/99-wyhouse-banner.sh" || true
            : > "$TARGET_DIR/package/base-files/files/etc/banner" || true
            echo "[DIY-P2] dynamic banner installed (etc/profile.d/99-wyhouse-banner.sh)"
        else
            cp -f "diy/${BANNER_FILE}" "$TARGET_DIR/package/base-files/files/etc/banner" || true
            sed -i "s/%D %V, %C/OpenWrt by ${AUTHORED_BY} $(date +'%Y-%m-%d')/g" "$TARGET_DIR/package/base-files/files/etc/banner" || true
            echo "[DIY-P2] static banner installed (diy/${BANNER_FILE} -> /etc/banner)"
        fi
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

# ===== Install first-boot modules =====
# Modules are sourced by zzz-default-settings at first boot.
# Install path: /usr/lib/wyhome/modules/ (inside firmware image).
echo "[DIY-P2] Installing first-boot modules..."
MODULES_SRC="$GITHUB_WORKSPACE/diy/modules"
MODULES_DST="$TARGET_DIR/package/base-files/files/usr/lib/wyhome/modules"
mkdir -p "$MODULES_DST"
if [ -d "$MODULES_SRC" ]; then
    for _mod in "$MODULES_SRC"/[0-9][0-9]-*.sh; do
        [ -f "$_mod" ] || continue
        cp -f "$_mod" "$MODULES_DST/" || true
        chmod +x "$MODULES_DST/$(basename $_mod)" || true
        echo "[DIY-P2] module installed: $(basename $_mod)"
    done
else
    echo "[WARNING] diy/modules/ not found, skipping module installation"
fi

# ===== Install first-boot default settings (orchestrator) =====
# zzz-default-settings runs last (alphabetical in uci-defaults) and
# sources all modules from /usr/lib/wyhome/modules/.
echo "[DIY-P2] Installing zzz-default-settings..."
mkdir -p "$TARGET_DIR/package/base-files/files/etc/uci-defaults"
if [ -f "diy/common/zzz-default-settings" ]; then
    cp -f diy/common/zzz-default-settings \
        "$TARGET_DIR/package/base-files/files/etc/uci-defaults/zzz-default-settings" || true
    chmod +x "$TARGET_DIR/package/base-files/files/etc/uci-defaults/zzz-default-settings" || true
    echo "[DIY-P2] zzz-default-settings installed"
fi

# ===== LEDE-only: install default-settings =====
# diy/common/default-settings contains LEDE-specific settings not covered by modules:
#   root password hash, NAS menu moves, dnsmasq log suppression,
#   wget hardening, LEDE opkg mirror, luci-modulecache cleanup.
# Installed as 'default-settings' (runs before zzz-default-settings alphabetically).
# Overrides kenzok's luci-app-default-settings package version if present.
if [ "$TARGET_DIR" = "lede" ] && [ -f "diy/common/default-settings" ]; then
    cp -f diy/common/default-settings \
        "$TARGET_DIR/package/base-files/files/etc/uci-defaults/default-settings" || true
    chmod +x "$TARGET_DIR/package/base-files/files/etc/uci-defaults/default-settings" || true
    echo "[DIY-P2] default-settings (LEDE) installed"
fi

# ===== OpenClash: install config + download core =====
# Delegates to diy/scripts/build-openclash.sh (build-time only, not in image).
echo "[DIY-P2] Running OpenClash build script..."
if [ -f "$GITHUB_WORKSPACE/diy/scripts/build-openclash.sh" ]; then
    # shellcheck source=diy/scripts/build-openclash.sh
    source "$GITHUB_WORKSPACE/diy/scripts/build-openclash.sh" || true
else
    echo "[WARNING] diy/scripts/build-openclash.sh not found, skipping"
fi

echo "[DIY-P2] DIY Part 2 completed successfully"