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

# Board data (BDF) for the 2.4 GHz IPQ5018 radio. Build/Prepare/Default
# copies ./src/* into the ipq-wifi PKG_BUILD_DIR, where
# generate-ipq-wifi-package picks them up via wildcard. Without this file
# ipq-wifi-redmi_ax3000 builds EMPTY (wildcard silently matches nothing)
# and ath11k falls back to generic board data. The per-unit 2.4G
# calibration is layered on at boot by the stock 11-ath11k-caldata
# firmware hotplug script (extracts caldata.bin from the unit's ART).
install -Dm644 "$ADAPT_DIR/board-redmi_ax3000.ipq5018" \
	package/firmware/ipq-wifi/src/board-redmi_ax3000.ipq5018

# 5 GHz QCN6122 BDF: generated PER-UNIT at boot by the
# 12-ath11k-qcn6122-bdf firmware hotplug script, from the community
# template below + THIS unit's own ART calibration. The image deliberately
# ships NO static QCN6122 board-2.bin: ath11k requests it, finds nothing,
# the hotplug hook fires, generates the file, and the kernel retries the
# read. One image thus covers BOTH CR8806 RF board generations (M79 "A"
# and M81 "B") — every unit boots with its own per-unit RF calibration,
# exactly like stock firmware (which reads calibration straight from ART).
#
# qcn6122-bdf-template (md5 c34b1769883ed4da6b3e34fb73d53946) is the
# community M81-board skeleton: its 84-byte QCA-ATH11K-BOARD container
# header, board-id zone (0x60 — what the DT asks for) and MAC/date
# placeholders are kept; 88 machine-diff zones (3246 bytes: per-unit power
# calibration tables, board parameter tables, board markers) are
# transplanted from the unit's own ART[0x26800:+0x20000]. Zone list
# derived from a three-way diff (template vs M79 ART vs M81 ART), mirrored
# in make-m79-hybrid.py (the offline reference implementation).
#
# Verified on M79 unit 172.16.3.19 (kmiit 24.10, kernel 6.6):
#   - manual generation output == the hand-verified hybrid
#     md5 2e26588c248c4f4b307a5d53a17ba587 (byte-identical)
#   - deleted board-2.bin, rebooted: hotplug log "ath11k-bdf: generated",
#     ath11k booted clean, 5G AP up ch36 HE80
#   - neighbour scan: ch36 @ -61/-62 dBm (before the fix: not found at any
#     range); iperf3 over the 5G link: 465 Mbps down / 355 Mbps up
#   - M81 units need the same 88-zone transplant from their own ART (same
#     offset, cross-checked against the M81 ART dump); full M81 validation
#     still pending a 25.12 flash on an M81 unit.
install -Dm644 "$ADAPT_DIR/qcn6122-bdf-template" \
	target/linux/qualcommax/ipq50xx/base-files/lib/firmware/ath11k/qcn6122-bdf-template.bin
install -Dm755 "$ADAPT_DIR/12-ath11k-qcn6122-bdf" \
	target/linux/qualcommax/ipq50xx/base-files/etc/hotplug.d/firmware/12-ath11k-qcn6122-bdf

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
