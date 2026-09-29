#!/usr/bin/env python3
"""Regenerate the per-unit QCN6122 hybrid BDF (board-2.bin) — offline
reference implementation.

The build NO LONGER ships a static QCN6122 board-2.bin. Instead the
12-ath11k-qcn6122-bdf firmware hotplug script generates it per-unit at
boot (community template + the unit's own ART calibration), so ONE image
covers both M79 ("A") and M81 ("B") CR8806 RF boards.

This script is the offline reference implementation of that generation
logic and the authoritative source of the ZONES list — the hotplug
script's zone tokens are extracted from this file programmatically, so
edit the zones HERE, not there. Use it to reproduce the generation on a
PC for verification or debugging.

Background
----------
Every community OpenWrt build for redmi_ax3000/CR880x ships the same QCN6122
board-2.bin: an M81-board extract (md5 c34b1769883ed4da6b3e34fb73d53946,
placeholder MAC 00:03:7f:12:34:56) that still carries the donor unit's
per-unit RF calibration. On M79-hardware units the ath11k firmware consumes
those wrong calibration/board parameters and the 5 GHz radio radiates
near-zero power — clients cannot see the SSID even at 20 cm, while the
stock firmware (which reads calibration straight from the unit's own ART
partition) works fine. Shipping an M79-calibrated file instead would hit
M81 units with the mirror-image defect; generating from the unit's own
ART sidesteps both.

Fix (verified on the M79 unit 172.16.3.19)
------------------------------------------
Keep the community template's container header, board-id zone (0x60, must
match the DT "qcom,board_id" the driver requests) and MAC/date placeholder
zone, then transplant 88 machine-diff zones (3246 bytes) from THIS unit's
own ART[0x26800:+0x20000]: per-unit power calibration tables, board
parameter tables and M79 markers. Result: neighbour AP sees ch36 @ -60 dBm
(previously not found at any range), ath11k boots clean.

Usage
-----
    python3 make-m79-hybrid.py \
        --template qcn6122-bdf-template \
        --art art_m79.bin \
        --out board-2.bin

ART can be dumped on the unit with:
    dd if=/dev/mtd13 of=/tmp/art.bin   # the "0:ART" partition (1 MiB)

Self-check: with the template above and the ART of unit 172.16.3.19
(md5 6b4d60f18ea02838c8e1df56fcc3ac07), the output md5 must be
2e26588c248c4f4b307a5d53a17ba587 — the on-device hotplug script
reproduces exactly this file on that unit (verified: manual run
byte-identical; after deleting board-2.bin the boot-time hotplug
regenerated it with the same md5, ath11k booted clean).

On other units (M79 or M81): the ZONES offsets are structural (derived
from a three-way diff: template vs M79 ART vs M81 ART) and apply to both
board generations; the transplanted VALUES always come from the unit's
own ART. Re-verify 5G air time after flashing.
"""

import argparse
import hashlib
import sys

TEMPLATE_MD5 = "c34b1769883ed4da6b3e34fb73d53946"
BDF_SIZE = 131156           # 84-byte QCA-ATH11K-BOARD container header + 128K body
ART_OFF = 0x26800           # QCN6122 caldata offset inside the ART partition
ART_SIZE = 0x20000
HYBRID_MD5_THIS_UNIT = "2e26588c248c4f4b307a5d53a17ba587"

