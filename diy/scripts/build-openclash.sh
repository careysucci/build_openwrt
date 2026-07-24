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
#   2. Pre-download Clash Meta core (multiple fallback sources):
#      a. vernesong/OpenClash releases (clash_meta-linux-amd64-compatible.gz / v1 variant)
#      b. MetaCubeX/mihomo releases    (mihomo-linux-amd64-compatible-v*.gz, renamed)
#      Binary installed as /etc/openclash/core/clash_meta
#   3. Install oc-bootstrap.sh helper for first-time node setup
#
# Binary path in firmware: /etc/openclash/core/clash_meta
# Note: UCI core_type/core_version are no longer pre-set — OpenClash
#       defaults apply (see diy/modules/30-openclash.sh).
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

# ── 1c. Inject subscription URL into HomeProxy only ──────────
# OpenClash: uses fixed localhost placeholder → no injection needed.
# Nikki:     uses fixed localhost placeholder → no injection needed.
# HomeProxy: 36-homeproxy.sh uses __CLASH_SUB_URL__ in a case() statement
#            that gracefully handles both injected and not-injected states.
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
_inject_sub_url "$TARGET_DIR/package/base-files/files/usr/lib/wyhome/modules/36-homeproxy.sh"

# ── 2. Pre-download Clash Meta core ──────────────────────────
# Pre-bundle the clash_meta binary so OpenClash works immediately after
# flashing, even without internet access.
#
# Without a pre-bundled core, OpenClash auto-downloads it at first boot.
# This fails when the router needs a proxy to reach GitHub but can't start
# the proxy without the core — a classic chicken-and-egg deadlock.
#
# Source priority:
#   1. vernesong/OpenClash releases (official OpenClash distribution, broadest compat)
#      Patterns tried: clash_meta-linux-amd64-compatible.gz, clash_meta-linux-amd64-v1.gz
#   2. MetaCubeX/mihomo releases (upstream mihomo, renamed to clash_meta)
#      Pattern: mihomo-linux-amd64-compatible-v*.gz
#
# Binary installed as: /etc/openclash/core/clash_meta
# (UCI core_type/core_version not pre-set — OpenClash defaults apply)
_CORE_DIR="$TARGET_DIR/package/base-files/files/etc/openclash/core"
mkdir -p "$_CORE_DIR"

# Helper: download + decompress a .gz URL → $1 target path
# Returns 0 on success, 1 on failure.
_oc_fetch_core() {
    local _url="$1"
    local _dest="$2"
    local _label="$3"
    local _tmpgz
    _tmpgz="/tmp/oc_core_$$.gz"

    echo "[build-openclash] Downloading: $_label"
    echo "[build-openclash]   URL: $_url"
    rm -f "$_tmpgz"

    if curl -fsSL --connect-timeout 30 --max-time 300 \
            ${GITHUB_TOKEN:+-H "Authorization: token $GITHUB_TOKEN"} \
            -o "$_tmpgz" "$_url"; then
        # Decompress to stdout → avoids dealing with extracted filename
        if gunzip -c "$_tmpgz" > "$_dest" 2>/dev/null && [ -s "$_dest" ]; then
            chmod +x "$_dest"
            local _sz
            _sz=$(du -k "$_dest" | cut -f1)
            echo "[build-openclash] ✓ Core installed (${_sz}KB): $_dest"
            rm -f "$_tmpgz"
            return 0
        else
            echo "[build-openclash] ✗ Decompression failed for $_label"
        fi
    else
        echo "[build-openclash] ✗ Download failed for $_label"
    fi

    rm -f "$_tmpgz" "$_dest"
    return 1
}

