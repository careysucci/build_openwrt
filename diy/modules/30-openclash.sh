#!/bin/sh
# =============================================================
# Module: 30-openclash.sh
# Scope:  OpenClash UCI pre-configuration
# Runs:   First boot via zzz-default-settings orchestrator
#
# Purpose: Keep OpenClash UCI values consistent with
#          /etc/openclash/config/clash-all-noicon-clash.yaml.
#          Without this, the LuCI web UI writes default UCI
#          values on first access and overwrites YAML settings.
#
# Reference YAML: clash-all-noicon-clash.yaml (project root)
# =============================================================

[ -f /etc/init.d/openclash ] || {
    echo "[30-openclash] openclash not installed — skipping"
    return 0 2>/dev/null || exit 0
}

# ── Config file path ──────────────────────────────────────────
uci set openclash.config.config_path='/etc/openclash/config/clash-all-noicon-clash.yaml'

# ── Operation mode ────────────────────────────────────────────
# yaml: enhanced-mode: redir-host
uci set openclash.config.operation_mode='redir-host'
uci set openclash.config.en_mode='redir-host'
uci set openclash.config.proxy_mode='rule'

# ── Ports ─────────────────────────────────────────────────────
# yaml: port/socks-port/redir-port/mixed-port/tproxy-port/dns.listen/external-controller
uci set openclash.config.http_port='7890'
uci set openclash.config.socks_port='7891'
uci set openclash.config.proxy_port='7892'
uci set openclash.config.mixed_port='7893'
uci set openclash.config.tproxy_port='7895'
uci set openclash.config.dns_port='7874'
uci set openclash.config.cn_port='9090'

# ── IPv6 ──────────────────────────────────────────────────────
# yaml: ipv6: true, dns.ipv6: true
uci set openclash.config.ipv6_enable='1'
uci set openclash.config.ipv6_dns='1'

# ── respect-rules ─────────────────────────────────────────────
# yaml: respect-rules: false
# Disabled for performance: prevents double rule-matching per DNS query.
# .6 AdGuardHome upstream traffic is protected by nftables tproxy (kernel layer).
uci set openclash.config.enable_respect_rules='0'

# ── DNS: fully controlled by yaml ─────────────────────────────
# Disable all UI DNS overrides; nameserver/policy defined in yaml only.
uci set openclash.config.enable_custom_dns='0'
uci set openclash.config.enable_custom_clash_rules='0'
uci set openclash.config.enable_custom_domain_dns_server='0'
uci set openclash.config.append_wan_dns='0'
uci set openclash.config.append_default_dns='0'

# ── DNS redirection (CRITICAL for requirement 8: all DNS → .7/.6) ──
# enable_redirect_dns=1: OpenClash hijacks ALL port 53 traffic on the router
# to Clash DNS (port 7874). This ensures every client query passes through
# Clash's nameserver-policy, splitting CN→.7 and foreign→.6 correctly.
# Without this, dnsmasq may use ISP DNS directly → breaks ad blocking + leaks DNS.
uci set openclash.config.enable_redirect_dns='1'
uci set openclash.config.redirect_dns='1'

# Prevent dnsmasq from also querying ISP DNS (resolv.conf.auto contains ISP servers).
# When noresolv=1, dnsmasq ONLY uses the server set by OpenClash (127.0.0.1#7874),
# guaranteeing all queries flow: client → dnsmasq → Clash DNS → .7/.6 AdGuardHome.
uci set openclash.config.dnsmasq_noresolv='1'

# ── Router self proxy ─────────────────────────────────────────
# Route the router's own outbound traffic through Clash rules.
uci set openclash.config.router_self_proxy='1'

    # --- Performance ───────────────────────────────────────────────
    # yaml: tcp-concurrent: true
    uci set openclash.config.disable_udp_quic='1'
    uci set openclash.config.cachesize_dns='1'
    uci set openclash.config.disable_masq_cache='1'

    # --- China IP bypass (CRITICAL for 2000Mbps) ──────────────────
    # When enabled: OpenClash adds all China IPs to an nftables bypass set.
    # Packets destined to China IPs are RETURNED from tproxy chain BEFORE
    # reaching Clash userspace → kernel-speed forwarding → full 2000Mbps.
    # Chinese speedtest/download traffic never enters Clash process.
    uci set openclash.config.china_ip_route='1'

    # --- Bypass LAN (performance) ─────────────────────────────────
    # skip_proxy_address=0: DISABLE automatic address bypass.
    # When enabled, OpenClash may add nftables bypass rules for DNS server IPs
    # (including .6), causing .6's upstream traffic (8.8.4.4) to go DIRECT → timeout.
    # We handle bypass manually via yaml rules (SRC-IP-CIDR for .7 DIRECT, .6 proxy).
    uci set openclash.config.bypass_gateway_compatible='0'
    uci set openclash.config.skip_proxy_address='0'

# ── TUN / stack ───────────────────────────────────────────────
# yaml: tun.enable: false  (tproxy-only mode, TUN disabled)
# stack_type retained for reference; TUN is disabled in yaml.
uci set openclash.config.stack_type='system'

# ── Core: Meta (mihomo) ───────────────────────────────────────
# linux-amd64-v1 = compatible build (broadest x86_64 support,
# works without SSE4.2/AVX2; covers Intel 4th gen and all modern AMD).
uci set openclash.config.core_type='Meta'
uci set openclash.config.core_version='linux-amd64-v1'

# ── Logging ───────────────────────────────────────────────────
# yaml: log-level: warning → OpenClash UI level 0
uci set openclash.config.log_level='0'

# ── GEO database auto-update ──────────────────────────────────
# Update every Monday at 01:00
uci set openclash.config.geo_auto_update='1'
uci set openclash.config.geoip_auto_update='1'
uci set openclash.config.geosite_auto_update='1'
uci set openclash.config.geoasn_auto_update='1'
uci set openclash.config.geo_update_week_time='1'
uci set openclash.config.geo_update_day_time='1'

# ── Dashboard ─────────────────────────────────────────────────
# yaml: external-ui-name: metacubed → metacubexd
uci set openclash.config.dashboard_type='Official'
uci set openclash.config.yacd_type='Meta'

uci commit openclash
echo "[30-openclash] UCI pre-configured to match clash-all-noicon-clash.yaml"

