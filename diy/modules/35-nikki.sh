#!/bin/sh
# =============================================================
# Module: 35-nikki.sh
# Scope:  Nikki (luci-app-nikki / mihomo) UCI pre-configuration
# Runs:   First boot via zzz-default-settings orchestrator
#
# Purpose: Set nikki UCI values to use our pre-installed profile
#          and prevent the UI from overwriting critical settings.
#          Config mirrors clash-all-noicon-clash.yaml logic exactly.
# =============================================================

[ -f /etc/init.d/nikki ] || {
    echo "[35-nikki] nikki not installed — skipping"
    return 0 2>/dev/null || exit 0
}

# --- Use custom profile (disable UI config generation) ---
# nikki reads profile from /etc/nikki/profiles/ when profile_name is set.
# This prevents the web UI from generating and overwriting the yaml.
uci set nikki.config=config
uci set nikki.config.enabled='0'
uci set nikki.config.profile_name='nikki-config'

# --- Operation mode: tproxy (same as OpenClash) ---
uci set nikki.proxy=proxy
uci set nikki.proxy.mode='tproxy'
uci set nikki.proxy.ipv6='1'
uci set nikki.proxy.tcp_transparent_proxy_mode='tproxy'
uci set nikki.proxy.udp_transparent_proxy_mode='tproxy'

# --- DNS ---
uci set nikki.proxy.dns_mode='redir_host'
uci set nikki.proxy.dns_port='7884'

# --- Performance: China IP bypass ---
uci set nikki.proxy.bypass_china_mainland_ip='1'

# --- Router self proxy ---
uci set nikki.proxy.router_proxy='1'

# --- Ports (OpenClash +10, avoid conflict) ---
uci set nikki.proxy.http_port='7900'
uci set nikki.proxy.socks_port='7901'
uci set nikki.proxy.mixed_port='7903'
uci set nikki.proxy.redir_port='7902'
uci set nikki.proxy.tproxy_port='7905'

# --- API ---
uci set nikki.api=api
uci set nikki.api.port='9091'
uci set nikki.api.secret='nk_7Xm2pQ9wR4tK8vL1nJ6cF3bA5yD0e'

# --- Disable auto-start (user switches between OpenClash and Nikki manually) ---
# Only one can run at a time (both use same ports + tproxy)
uci set nikki.config.enabled='0'

uci commit nikki
echo "[35-nikki] UCI pre-configured — profile: nikki-config (disabled by default)"
echo "[35-nikki] To activate: disable OpenClash first, then enable nikki"