# Helper: query GitHub releases API and find the first asset matching a pattern
# Usage: _oc_find_asset <repo> <pattern>  → prints URL or empty string
_oc_find_asset() {
    local _repo="$1"
    local _pat="$2"
    local _api_url="https://api.github.com/repos/${_repo}/releases?per_page=10"
    curl -fsSL \
        -H "Accept: application/vnd.github.v3+json" \
        ${GITHUB_TOKEN:+-H "Authorization: token $GITHUB_TOKEN"} \
        "$_api_url" 2>/dev/null \
    | jq -r --arg pat "$_pat" \
        '[.[].assets[].browser_download_url | select(test($pat))] | first // ""' \
        2>/dev/null || true
}

# Helper: query the /releases/latest endpoint (single release)
_oc_find_asset_latest() {
    local _repo="$1"
    local _pat="$2"
    local _api_url="https://api.github.com/repos/${_repo}/releases/latest"
    curl -fsSL \
        -H "Accept: application/vnd.github.v3+json" \
        ${GITHUB_TOKEN:+-H "Authorization: token $GITHUB_TOKEN"} \
        "$_api_url" 2>/dev/null \
    | jq -r --arg pat "$_pat" \
        '[.assets[].browser_download_url | select(test($pat))] | first // ""' \
        2>/dev/null || true
}

_CORE_DEST="$_CORE_DIR/clash_meta"
_CORE_INSTALLED=0

echo "[build-openclash] ── Fetching OpenClash Meta core ───────────────────────────"

# ── Source 1: vernesong/OpenClash releases ────────────────────
# Try the compatible (broadest x86_64) variant first, then v1
for _OC_PAT in \
    "clash_meta-linux-amd64-compatible\\.gz$" \
    "clash_meta-linux-amd64-v1\\.gz$" \
    "clash-meta-linux-amd64-compatible\\.gz$"; do

    echo "[build-openclash] Searching vernesong/OpenClash (pattern: $_OC_PAT)..."
    _OC_CORE_URL=$(_oc_find_asset "vernesong/OpenClash" "$_OC_PAT")

    if [ -n "$_OC_CORE_URL" ]; then
        if _oc_fetch_core "$_OC_CORE_URL" "$_CORE_DEST" "vernesong/OpenClash [$_OC_PAT]"; then
            _CORE_INSTALLED=1
            break
        fi
    else
        echo "[build-openclash] No asset found for pattern: $_OC_PAT"
    fi
done

# ── Source 2: MetaCubeX/mihomo releases (fallback) ────────────
if [ "$_CORE_INSTALLED" -eq 0 ]; then
    echo "[build-openclash] Falling back to MetaCubeX/mihomo releases..."

    for _MH_PAT in \
        "mihomo-linux-amd64-compatible-v.*\\.gz$" \
        "mihomo-linux-amd64-compatible\\.gz$"; do

        echo "[build-openclash] Searching MetaCubeX/mihomo/releases/latest (pattern: $_MH_PAT)..."
        _MH_CORE_URL=$(_oc_find_asset_latest "MetaCubeX/mihomo" "$_MH_PAT")

        # Also try full releases list if latest doesn't have it
        if [ -z "$_MH_CORE_URL" ]; then
            _MH_CORE_URL=$(_oc_find_asset "MetaCubeX/mihomo" "$_MH_PAT")
        fi

        if [ -n "$_MH_CORE_URL" ]; then
            if _oc_fetch_core "$_MH_CORE_URL" "$_CORE_DEST" "MetaCubeX/mihomo [$_MH_PAT]"; then
                _CORE_INSTALLED=1
                echo "[build-openclash] Note: mihomo binary installed as clash_meta (compatible rename)"
                break
            fi
        else
            echo "[build-openclash] No asset found for pattern: $_MH_PAT"
        fi
    done
fi

# ── Result ─────────────────────────────────────────────────────
if [ "$_CORE_INSTALLED" -eq 1 ]; then
    echo "[build-openclash] ✓ Core pre-bundled: $_CORE_DEST"
    # Quick sanity check: ELF header
    if od -A n -t x1 -N 4 "$_CORE_DEST" 2>/dev/null | grep -qi "7f 45 4c 46"; then
        echo "[build-openclash] ✓ ELF binary verified"
    else
        echo "[build-openclash] WARNING: Binary does not appear to be ELF — may be corrupt"
    fi
