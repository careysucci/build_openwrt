#!/bin/bash
#
# File name: diy/cr8806/diy-nss.sh
# Description: Build-time customization for the CR8806 NSS router build
#              (kuncy7/openwrt-nss-edma, branch c3po-tag-8021q, kernel 6.18)
#
# NSS-tree variant of diy-ap.sh. The shared diy-part1.sh / diy-part2.sh
# and the 25.12 diy-ap.sh are NOT touched, so the LEDE, official and
# ImmortalWrt builds keep working exactly as before.
#
# Differences from diy-ap.sh:
#   1. Installs 99-ap-bridge-nss instead of 99-ap-bridge — the NSS
#      variant does NOT set network.globals.packet_steering=1 (the NSS
#      tree's own 98-nss-offload sets steering and flow-offloading to
#      the values measured on the NSS data path, and uci-defaults
#      filename order would let a 99-* script override it; see the
#      header of 99-ap-bridge-nss).
#   2. Does NOT install netopt.sh. The generic tuning script enables
#      irqbalance and zeroes rps_cpus/xps_cpus on every interface —
#      both clash with the NSS plane (nss-irq-affinity pins the
#      firmware's delivery IRQs by hand, and 12-nss-networking.conf
#      ships net.core.rps_default_mask for the N2H delivery model;
#      netopt.sh itself warns against mixing it with manual affinity
#      writes). Host-side TCP tuning (BBR, conntrack sizing) also
#      targets a pure-host data path, not an offloaded one — the tree's
#      own sysctl fragment covers what the NSS plane needs.
#
# What it does:
#   1. Brand the banner / openwrt_release / os-release
#   2. Install 99-ap-bridge-nss (first-boot branding + WiFi
#      provisioning; network/DHCP/firewall/WAN/NSS provisioning stay
#      with the tree's own defaults)
#
# Requires env: TARGET_MATRIX, AUTHORED_BY, RELEASE_NAME, DATE4
# (all provided by the workflow env + 'Get current date' step)
#

set -e

TARGET_DIR="${TARGET_MATRIX:-.}"
echo "[DIY-NSS] Starting NSS customization for: $TARGET_DIR"

if [ ! -d "$TARGET_DIR" ]; then
    echo "[ERROR] Target directory not found: $TARGET_DIR"
    exit 1
fi

# ===== Source description (for release branding) =====
# The NSS tree is synthesized from the pinned official OpenWrt tarball + the
# vendored nss-overlay (no .git inside the tree), so the workflow passes the
# pinned provenance in SOURCE_COMMIT. Fall back to git for manual builds
# from a real clone.
if [ -n "${SOURCE_COMMIT:-}" ]; then
    SHORT_COMMIT="$SOURCE_COMMIT"
else
    SHORT_COMMIT=$(git -C "$TARGET_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
fi
echo "[DIY-NSS] Source: $SHORT_COMMIT"

# ===== Customize banner =====
if [ -f "diy/banner" ] && [ -d "$TARGET_DIR/package/base-files/files/etc" ]; then
    cp -f diy/banner "$TARGET_DIR/package/base-files/files/etc/banner"
    sed -i "s/%D %V, %C/OpenWrt AP by ${AUTHORED_BY} $(date +'%Y-%m-%d')/g" \
        "$TARGET_DIR/package/base-files/files/etc/banner" || true
    echo "[DIY-NSS] banner installed"
fi

# ===== Brand openwrt_release =====
if [ -f "$TARGET_DIR/package/base-files/files/etc/openwrt_release" ]; then
    sed -i "s/%D/${RELEASE_NAME}/g" "$TARGET_DIR/package/base-files/files/etc/openwrt_release" || true
    sed -i "s/%V/${DATE4}/g" "$TARGET_DIR/package/base-files/files/etc/openwrt_release" || true
    sed -i "s/%C/git-${SHORT_COMMIT}/g" "$TARGET_DIR/package/base-files/files/etc/openwrt_release" || true
    # %R (DISTRIB_REVISION) is expanded by base-files at build time from
    # scripts/getver.sh, which prints "unknown" on a tarball tree (no .git);
    # pin it here instead, same mechanism as the branding above.
    sed -i "s/%R/${SHORT_COMMIT}/g" "$TARGET_DIR/package/base-files/files/etc/openwrt_release" || true
    sed -i "s/Openwrt/${RELEASE_NAME}/g" "$TARGET_DIR/package/base-files/files/etc/openwrt_release" || true
    echo "[DIY-NSS] openwrt_release branded: ${RELEASE_NAME} ${DATE4} ${SHORT_COMMIT}"
fi

# ===== Brand os-release =====
if [ -f "$TARGET_DIR/package/base-files/files/usr/lib/os-release" ]; then
    sed -i "s/%D/${RELEASE_NAME}/g" "$TARGET_DIR/package/base-files/files/usr/lib/os-release" || true
    sed -i "s/%V/${DATE4}/g" "$TARGET_DIR/package/base-files/files/usr/lib/os-release" || true
    sed -i "s/%C/git-${SHORT_COMMIT}/g" "$TARGET_DIR/package/base-files/files/usr/lib/os-release" || true
    sed -i "s/%R/${SHORT_COMMIT}/g" "$TARGET_DIR/package/base-files/files/usr/lib/os-release" || true
fi

# ===== Install first-boot provisioning (NSS variant) =====
mkdir -p "$TARGET_DIR/package/base-files/files/etc/uci-defaults"
if [ -f "diy/cr8806/99-ap-bridge-nss" ]; then
    cp -f diy/cr8806/99-ap-bridge-nss \
        "$TARGET_DIR/package/base-files/files/etc/uci-defaults/99-ap-bridge-nss"
    chmod +x "$TARGET_DIR/package/base-files/files/etc/uci-defaults/99-ap-bridge-nss"
    echo "[DIY-NSS] 99-ap-bridge-nss installed (stock router defaults + WiFi roaming; NSS plane left to the tree's own defaults)"
else
    echo "[ERROR] diy/cr8806/99-ap-bridge-nss not found"
    exit 1
fi

echo "[DIY-NSS] NSS customization completed"
