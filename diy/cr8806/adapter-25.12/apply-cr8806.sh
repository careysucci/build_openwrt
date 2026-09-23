#!/bin/bash
# Inject Redmi AX3000 / Xiaomi CR880X device support into an official
# OpenWrt / ImmortalWrt openwrt-25.12 source tree.
#
# Adapted from kmiit/Redmi_AX3000_immortalwrt (branch redmi_ax3000-24.10):
#   - DTS rewritten to the 25.12 style (6.12 kernel, upstream dtsi layout,
#     at803x "qcom,dac-preset-short-cable" instead of legacy mdac/edac props)
#   - ath11k board_id patches (211/212) + DMA buffer reduction (911) carried
#     over; everything else (QCN6122 support, RSSI fix, MPD, ge_phy, caldata
#     helpers) is already upstream in 25.12.
#
# Run from the root of the ImmortalWrt source tree.

set -e

ADAPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[ -d target/linux/qualcommax/ipq50xx ] || {
	echo "ERROR: run this script from the ImmortalWrt source tree root" >&2
	exit 1
}

echo "=== Injecting CR8806 (redmi_ax3000) device support into $(git describe --tags --always 2>/dev/null || echo 'source tree') ==="

# --- 1. New files -------------------------------------------------------------
echo "--- Installing new files"
install -Dm644 "$ADAPT_DIR/ipq5000-ax3000.dts" \
	target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq5000-ax3000.dts
install -Dm755 "$ADAPT_DIR/10-ath11k-board_id" \
	target/linux/qualcommax/ipq50xx/base-files/etc/hotplug.d/firmware/10-ath11k-board_id
install -Dm755 "$ADAPT_DIR/uboot_env" \
	target/linux/qualcommax/ipq50xx/base-files/etc/init.d/uboot_env
install -Dm644 "$ADAPT_DIR/mi_dualboot.sh" \
	target/linux/qualcommax/ipq50xx/base-files/lib/upgrade/mi_dualboot.sh

# Board data files (BDF) for IPQ5018 + QCN6122. Build/Prepare/Default copies
# ./src/* into the ipq-wifi PKG_BUILD_DIR, where generate-ipq-wifi-package
# picks them up via wildcard. Without them ipq-wifi-redmi_ax3000 builds EMPTY
# (wildcard silently matches nothing) and ath11k falls back to generic board
# data — the QCN6122 5GHz radio then runs with wrong RF parameters.
# Source: kmiit redmi_ax3000-24.10 ipq-wifi/src; md5-verified identical to
# the BDF shipped by hzyitc's 21.02 build on the M79 test unit.
install -Dm644 "$ADAPT_DIR/board-redmi_ax3000.ipq5018" \
	package/firmware/ipq-wifi/src/board-redmi_ax3000.ipq5018
install -Dm644 "$ADAPT_DIR/board-redmi_ax3000.qcn6122" \
	package/firmware/ipq-wifi/src/board-redmi_ax3000.qcn6122

# --- 2. mac80211 patches ------------------------------------------------------
echo "--- Installing mac80211 patches"
for p in "$ADAPT_DIR"/patches/*.patch; do
	name="$(basename "$p")"
	dest="package/kernel/mac80211/patches/ath11k/$name"
	if [ -e "$dest" ]; then
		echo "ERROR: patch slot already occupied upstream: $name" >&2
		exit 1
	fi
	install -Dm644 "$p" "$dest"
done

# --- 3. In-place modifications ------------------------------------------------
echo "--- Patching existing files"
python3 "$ADAPT_DIR/apply-modifications.py"

echo "=== CR8806 device support injected successfully ==="
