#!/bin/bash
# Inject Redmi AX3000 / Xiaomi CR880X (CR8806/CR8808/CR8809) device support
# into the NSS source tree (kuncy7/openwrt-nss-edma, branch c3po-tag-8021q,
# kernel 6.18: upstream stmmac/dwmac-ipq5018 MACs + qca8k DSA switch +
# NSS PPE hardware acceleration).
#
# Run from the root of the NSS source tree.
#
# What this script installs (and why it differs from the 25.12 adapter):
#   - Board DTS in target/linux/qualcommax/dts/ (the NSS tree keeps board
#     DTS there; the image Makefile's DEVICE_DTS default rule resolves
#     redmi_ax3000 + SOC ipq5018 to ipq5018-ax3000.dts).
#   - Per-unit BDF generators for BOTH radios, writing bare board.bin files
#     at firmware-request time. The 6.18 ath11k has no board_id override
#     patches (hzyitc 211/212 do not apply to this tree), and the WLAN
#     firmware reports qmi-board-id 0xFF until calibrated — proven by the
#     upstream Cudy P5 / TP-Link EX511 board files on this tree, whose
#     entries are all named "...qmi-board-id=255". No static board-2.bin
#     of ours can match that, so both radios use the board.bin fallback
#     path (ath11k_core_fetch_board_data_api_1: loaded verbatim, NO name
#     matching). The bytes the firmware receives are identical to what the
#     device-verified 25.12 image delivered via container entry matching;
#     per-unit calibration still comes from the stock 11-ath11k-caldata.
#   - Xiaomi dual-boot upgrade path (mi_dualboot.sh, auto-sourced by
#     stage2's "include /lib/upgrade") + boot-flag confirmation script.
#   - NO mac80211 patches: the tree already carries everything needed
#     (QCN6122 MPD v2 series 913/920/921-925, fw-memory-mode via DT 903,
#     split-firmware wcss-sec 0808/0813). The 25.12 tree's 211/212/911
#     have no equivalent here and are intentionally NOT carried over.

set -e

ADAPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[ -d target/linux/qualcommax/ipq50xx ] || {
        echo "ERROR: run this script from the NSS source tree root" >&2
        exit 1
}

echo "=== Injecting CR8806 (redmi_ax3000) NSS device support into $(git describe --tags --always 2>/dev/null || echo 'source tree') ==="

# --- 1. New files -------------------------------------------------------------
echo "--- Installing new files"

# Board DTS (ethernet from upstream AX5400, QCN6122 section from B3000,
# 256M memory recipe from EX511 v2, peripherals from the 25.12 build —
# all section sources documented inside the DTS)
install -Dm644 "$ADAPT_DIR/ipq5018-ax3000.dts" \
        target/linux/qualcommax/dts/ipq5018-ax3000.dts

# 2.4 GHz IPQ5018 BDF: per-unit generator (13) + community dual-entry
# container template (M79 entry id 0x10 @0x54 / M81 entry id 0x24
# @0x20094; md5 9acb0e52055cad7760f9630cf55a6d2e). The generator extracts
# the wl_pa_type-matching entry body as a bare board.bin.
install -Dm755 "$ADAPT_DIR/13-ath11k-ipq5018-bdf" \
        target/linux/qualcommax/ipq50xx/base-files/etc/hotplug.d/firmware/13-ath11k-ipq5018-bdf
install -Dm644 "$ADAPT_DIR/ipq5018-bdf-template" \
        target/linux/qualcommax/ipq50xx/base-files/lib/firmware/ath11k/ipq5018-bdf-template.bin

# 5 GHz QCN6122 BDF: per-unit generator (12, board.bin variant of the
# device-verified 25.12 script) + community M81-board skeleton template
# (md5 c34b1769883ed4da6b3e34fb73d53946). 88 machine-diff zones are
# transplanted from THIS unit's ART[0x26800:+0x20000], exactly as on 25.12.
install -Dm755 "$ADAPT_DIR/12-ath11k-qcn6122-bdf" \
        target/linux/qualcommax/ipq50xx/base-files/etc/hotplug.d/firmware/12-ath11k-qcn6122-bdf
install -Dm644 "$ADAPT_DIR/qcn6122-bdf-template" \
        target/linux/qualcommax/ipq50xx/base-files/lib/firmware/ath11k/qcn6122-bdf-template.bin

# Xiaomi dual-boot: sysupgrade flips rootfs/rootfs_1 slots via fw_setenv;
# the init script confirms a successful boot back to U-Boot on the next
# startup. uboot-envtools stays a hard device dependency (see the Device
# definition added by apply-modifications-nss.py).
install -Dm644 "$ADAPT_DIR/mi_dualboot.sh" \
        target/linux/qualcommax/ipq50xx/base-files/lib/upgrade/mi_dualboot.sh
install -Dm755 "$ADAPT_DIR/uboot_env" \
        target/linux/qualcommax/ipq50xx/base-files/etc/init.d/uboot_env

# --- 2. In-place modifications ------------------------------------------------
echo "--- Patching existing files"
python3 "$ADAPT_DIR/apply-modifications-nss.py"

echo "=== CR8806 NSS device support injected successfully ==="
