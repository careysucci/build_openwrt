# NSS overlay — vendored increment over the official OpenWrt tree

This directory carries the complete NSS hardware-offload increment of
[kuncy7/openwrt-nss-edma](https://github.com/kuncy7/openwrt-nss-edma)
(branch `c3po-tag-8021q`) as **plain files in this repository**, applied at
build time on top of a **pinned official OpenWrt commit**. The CI build
never clones the third-party firmware branch: it downloads the official
tarball and applies this overlay, so every byte of the NSS layer is under
this repository's change control.

## Provenance (pinned)

| role | repository | ref |
| --- | --- | --- |
| base (official OpenWrt) | openwrt/openwrt | `3ab520425b127d66617bfeb1e2805b4f20109f95` (main, 2026-09-25) |
| head (NSS branch) | kuncy7/openwrt-nss-edma | `c3po-tag-8021q` @ `2f00ddefdba6b31d21f8b1d0edeb782c4eac5d6e` |

The NSS branch is itself a mirror of `git.openwrt.org/openwrt/openwrt.git`
plus the NSS work: its history contains the official main up to the base
commit above (`git diff` between the two ids is exactly this overlay).
The companion **nss feed** (qca-nss-drv, qca-nss-ecm, nss-firmware 12.2)
is pinned separately in the workflow: `kuncy7/nss-packages` branch
`ipq50xx-rebase` @ `23ba3ccc5d92815e51872ba950de8dd35988eec5`.

## Contents

```
MANIFEST.txt            487 entries: A 276 add / M 180 modify / D 30 remove / L 1 symlink,
                        each with sha256 (base precondition + applied result)
tree/<path>             the 456 added/modified files, byte-identical to the
                        branch blobs (verified by git hash-object at extraction)
apply-nss-overlay.sh    POSIX sh applier: precondition -> apply -> verify
tools/extract-nss-overlay.py  the generator (keeps the derivation reproducible)
```

The increment includes: the IPQ5018 NSS core enablement (kernel patches
0956/0961 stmmac data-plane claim, 0192 core clock, 0136/0137 core boot),
`ipq5018-nss.dtsi` / `ipq5018-ess.dtsi` and per-board NSS DTS includes, the
`qca-dwmac-nss` / `qca8337-nss` / `qca-dsa-nss` / `qca-ppe-nss` kernel
module packages, the `nss-tools` bring-up service (98-nss-offload,
99-nss-topology, nss-irq-affinity), the ath11k Wi-Fi offload patch set
under `mac80211/patches/nss/`, the 802.1Q tag drivers (761/762), and the
feed pointer in `feeds.conf.default`.

## How the build applies it

```sh
curl -fsSL <tarball of the pinned base commit> | tar -xz --strip-components=1 -C openwrt
./diy/cr8806/nss-overlay/apply-nss-overlay.sh openwrt
```

`apply-nss-overlay.sh` refuses to run unless every file it is about to
modify or delete still hashes to the recorded **base** sha256 — bumping the
base commit without re-deriving the overlay fails loudly instead of
producing a half-patched tree. After applying it re-hashes everything
against the recorded **result** sha256 values.

## Re-deriving (e.g. to follow a newer kuncy7 head or a newer official base)

```sh
git clone https://github.com/kuncy7/openwrt-nss-edma.git   # any clone containing both refs
git -C openwrt-nss-edma fetch --depth 1 origin <new-official-base-sha>
python3 tools/extract-nss-overlay.py <repo> <this-directory>   # update BASE/HEAD in the script first
```

The generator updates `MANIFEST.txt` and `tree/` wholesale and re-proves
per-file byte fidelity (git hash-object == branch blob id). Commit the
result together with the workflow's pinned tarball URL and feed pin.

## Verification status

- Byte fidelity: every `tree/` file hashes (git blob id) equal to the
  kuncy7 branch blob — checked at generation time; `apply-nss-overlay.sh`
  re-checks sha256 on both ends at build time.
- The resulting tree is byte-identical to the branch the community
  validates (GL-B3000 wired ~900 Mbit/s, Wi-Fi offload on B3000/MX2000,
  256M group on Cudy P5 / TP-Link EX511), so all community validation
  carries over to the synthesized tree.
- CR8806-specific parts remain as documented in the workflow release notes
  (not yet device-tested; recovery is U-boot TFTP back to the 25.12 image).