else
    echo "[build-openclash] ✗ WARNING: Core download failed from ALL sources."
    echo "[build-openclash]   OpenClash will auto-download the core at first boot."
    echo "[build-openclash]   This requires internet access WITHOUT a proxy on first boot."
    echo "[build-openclash]   If your router needs a proxy to reach GitHub, manual"
    echo "[build-openclash]   core installation may be required after flashing."
fi

# ── 3. Install helper scripts ─────────────────────────────────
# a) setup-openclash.sh → /root/setup-openclash.sh
#    One-shot first-boot script: downloads subscription, updates YAML URL,
#    enables and starts OpenClash.  User runs: ./setup-openclash.sh <url>
_SETUP_SRC="$GITHUB_WORKSPACE/diy/scripts/setup-openclash.sh"
_SETUP_DST="$TARGET_DIR/package/base-files/files/root/setup-openclash.sh"
mkdir -p "$(dirname "$_SETUP_DST")"
if [ -f "$_SETUP_SRC" ]; then
    cp -f "$_SETUP_SRC" "$_SETUP_DST"
    chmod +x "$_SETUP_DST"
    echo "[build-openclash] Setup script installed: /root/setup-openclash.sh"
else
    echo "[build-openclash] WARNING: setup-openclash.sh not found at $_SETUP_SRC — skipping"
fi

# b) setup-nikki.sh → /root/setup-nikki.sh
#    Same as setup-openclash.sh but for Nikki (alternative proxy engine).
#    Also stops OpenClash before starting Nikki (mutual exclusion).
_SETUP_NK_SRC="$GITHUB_WORKSPACE/diy/scripts/setup-nikki.sh"
_SETUP_NK_DST="$TARGET_DIR/package/base-files/files/root/setup-nikki.sh"
if [ -f "$_SETUP_NK_SRC" ]; then
    cp -f "$_SETUP_NK_SRC" "$_SETUP_NK_DST"
    chmod +x "$_SETUP_NK_DST"
    echo "[build-openclash] Setup script installed: /root/setup-nikki.sh"
else
    echo "[build-openclash] WARNING: setup-nikki.sh not found at $_SETUP_NK_SRC — skipping"
fi

# c) oc-bootstrap.sh → /usr/lib/wyhome/oc-bootstrap.sh
#    Lightweight variant (cache-only, no YAML modification).
_BOOTSTRAP_SRC="$GITHUB_WORKSPACE/diy/scripts/oc-bootstrap.sh"
_BOOTSTRAP_DST="$TARGET_DIR/package/base-files/files/usr/lib/wyhome/oc-bootstrap.sh"
mkdir -p "$(dirname "$_BOOTSTRAP_DST")"
if [ -f "$_BOOTSTRAP_SRC" ]; then
    cp -f "$_BOOTSTRAP_SRC" "$_BOOTSTRAP_DST"
    chmod +x "$_BOOTSTRAP_DST"
    echo "[build-openclash] Bootstrap helper installed: /usr/lib/wyhome/oc-bootstrap.sh"
else
    echo "[build-openclash] WARNING: oc-bootstrap.sh not found at $_BOOTSTRAP_SRC — skipping"
fi

# Clean up temp vars and functions (sourced into parent scope)
unset _OC_CFG_DIR _OC_PROV_DIR _YAML_SRC _CORE_DIR _CORE_DEST _CORE_INSTALLED
unset _NK_PROF_DIR _NK_YAML_SRC _SETUP_SRC _SETUP_DST _SETUP_NK_SRC _SETUP_NK_DST
unset _BOOTSTRAP_SRC _BOOTSTRAP_DST
unset _OC_CORE_URL _OC_PAT _MH_CORE_URL _MH_PAT
unset -f _oc_fetch_core _oc_find_asset _oc_find_asset_latest _inject_sub_url 2>/dev/null || true
