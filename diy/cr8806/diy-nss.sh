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
BANNER_FILE="${BANNER_FILE:-banner}"
if [ -f "diy/${BANNER_FILE}" ] && [ -d "$TARGET_DIR/package/base-files/files/etc" ]; then
    if [ "${BANNER_FILE}" = "banner-wyhousewrt" ]; then
        mkdir -p "$TARGET_DIR/package/base-files/files/etc/profile.d"
        sed -e "s#__AUTHORED_BY__#${AUTHORED_BY:-Wy.House}#g" \
            -e "s#__BUILD_DATE__#$(date +'%Y-%m-%d')#g" \
            "diy/${BANNER_FILE}" \
            > "$TARGET_DIR/package/base-files/files/etc/profile.d/99-wyhouse-banner.sh" || true
        chmod +x "$TARGET_DIR/package/base-files/files/etc/profile.d/99-wyhouse-banner.sh"
        : > "$TARGET_DIR/package/base-files/files/etc/banner"
        echo "[DIY-NSS] dynamic banner installed (etc/profile.d/99-wyhouse-banner.sh)"
    else
        cp -f "diy/${BANNER_FILE}" "$TARGET_DIR/package/base-files/files/etc/banner"
        sed -i "s/%D %V, %C/OpenWrt AP by ${AUTHORED_BY} $(date +'%Y-%m-%d')/g" \
            "$TARGET_DIR/package/base-files/files/etc/banner" || true
        echo "[DIY-NSS] static banner installed (diy/${BANNER_FILE} -> /etc/banner)"
    fi
fi

# ===== Provide the apk package-version REVISION (getver.sh) =====
# The tree is a tarball + overlay (no .git), so scripts/getver.sh falls
# through to REV="unknown". base-files then versions its apk as
# "<commitcount>~unknown" and host apk mkpkg rejects it:
#   ERROR: info field 'version' has invalid value: package version is invalid
# getver.sh's FIRST choice is a plain "version" file in the tree root,
# which is also how the official release tarballs ship their revision.
# Write one shaped like a real git revision "r<n>-<shortsha>" so the
# resulting base-files version matches what the official buildbot
# publishes (e.g. base-files-1708~5c8e736980.apk): only the last
# dash-separated word feeds the apk version, and it must start with a
# digit (hex commit prefix), never a letter like "unknown".
NSS_VERSION_SHA="${OFFICIAL_BASE_SHA:-}"
if [ -z "$NSS_VERSION_SHA" ]; then
    NSS_VERSION_SHA=$(git -C "$TARGET_DIR" rev-parse --short=10 HEAD 2>/dev/null || echo "")
fi
[ -n "$NSS_VERSION_SHA" ] || NSS_VERSION_SHA="0000000000"
printf 'r0-%s\n' "${NSS_VERSION_SHA:0:10}" > "$TARGET_DIR/version"
echo "[DIY-NSS] version file written: $(cat "$TARGET_DIR/version") (REVISION for apk package versions)"

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