# (start, end) inclusive, offsets relative to the 128K body (= ART[0x26800:+])
# Zones 0x0a-0x13 (MAC/date placeholder) and 0x3a-0x45 (board-id 0x60) are
# intentionally NOT in this list: they must stay as the template has them.
ZONES = [
    # D-zones: template kept the M81 donor value, M79 hardware needs its own
    (0x00005B, 0x00005B), (0x00044C, 0x00044C), (0x000598, 0x0005C9),
    (0x000618, 0x000623), (0x0008B6, 0x0008B8), (0x0008DD, 0x0008E1),
    (0x001428, 0x001429), (0x0014AC, 0x0014AD), (0x001530, 0x001531),
    (0x0015B4, 0x0015B5), (0x001638, 0x001639), (0x0016BC, 0x0016BD),
    (0x001740, 0x001741), (0x0017C4, 0x0018A9), (0x001EE8, 0x001F05),
    (0x001F28, 0x001F45), (0x001F6C, 0x001F8A), (0x001FAC, 0x001FCA),
    (0x001FF0, 0x00200E), (0x002031, 0x00204E), (0x002075, 0x002091),
    (0x0020B4, 0x0020D2), (0x0020F8, 0x002116), (0x002138, 0x002156),
    (0x00217C, 0x00219A), (0x0021BC, 0x0021DA), (0x002200, 0x00221E),
    (0x002240, 0x00225E), (0x002284, 0x0022A2), (0x0022C4, 0x0022E2),
    (0x002308, 0x002326), (0x002348, 0x002366), (0x00238C, 0x0023AA),
    (0x0023CC, 0x0023EA), (0x002410, 0x00242E), (0x002450, 0x00246E),
    (0x002745, 0x002745), (0x003748, 0x003766), (0x003788, 0x003803),
    (0x003ADA, 0x003ADA), (0x003B27, 0x003B27), (0x003BB0, 0x003BDC),
    (0x003EDA, 0x003F27), (0x0045BE, 0x0046C2), (0x010742, 0x010774),
    (0x010796, 0x0107B4), (0x0107DA, 0x0107F8), (0x01081A, 0x010838),
    (0x01085E, 0x01087C), (0x01089E, 0x0108BB), (0x0108E2, 0x010900),
    (0x010922, 0x01093E), (0x010966, 0x010984), (0x0109A6, 0x0109C4),
    (0x0109EA, 0x010A08), (0x010A2A, 0x010A48), (0x010A6E, 0x010A8B),
    (0x010AAE, 0x010ACB), (0x010AF2, 0x010B0F), (0x010B32, 0x010B4F),
    (0x010C7E, 0x010DB3), (0x011FD2, 0x011FD2), (0x015262, 0x015267),
    (0x0189F6, 0x0189F6), (0x018A6D, 0x018A99),
    # E-zones: three-way differing fields (power tables, board params)
    (0x0001ED, 0x0001ED), (0x000F5B, 0x000F68), (0x000F7D, 0x000F7D),
    (0x001C16, 0x001C25), (0x001C54, 0x001C70), (0x001C94, 0x001CB2),
    (0x001CD8, 0x001CF6), (0x001D18, 0x001D36), (0x001D5C, 0x001D7A),
    (0x001D9C, 0x001DBA), (0x001DE0, 0x001DFE), (0x001E20, 0x001E3E),
    (0x001E64, 0x001E81), (0x001EA4, 0x001EC1), (0x002494, 0x00272B),
    (0x002760, 0x002777), (0x0047BE, 0x004CB2), (0x00E29D, 0x00E2C9),
    (0x0106E4, 0x0106F0), (0x013A12, 0x013A12), (0x0150E8, 0x0150E8),
    (0x0151D4, 0x0151F0), (0x015214, 0x015230),
]

KEEP_ZONES = [(0x0A, 0x13), (0x3A, 0x45)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--template", required=True,
                    help="community M81-board BDF (board-2.bin, 131156 bytes)")
    ap.add_argument("--art", required=True,
                    help="full ART partition dump of the M79 unit (>= 0x46800 bytes)")
    ap.add_argument("--out", required=True, help="output hybrid BDF path")
    args = ap.parse_args()

    tpl = open(args.template, "rb").read()
    if hashlib.md5(tpl).hexdigest() != TEMPLATE_MD5:
        sys.exit("template md5 mismatch: expected %s (community M81 template)" % TEMPLATE_MD5)
    if len(tpl) != BDF_SIZE:
        sys.exit("template size %d != %d" % (len(tpl), BDF_SIZE))

    art = open(args.art, "rb").read()
    if len(art) < ART_OFF + ART_SIZE:
        sys.exit("ART dump too small: need >= 0x%x bytes" % (ART_OFF + ART_SIZE))
    m79c = art[ART_OFF:ART_OFF + ART_SIZE]

    for s, e in KEEP_ZONES:
        for s2, e2 in ZONES:
            if not (e < s2 or s > e2):
                sys.exit("zone list must not touch keep-zone %06x-%06x" % (s, e))

    body = bytearray(tpl[84:])
    changed = 0
    for s, e in ZONES:
        for i in range(s, e + 1):
            if body[i] != m79c[i]:
                body[i] = m79c[i]
                changed += 1

    out = tpl[:84] + bytes(body)
    md5 = hashlib.md5(out).hexdigest()
    open(args.out, "wb").write(out)

    print("template : %s (%s)" % (args.template, TEMPLATE_MD5))
    print("art      : %s (md5 %s)" % (args.art, hashlib.md5(art).hexdigest()))
    print("zones    : %d, bytes changed: %d" % (len(ZONES), changed))
    print("output   : %s (%d bytes, md5 %s)" % (args.out, len(out), md5))
    if md5 == HYBRID_MD5_THIS_UNIT:
        print("self-check OK: matches the verified hybrid of unit 172.16.3.19")
    else:
        print("note: differs from unit 172.16.3.19 hybrid (expected when using "
              "another unit's ART) — verify 5G air time after flashing")


if __name__ == "__main__":
    main()
