#!/usr/bin/env python3
"""In-place modifications for Redmi AX3000 / CR880X on the NSS tree
(kuncy7/openwrt-nss-edma, c3po-tag-8021q branch, kernel 6.18).

Same anchoring contract as the 25.12 script: every edit is anchored on an
exact string from the tree file; the script fails loudly (exit 1) if an
anchor is missing so upstream drift is detected at build time instead of
producing a silently broken image. All edits are idempotent: if the marker
is already present the file is skipped.

Differences from the 25.12 script:
  - SOC := ipq5018 (the NSS tree names every ipq50xx board ipq5018, and
    the board DTS lives in target/linux/qualcommax/dts/, so the default
    DEVICE_DTS rule resolves to ipq5018-ax3000.dts).
  - No ipq-wifi-redmi_ax3000 registration at all: neither radio ships a
    static board-2.bin. The 6.18 ath11k has no board_id override patches
    and the firmware reports qmi-board-id 0xFF until calibrated (see the
    hotplug generators 12-/13- for the full reasoning), so both radios
    load a per-unit generated bare board.bin instead.
"""

import sys

FAILURES = []


def patch_file(path, marker, edits):
    try:
        with open(path, "r", encoding="utf-8", newline="") as f:
            content = f.read()
    except FileNotFoundError:
        FAILURES.append(f"{path}: file not found")
        return
    if marker in content:
        print(f"  [skip] {path} (already patched)")
        return
    original = content
    for anchor, insertion, where in edits:
        if where == "append":
            content = content.rstrip("\n") + "\n" + insertion
            continue
        if anchor not in content:
            FAILURES.append(f"{path}: anchor not found: {anchor!r}")
            return
        if where == "after":
            content = content.replace(anchor, anchor + insertion, 1)
        else:
            content = content.replace(anchor, insertion + anchor, 1)
    if content != original:
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(content)
        print(f"  [ok]   {path}")


# 1. Device definition: append to the ipq50xx image makefile -------------------
patch_file(
    "target/linux/qualcommax/image/ipq50xx.mk",
    "redmi_ax3000",
    [(
        None,
        """
define Device/redmi_ax3000
\t$(call Device/FitImage)
\t$(call Device/UbiFit)
\tDEVICE_VENDOR := Redmi
\tDEVICE_MODEL := AX3000
\tDEVICE_ALT0_VENDOR := Xiaomi
\tDEVICE_ALT0_MODEL := CR880X
\tDEVICE_ALT0_VARIANT := (M81 version)
\tDEVICE_ALT1_VENDOR := Xiaomi
\tDEVICE_ALT1_MODEL := CR880X
\tDEVICE_ALT1_VARIANT := (M79 version)
\tBLOCKSIZE := 128k
\tPAGESIZE := 2048
\tSOC := ipq5018
\tNAND_SIZE := 128m
\tDEVICE_DTS_CONFIG := config@mp02.1
\t# uboot-envtools: hard dependency — the Xiaomi dual-boot upgrade path
\t# (mi_dualboot.sh fw_setenv slot flipping + uboot_env boot flag script)
\t# breaks without fw_printenv/fw_setenv. Force-include it so a seed config
\t# with "# CONFIG_PACKAGE_uboot-envtools is not set" cannot silently
\t# disable OTA slot flipping on this device. The BDF generators also read
\t# wl_pa_type via /dev/mtdblock (appsblenv), though they only need the
\t# node, not the fw_* binaries.
\t# No ipq-wifi-redmi_ax3000: both radios load a per-unit generated bare
\t# board.bin (hotplug 12-/13-ath11k-*-bdf) — no static board-2.bin can
\t# match the 0xFF board_id the uncalibrated firmware reports upstream.
\tDEVICE_PACKAGES := ath11k-firmware-ipq5018-qcn6122 uboot-envtools
\t# factory.img: same ubinized UBI payload as factory.ubi, .img suffix for
\t# flashing tools that expect it (U-boot TFTP accepts both).
\tIMAGES += factory.img
\tIMAGE/factory.img := append-ubi
endef
TARGET_DEVICES += redmi_ax3000
""",
        "append",
    )],
)

# 2. Default network config (LAN1-3 via SGMII conduit eth1, WAN via GE PHY
#    conduit eth0 - the PHY-to-PHY link through QCA8337 port 5). Same as the
#    upstream xiaomi,redmi-ax5400 case: identical wiring on this board. ------
patch_file(
    "target/linux/qualcommax/ipq50xx/base-files/etc/board.d/02_network",
    "redmi,ax3000",
    [(
        "\tcase $board in\n",
        "\tredmi,ax3000)\n"
        '\t\tucidef_set_interfaces_lan_wan "lan1 lan2 lan3" "wan"\n'
        '\t\tucidef_set_network_device_conduit "lan1" "eth1"\n'
        '\t\tucidef_set_network_device_conduit "lan2" "eth1"\n'
        '\t\tucidef_set_network_device_conduit "lan3" "eth1"\n'
        '\t\tucidef_set_network_device_conduit "wan" "eth0"\n'
        "\t\t;;\n",
        "after",
    )],
)

# 3. WiFi calibration data extraction from the "0:art" partition -----------
# NOTE: lowercase! 6.12+ kernels parse Xiaomi's SMEM table to lowercase names
# (verified on-device: "0:art"); request strings here match the NSS tree's
# stock script (UPPERCASE "QCN6122" fw.dir, per mac80211 patch 920).
patch_file(
    "target/linux/qualcommax/ipq50xx/base-files/etc/hotplug.d/firmware/11-ath11k-caldata",
    "redmi,ax3000",
    [
        (
            '"ath11k/IPQ5018/hw1.0/cal-ahb-c000000.wifi.bin")\n\tcase "$board" in\n',
            "\tredmi,ax3000)\n"
            '\t\tcaldata_extract "0:art" 0x1000 0x20000\n'
            "\t\t;;\n",
            "after",
        ),
        (
            '"ath11k/QCN6122/hw1.0/cal-ahb-b00a040.wifi.bin")\n\tcase "$board" in\n',
            "\tredmi,ax3000)\n"
            '\t\tcaldata_extract "0:art" 0x26800 0x20000\n'
            "\t\t;;\n",
            "after",
        ),
    ],
)

# 4. sysupgrade: Xiaomi dual-boot slot flipping --------------------------------
# mi_dualboot.sh is installed as base-files /lib/upgrade/mi_dualboot.sh and
# auto-sourced by stage2's "include /lib/upgrade" (verified present in this
# tree's package/base-files/files/lib/upgrade/stage2).
patch_file(
    "target/linux/qualcommax/ipq50xx/base-files/lib/upgrade/platform.sh",
    "mi_dualboot_do_upgrade",
    [(
        'platform_do_upgrade() {\n\tcase "$(board_name)" in\n',
        "\tredmi,ax3000)\n"
        '\t\tmi_dualboot_do_upgrade "$1"\n'
        "\t\t;;\n",
        "after",
    )],
)

# 5. u-boot environment access (0:appsblenv, dual-boot flags) ----------------
patch_file(
    "package/boot/uboot-tools/uboot-envtools/files/qualcommax_ipq50xx",
    "redmi,ax3000",
    [(
        'case "$board" in\n',
        "redmi,ax3000)\n"
        '\tubootenv_add_mtd "0:appsblenv" "0x0" "0x10000" "0x20000"\n'
        "\t;;\n",
        "after",
    )],
)

if FAILURES:
    print("\nERROR: adaptation failed:")
    for f in FAILURES:
        print(" -", f)
    sys.exit(1)

print("All modifications applied.")
