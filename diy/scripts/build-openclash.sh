#!/bin/bash
# =============================================================
# Build script: build-openclash.sh
# Scope:  Build-time only — NOT installed into the firmware image
# Called: Sourced from diy-part2.sh (inherits TARGET_DIR, GITHUB_WORKSPACE, etc.)
#
# Actions:
#   1. Copy clash-all-noicon-clash.yaml into the image
#   1b. Copy nikki-config.yaml into the image
#   2. Pre-download Clash Meta core from MetaCubeX/mihomo releases
#      so OpenClash works immediately after flashing.
#
# Core source: https://github.com/MetaCubeX/mihomo/releases
#   mihomo-linux-amd64-compatible → amd64-v1 (broadest x86_64 support)
#   mihomo-linux-amd64            → standard (may require newer CPU features)
#
# UCI core_version=linux-amd64-v1 → compatible build
# Binary installed as /etc/openclash/core/clash_meta
# =============================================================

# ── 1. Install OpenClash YAML config ─────────────────────────
_OC_CFG_DIR="$TARGET_DIR/package/base-files/files/etc/openclash/config"
_OC_PROV_DIR="$TARGET_DIR/package/base-files/files/etc/openclash/providers"
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
_NK_YAML_SRC="$GITHUB_WORKSPACE/nikki-config.yaml"
if [ -f "$_NK_YAML_SRC" ]; then
    cp -f "$_NK_YAML_SRC" "$_NK_PROF_DIR/nikki-config.yaml"
    echo "[build-openclash] Nikki profile installed → $_NK_PROF_DIR/nikki-config.yaml"
else
    echo "[build-openclash] WARNING: nikki-config.yaml not found, skipping"
fi

# ── 2. Pre-download Clash Meta (mihomo) core ─────────────────
# Compatible build: broadest x86_64 support (no SSE4.2/AVX2 requirement).
# Covers Intel 4th gen (4560T) and all modern AMD CPUs running in PVE KVM.
# OpenClash UCI core_version=linux-amd64-v1 → expects binary named: clash_meta
_CORE_DIR="$TARGET_DIR/package/base-files/files/etc/openclash/core"
mkdir -p "$_CORE_DIR"

echo "[build-openclash] Fetching latest mihomo release tag..."
_MIHOMO_VER=$(curl -fsSL \
    -H "Accept: application/vnd.github.v3+json" \
    ${GITHUB_TOKEN:+-H "Authorization: token $GITHUB_TOKEN"} \
    "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" \
    | grep '"tag_name"' | head -1 | cut -d'"' -f4)

_try_download_core() {
    local url="$1" label="$2"
    echo "[build-openclash] Trying $label: $url"
    rm -f /tmp/clash_meta.gz /tmp/clash_meta
    if curl -fsSL -o /tmp/clash_meta.gz "$url"; then
        if gzip -d /tmp/clash_meta.gz && \
           mv /tmp/clash_meta "$_CORE_DIR/clash_meta" && \
           chmod +x "$_CORE_DIR/clash_meta"; then
            echo "[build-openclash] Core $_MIHOMO_VER ($label) installed → $_CORE_DIR/clash_meta"
            return 0
        fi
    fi
    rm -f /tmp/clash_meta.gz /tmp/clash_meta
    echo "[build-openclash] WARNING: $label download failed"
    return 1
}

if [ -n "$_MIHOMO_VER" ]; then
    echo "[build-openclash] Latest mihomo: $_MIHOMO_VER"
    _BASE="https://github.com/MetaCubeX/mihomo/releases/download/$_MIHOMO_VER"
    _try_download_core \
        "$_BASE/mihomo-linux-amd64-compatible-$_MIHOMO_VER.gz" \
        "amd64-compatible (v1)" \
    || _try_download_core \
        "$_BASE/mihomo-linux-amd64-$_MIHOMO_VER.gz" \
        "amd64-standard" \
    || echo "[build-openclash] WARNING: All downloads failed — OpenClash will auto-download core at runtime"
else
    echo "[build-openclash] WARNING: Could not determine mihomo version — core will be downloaded at runtime"
fi

# Clean up temp vars (sourced into parent scope)
unset _OC_CFG_DIR _OC_PROV_DIR _YAML_SRC _CORE_DIR _NK_PROF_DIR _NK_YAML_SRC
unset _MIHOMO_VER _BASE
unset -f _try_download_core 2>/dev/null || true

