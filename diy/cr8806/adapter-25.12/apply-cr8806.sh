#!/bin/bash
# Inject Redmi AX3000 / Xiaomi CR880X + Xiaomi CR881x (CR8816/8818/8819)
# device support into an official OpenWrt / ImmortalWrt openwrt-25.12
# source tree.
#
# Adapted from kmiit/Redmi_AX3000_immortalwrt (branch redmi_ax3000-24.10):
#   - DTS rewritten to the 25.12 style (6.12 kernel, upstream dtsi layout,
#     at803x "qcom,dac-preset-short-cable" instead of legacy mdac/edac props)
#   - ath11k board_id patches (211/212) + DMA buffer reduction (911) carried
#     over; everything else (QCN6122 support, RSSI fix, MPD, ge_phy, caldata
#     helpers) is already upstream in 25.12.
#
# CR881x addition (same IPQ5018 SoC family, but a Motorcomm YT9215 switch
# instead of QCA8337 — CR880X images boot on a CR881x but no port comes up):
#   - DTS modeled after zcop/immortalwrt openwrt-25.12 (field-verified),
#     reworked to this tree's conventions (smem-part, board clocks)
#   - static BDFs from hzyitc/openwrt-redmi-ax3000 (board-id 0x23/0x60 match
#     the DT directly, no per-unit BDF generation needed)
#   - mainline v8 YT921x DSA driver backport (0913 tag + 0914 driver) plus
#     the REVSGMII SerDes hack (0915), all field-verified via zcop's build
#
# Run from the root of the ImmortalWrt source tree.

set -e

ADAPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[ -d target/linux/qualcommax/ipq50xx ] || {
	echo "ERROR: run this script from the ImmortalWrt source tree root" >&2
	exit 1
}

echo "=== Injecting CR8806 (redmi_ax3000) + CR881x (xiaomi_cr881x) device support into $(git describe --tags --always 2>/dev/null || echo 'source tree') ==="

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

# --- CR881x (CR8816 / CR8818 / CR8819: YT9215-switch sibling of the CR880X) --
# Same IPQ5018 + QCN6122 radio platform, but the switch is a Motorcomm
# YT9215 (external MDIO 0x1d, reset GPIO 39) instead of a QCA8337 — a CR880X
# image boots on this hardware yet no ethernet port ever comes up.
install -Dm644 "$ADAPT_DIR/ipq5018-cr881x.dts" \
	target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq5018-cr881x.dts

# Static BDFs for the CR881x (from hzyitc/openwrt-redmi-ax3000, also shipped
# by zcop/immortalwrt): container entries qmi-board-id=35 (0x23, 2.4G IPQ5018)
# and qmi-board-id=96 (0x60, 5G QCN6122) — they match the DT board_id values
# directly, so unlike the CR880X neither a per-unit board-id hotplug override
# nor a generated BDF is needed. Per-unit RF calibration still comes from the
# unit's own ART via the stock 11-ath11k-caldata hook (same offsets as the
# CR880X: 0x1000 / 0x26800); 12-ath11k-qcn6122-bdf short-circuits here
# because the static board-2.bin already exists.
install -Dm644 "$ADAPT_DIR/board-xiaomi_cr881x.ipq5018" \
	package/firmware/ipq-wifi/src/board-xiaomi_cr881x.ipq5018
install -Dm644 "$ADAPT_DIR/board-xiaomi_cr881x.qcn6122" \
	package/firmware/ipq-wifi/src/board-xiaomi_cr881x.qcn6122

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

# --- 2b. Kernel patches (YT9215 DSA driver for the CR881x) --------------------
# Mainline net-next v8 series (David Yang, merged for v6.19), backported for
# 6.12 via zcop/immortalwrt's field-verified packaging. Upstream 25.12 already
# carries the v6.17 "BRCM_LEGACY_FCS" DSA tag backport (generic 611-01), so the
# mainline patches apply unchanged: DSA_TAG_PROTO_YT921X (=30) slots in right
# after BRCM_LEGACY_FCS (=29), and .support_eee is already backported too.
# 0915 is the REVSGMII hack: on IPQ5018 the Uniphy pairs with the YT9215 only
# in PHY-role SGMII ("REVSGMII"), which the kernel cannot express — the driver
# maps "sgmii" to it (openwrt forum t/241325).
echo "--- Installing kernel patches"
for p in "$ADAPT_DIR"/patches-kernel/*.patch; do
	name="$(basename "$p")"
	dest="target/linux/qualcommax/patches-6.12/$name"
	if [ -e "$dest" ]; then
		echo "ERROR: patch slot already occupied upstream: $name" >&2
		exit 1
	fi
	install -Dm644 "$p" "$dest"
done

# --- 3. In-place modifications ------------------------------------------------
echo "--- Patching existing files"
python3 "$ADAPT_DIR/apply-modifications.py"

echo "=== CR8806 + CR881x device support injected successfully ==="
