#!/bin/bash
# =============================================================
# Build script: build-openclash.sh
# Scope:  Build-time only — NOT installed into the firmware image
# Called: Sourced from diy-part2.sh (inherits TARGET_DIR, GITHUB_WORKSPACE, etc.)
#
# Actions:
#   1. Copy clash-all-noicon-clash.yaml into the image
#   1b. Copy nikki-config.yaml into the image
#   1c. Inject CLASH_SUB_URL into YAML proxy-providers + Nikki/HomeProxy (if set)
#   2. Pre-download Clash Meta core from vernesong/OpenClash releases
#      so OpenClash works immediately after flashing.
#
# Core source: https://github.com/vernesong/OpenClash/releases
#   Asset: clash_meta-linux-amd64-compatible.gz  (broadest x86_64 support)
#   UCI: core_type=Meta / core_version=linux-amd64-v1
#   Binary installed as /etc/openclash/core/clash_meta
# =============================================================

# ── 1. Install OpenClash YAML config ─────────────────────────
_OC_CFG_DIR="$TARGET_DIR/package/base-files/files/etc/openclash/config"
# proxy-provider 本地缓存目录，与 yaml 内 proxy-providers.cc-auto.path 一致：
#   /etc/openclash/config/providers/cc-auto.yaml
_OC_PROV_DIR="$TARGET_DIR/package/base-files/files/etc/openclash/config/providers"
mkdir -p "$_OC_CFG_DIR" "$_OC_PROV_DIR"

_YAML_SRC="$GITHUB_WORKSPACE/clash-all-noicon-clash.yaml"
if [ -f "$_YAML_SRC" ]; then
    cp -f "$_YAML_SRC" "$_OC_CFG_DIR/clash-all-noicon-clash.yaml"
    echo "[build-openclash] YAML installed → $_OC_CFG_DIR/clash-all-noicon-clash.yaml"
else
    echo "[build-openclash] WARNING: clash-all-noicon-clash.yaml not found, skipping"
fi

# ── 1b. Install Nikki (mihomo) YAML profile ──────────────────
# Nikki reads profiles from /etc/nikki/profiles/<name>.yaml
# Profile name set in UCI as 'nikki-config' (see 35-nikki.sh module)
_NK_PROF_DIR="$TARGET_DIR/package/base-files/files/etc/nikki/profiles"
mkdir -p "$_NK_PROF_DIR"
# Nikki proxy-provider 本地订阅目录，与 nikki-config.yaml 内 path 一致：
#   /etc/nikki/run/providers/cc-auto.yaml
mkdir -p "$TARGET_DIR/package/base-files/files/etc/nikki/run/providers"
_NK_YAML_SRC="$GITHUB_WORKSPACE/nikki-config.yaml"
if [ -f "$_NK_YAML_SRC" ]; then
    cp -f "$_NK_YAML_SRC" "$_NK_PROF_DIR/nikki-config.yaml"
    echo "[build-openclash] Nikki profile installed → $_NK_PROF_DIR/nikki-config.yaml"
else
    echo "[build-openclash] WARNING: nikki-config.yaml not found, skipping"
fi

# ── 1c. Inject subscription URL into Nikki / HomeProxy ───────
# OpenClash proxy-providers URL is a fixed localhost placeholder (no injection needed).
# Nikki and HomeProxy still use __CLASH_SUB_URL__ placeholders.
_inject_sub_url() {
    _isu_file="$1"
    [ -f "$_isu_file" ] || return 0
    if [ -n "${CLASH_SUB_URL:-}" ]; then
        _isu_esc=$(printf '%s' "$CLASH_SUB_URL" | sed -e 's/[&|\\]/\\&/g')
        sed -i "s|__CLASH_SUB_URL__|$_isu_esc|g" "$_isu_file"
        echo "[build-openclash] Subscription URL injected → $_isu_file"
    else
        echo "[build-openclash] NOTE: CLASH_SUB_URL not set — placeholder kept in $_isu_file"
    fi
}
_inject_sub_url "$_NK_PROF_DIR/nikki-config.yaml"
_inject_sub_url "$TARGET_DIR/package/base-files/files/usr/lib/wyhome/modules/36-homeproxy.sh"

# ── 2. Pre-download Clash Meta core (vernesong/OpenClash) ─────
# Download the OpenClash-packaged Meta core (compatible/v1 build) so the
# binary is already in place when the firmware is flashed.
# Source: vernesong/OpenClash releases — same Meta core the OpenClash team
# tests and ships, ensuring version compatibility with OpenClash scripts.
# UCI: core_type=Meta / core_version=linux-amd64-v1 → binary: clash_meta
_CORE_DIR="$TARGET_DIR/package/base-files/files/etc/openclash/core"
mkdir -p "$_CORE_DIR"

echo "[build-openclash] Fetching OpenClash Meta core URL from vernesong/OpenClash releases..."
_OC_CORE_URL=$(curl -fsSL \
    -H "Accept: application/vnd.github.v3+json" \
    ${GITHUB_TOKEN:+-H "Authorization: token $GITHUB_TOKEN"} \
    "https://api.github.com/repos/vernesong/OpenClash/releases?per_page=30" \
    | jq -r '[.[].assets[].browser_download_url
              | select(test("clash_meta-linux-amd64-compatible\\.gz$"))]
             | first // ""')

if [ -n "$_OC_CORE_URL" ]; then
    echo "[build-openclash] Downloading OpenClash Meta core: $_OC_CORE_URL"
    rm -f /tmp/clash_meta.gz /tmp/clash_meta
    if curl -fsSL -o /tmp/clash_meta.gz "$_OC_CORE_URL" && \
       gzip -d /tmp/clash_meta.gz && \
       mv /tmp/clash_meta "$_CORE_DIR/clash_meta" && \
       chmod +x "$_CORE_DIR/clash_meta"; then
        echo "[build-openclash] OpenClash Meta core installed → $_CORE_DIR/clash_meta"
    else
        rm -f /tmp/clash_meta.gz /tmp/clash_meta
        echo "[build-openclash] WARNING: Core download/extraction failed — OpenClash will auto-download core at runtime"
    fi
else
    echo "[build-openclash] WARNING: No matching asset found in vernesong/OpenClash releases"
    echo "[build-openclash] OpenClash will auto-download the Meta core at first boot"
fi

# Clean up temp vars (sourced into parent scope)
unset _OC_CFG_DIR _OC_PROV_DIR _YAML_SRC _CORE_DIR _NK_PROF_DIR _NK_YAML_SRC
unset _OC_CORE_URL _isu_file _isu_esc
unset -f _inject_sub_url 2>/dev/null || true
