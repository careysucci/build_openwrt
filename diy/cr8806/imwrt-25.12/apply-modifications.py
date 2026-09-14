#!/usr/bin/env python3
"""In-place modifications for Redmi AX3000 / CR880X on ImmortalWrt openwrt-25.12.

Every edit is anchored on an exact string from the upstream file; the script
fails loudly (exit 1) if an anchor is missing so upstream drift is detected at
build time instead of producing a silently broken image. All edits are
idempotent: if the redmi_ax3000 marker is already present the file is skipped.
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
	$(call Device/FitImage)
	$(call Device/UbiFit)
	DEVICE_VENDOR := Redmi
	DEVICE_MODEL := AX3000
	DEVICE_ALT0_VENDOR := Xiaomi
	DEVICE_ALT0_MODEL := CR880X
	DEVICE_ALT0_VARIANT := (M81 version)
	DEVICE_ALT1_VENDOR := Xiaomi
	DEVICE_ALT1_MODEL := CR880X
	DEVICE_ALT1_VARIANT := (M79 version)
	BLOCKSIZE := 128k
	PAGESIZE := 2048
	SOC := ipq5000
	NAND_SIZE := 128m
	DEVICE_DTS_CONFIG := config@mp02.1
	DEVICE_PACKAGES := ath11k-firmware-ipq5018-qcn6122 ipq-wifi-redmi_ax3000
endef
TARGET_DEVICES += redmi_ax3000
""",
        "append",
    )],
)

# 2. Default network config (LAN1-3 via SGMII conduit eth1, WAN via GE PHY
#    conduit eth0 - the PHY-to-PHY link through QCA8337 port 5) --------------
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

# 3. WiFi calibration data extraction from the "0:ART" partition --------------
patch_file(
    "target/linux/qualcommax/ipq50xx/base-files/etc/hotplug.d/firmware/11-ath11k-caldata",
    "redmi,ax3000",
    [
        (
            '"ath11k/IPQ5018/hw1.0/cal-ahb-c000000.wifi.bin")\n\tcase "$board" in\n',
            "\tredmi,ax3000)\n"
            '\t\tcaldata_extract "0:ART" 0x1000 0x20000\n'
            "\t\t;;\n",
            "after",
        ),
        (
            '"ath11k/QCN6122/hw1.0/cal-ahb-b00a040.wifi.bin")\n\tcase "$board" in\n',
            "\tredmi,ax3000)\n"
            '\t\tcaldata_extract "0:ART" 0x26800 0x20000\n'
            "\t\t;;\n",
            "after",
        ),
    ],
)

# 4. sysupgrade: Xiaomi dual-boot slot flipping --------------------------------
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

# 5. u-boot environment access (0:APPSBLENV, dual-boot flags) -----------------
patch_file(
    "package/boot/uboot-tools/uboot-envtools/files/qualcommax_ipq50xx",
    "redmi,ax3000",
    [(
        'case "$board" in\n',
        "redmi,ax3000)\n"
        '\tubootenv_add_mtd "0:APPSBLENV" "0x0" "0x10000" "0x20000"\n'
        "\t;;\n",
        "after",
    )],
)

# 6. Board data file (BDF) package for IPQ5018 + QCN6122 ----------------------
patch_file(
    "package/firmware/ipq-wifi/Makefile",
    "redmi_ax3000",
    [
        (
            "\tqnap_301w \\\n",
            "\tredmi_ax3000 \\\n",
            "after",
        ),
        (
            "$(eval $(call generate-ipq-wifi-package,qnap_301w,QNAP 301w))\n",
            "$(eval $(call generate-ipq-wifi-package,redmi_ax3000,Redmi AX3000))\n",
            "after",
        ),
    ],
)

if FAILURES:
    print("\nERROR: adaptation failed:")
    for f in FAILURES:
        print(" -", f)
    sys.exit(1)

print("All modifications applied.")
