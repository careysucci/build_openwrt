#!/bin/sh
# =============================================================
# oc-bootstrap.sh — First-time OpenClash setup helper
# Installed at: /usr/lib/wyhome/oc-bootstrap.sh
#
# Usage:
#   oc-bootstrap.sh <subscription_url>
#
# What it does:
#   Downloads a subscription and saves it as the proxy-provider
#   cache file that mihomo reads. No format validation is performed.
#   OpenClash must be DISABLED while running this (default on first boot).
#
# After running, enable OpenClash:
#   uci set openclash.config.enable=1 && uci commit openclash
#   /etc/init.d/openclash enable && /etc/init.d/openclash start
# =============================================================

PROVIDER_PATH="/etc/openclash/config/providers/cc-auto.yaml"
SUB_URL="${1:-}"

_print_usage() {
    echo "Usage: $0 <subscription_url>"
    echo ""
    echo "Example:"
    echo "  $0 'https://your-airport.com/api/subscribe?token=xxx'"
    echo ""
    echo "Requirements:"
    echo "  - OpenClash must be DISABLED (it is by default on first boot)"
    echo "  - No format validation is performed — a Clash-format subscription"
    echo "    is recommended (some providers need ?client_type=clash)"
    echo ""
    echo "After running this script, enable OpenClash:"
    echo "  uci set openclash.config.enable=1 && uci commit openclash"
    echo "  /etc/init.d/openclash enable && /etc/init.d/openclash start"
    echo ""
    echo "Alternatively, use OpenClash UI → 订阅设置 to manage subscriptions,"
    echo "then set the subscription to enabled and restart OpenClash."
}

if [ -z "$SUB_URL" ]; then
    _print_usage
    exit 1
fi

# Check if OpenClash is running (warn but don't abort)
if /etc/init.d/openclash status 2>/dev/null | grep -q "running"; then
    echo "[oc-bootstrap] WARNING: OpenClash appears to be running."
    echo "[oc-bootstrap] Stop it first to avoid race conditions:"
    echo "  /etc/init.d/openclash stop"
    echo "[oc-bootstrap] Continuing anyway..."
    echo ""
fi

echo "[oc-bootstrap] Downloading subscription from: $SUB_URL"
echo "[oc-bootstrap] Target: $PROVIDER_PATH"
echo ""

mkdir -p "$(dirname "$PROVIDER_PATH")"

TMP_FILE="/tmp/oc_bootstrap_$$.yaml"

if ! curl -fsSL --connect-timeout 30 --max-time 120 "$SUB_URL" -o "$TMP_FILE"; then
    rm -f "$TMP_FILE"
    echo "[oc-bootstrap] ERROR: Download failed."
    echo "  Check network connectivity and the subscription URL."
    echo "  Try: curl -v '$SUB_URL'"
    exit 1
fi

# 说明：不强制校验内容格式，下载到什么就写入什么。
PROXY_COUNT=$(grep -c "^  - " "$TMP_FILE" 2>/dev/null || echo 0)
cp "$TMP_FILE" "$PROVIDER_PATH"
rm -f "$TMP_FILE"
echo "[oc-bootstrap] ✓ Success: $PROXY_COUNT node entries imported"
echo "[oc-bootstrap] ✓ Provider file saved: $PROVIDER_PATH"
echo ""
echo "Now enable and start OpenClash:"
echo "  uci set openclash.config.enable=1 && uci commit openclash"
echo "  /etc/init.d/openclash enable && /etc/init.d/openclash start"
echo ""
echo "Then open the OpenClash dashboard to verify nodes appear:"
echo "  http://$(uci get network.lan.ipaddr 2>/dev/null || echo '172.16.3.18'):9090/ui/"

