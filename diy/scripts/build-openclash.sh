#!/bin/bash
# =============================================================
# Build script: build-openclash.sh
# Scope:  Build-time only — NOT installed into the firmware image
# Called: Sourced from diy-part2.sh (inherits TARGET_DIR, GITHUB_WORKSPACE, etc.)
#
# Actions:
#   1. Copy clash-all-noicon-clash.yaml into the image
#   2. Pre-download Clash Meta core from OpenClash core branch
#      (same source OpenClash LuCI uses for auto-download)
#      so OpenClash works immediately after flashing.
#
# Core branch: https://github.com/vernesong/OpenClash/tree/core
#   meta/clash-linux-amd64.tar.gz     → amd64-v1 (compatible, broadest support)
#   meta/clash-linux-amd64-v3.tar.gz  → amd64-v3 (AVX2, newer CPUs only)
#
# UCI core_version=linux-amd64-v1 → clash-linux-amd64.tar.gz (compatible build)
# Binary inside tar: named "clash", installed as /etc/openclash/core/clash_meta
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

# ── 2. Pre-download Clash Meta core from OpenClash core branch ─
# OpenClash LuCI downloads from this exact URL when core is missing.
# Using the same source ensures version compatibility.
_CORE_DIR="$TARGET_DIR/package/base-files/files/etc/openclash/core"
mkdir -p "$_CORE_DIR"

# OpenClash core branch base URL
_OC_CORE_BASE="https://github.com/vernesong/OpenClash/raw/core/meta"

# Primary: amd64-v1 (compatible build — broadest x86_64 support,
# works without SSE4.2/AVX2, covers Intel 4th gen and all modern AMD in PVE)
_OC_CORE_URL="$_OC_CORE_BASE/clash-linux-amd64.tar.gz"

# Fallback: upstream MetaCubeX mihomo compatible build
_MIHOMO_FALLBACK_URL=""
_MIHOMO_VER=$(curl -fsSL \
    -H "Accept: application/vnd.github.v3+json" \
    ${GITHUB_TOKEN:+-H "Authorization: token $GITHUB_TOKEN"} \
    "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" \
    2>/dev/null | grep '"tag_name"' | head -1 | cut -d'"' -f4)
[ -n "$_MIHOMO_VER" ] && \
    _MIHOMO_FALLBACK_URL="https://github.com/MetaCubeX/mihomo/releases/download/$_MIHOMO_VER/mihomo-linux-amd64-compatible-$_MIHOMO_VER.gz"

_install_core_from_tar() {
    local url="$1" label="$2"
    echo "[build-openclash] Trying $label (tar.gz): $url"
    rm -f /tmp/clash_core.tar.gz /tmp/clash_core_extracted
    if curl -fsSL -o /tmp/clash_core.tar.gz "$url"; then
        # Extract binary named "clash" from tar.gz
        if tar -xzf /tmp/clash_core.tar.gz -C /tmp/ 2>/dev/null; then
            # Find the extracted binary (may be named "clash" or similar)
            local _bin
            _bin=$(find /tmp/ -maxdepth 1 -name "clash" -o -name "mihomo" 2>/dev/null | head -1)
            if [ -n "$_bin" ]; then
                mv "$_bin" "$_CORE_DIR/clash_meta"
                chmod +x "$_CORE_DIR/clash_meta"
                rm -f /tmp/clash_core.tar.gz
                echo "[build-openclash] Core ($label) installed → $_CORE_DIR/clash_meta"
                return 0
            fi
        fi
    fi
    rm -f /tmp/clash_core.tar.gz
    echo "[build-openclash] WARNING: $label failed"
    return 1
}

_install_core_from_gz() {
    local url="$1" label="$2"
    echo "[build-openclash] Trying $label (gz): $url"
    rm -f /tmp/clash_meta.gz /tmp/clash_meta
    if curl -fsSL -o /tmp/clash_meta.gz "$url" && \
       gzip -d /tmp/clash_meta.gz && \
       mv /tmp/clash_meta "$_CORE_DIR/clash_meta" && \
       chmod +x "$_CORE_DIR/clash_meta"; then
        echo "[build-openclash] Core ($label) installed → $_CORE_DIR/clash_meta"
        rm -f /tmp/clash_meta.gz
        return 0
    fi
    rm -f /tmp/clash_meta.gz /tmp/clash_meta
    echo "[build-openclash] WARNING: $label failed"
    return 1
}

echo "[build-openclash] Downloading Clash Meta core..."
_install_core_from_tar "$_OC_CORE_URL" "OpenClash/core amd64-v1" \
|| { [ -n "$_MIHOMO_FALLBACK_URL" ] && \
     _install_core_from_gz "$_MIHOMO_FALLBACK_URL" "MetaCubeX mihomo compatible fallback"; } \
|| echo "[build-openclash] WARNING: All downloads failed — OpenClash will auto-download core at runtime"

# Clean up temp vars from parent scope
unset _OC_CFG_DIR _OC_PROV_DIR _YAML_SRC _CORE_DIR _NK_PROF_DIR _NK_YAML_SRC
unset _OC_CORE_BASE _OC_CORE_URL _MIHOMO_VER _MIHOMO_FALLBACK_URL
unset -f _install_core_from_tar _install_core_from_gz 2>/dev/null || true

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
unset _OC_CFG_DIR _OC_PROV_DIR _YAML_SRC _CORE_DIR _MIHOMO_VER _BASE
unset -f _try_download_core 2>/dev/null || true

