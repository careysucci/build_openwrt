#!/bin/sh
# =============================================================
# Module: 36-homeproxy.sh
# Scope:  luci-app-homeproxy (sing-box) UCI pre-configuration
# Runs:   First boot via zzz-default-settings orchestrator
#
# Purpose: Provide a ready-to-use homeproxy profile whose behaviour
#          mirrors clash-all-noicon-clash.yaml:
#            - 国内(China) IP/域名 直连  → 保障国内直连网速
#            - 其余流量            走代理 → YouTube 等国外站点走代理
#            - DNS 仅用内网 AdGuardHome (无 DNS 泄漏, 不碰 ISP/公网 DNS)
#                * 国内域名 → 172.16.3.7
#                * 国外域名 → 172.16.3.6  (广告过滤 + 外国解析)
#            - 默认路由 = 代理 → 无 IP 泄漏
#
# SAFETY: homeproxy is DISABLED by default (main_node='nil' + service
#         disabled). Only ONE transparent proxy can own tproxy at a time;
#         OpenClash stays primary. Enabling homeproxy NEVER happens
#         automatically, so the shipped network config / 网速 is untouched.
#
# UI consistency: everything is written to /etc/config/homeproxy — the same
#         UCI the LuCI page reads, so the web UI always matches this file.
#
# Subscription URL is injected at build time from CLASH_SUB_URL
# (see build-openclash.sh). Placeholder below: __CLASH_SUB_URL__
# =============================================================

[ -f /etc/init.d/homeproxy ] || {
    echo "[36-homeproxy] homeproxy not installed — skipping"
    return 0 2>/dev/null || exit 0
}

# Internal AdGuardHome split-DNS endpoints (LAN, reached directly)
_HP_DNS_CN='172.16.3.7'      # 国内 AdGuardHome (上游: 223.5.5.5 / 119.29.29.29)
_HP_DNS_FOREIGN='172.16.3.6' # 国外 AdGuardHome (上游: DoH 1.1.1.1 / 8.8.8.8 / 9.9.9.9)

# ── Main config section ───────────────────────────────────────
uci set homeproxy.config=homeproxy

# Transparent proxy mode: TPROXY (same kernel-layer approach as OpenClash/Nikki)
uci set homeproxy.config.proxy_mode='redirect_tproxy'
# Only proxy common ports → P2P/未知端口直连, reduces overhead (国内网速友好)
uci set homeproxy.config.routing_port='common'

# Routing: bypass China mainland → CN IP/域名直连, 其余走代理.
# This is the kernel/route-level equivalent of clash 的 China/IP+China/Domain DIRECT
# 与 GeoLocation-!CN → 代理. 国内流量不进 sing-box 用户态转发路径 → 保国内网速.
uci set homeproxy.config.routing_mode='bypass_mainland_china'

# IPv6: enabled to match clash (ipv6: true) — 国内 IPv6 直连, 国外 IPv6 走代理.
uci set homeproxy.config.ipv6_support='1'

# Sniff + override destination with the sniffed domain so domain-based routing
# (China/非China) works even for IP-only connections → 防止 IP 泄漏漏判.
uci set homeproxy.config.sniff_override='1'

# ── Split DNS → 仅内网 AdGuardHome (无泄漏) ───────────────────
# dns_server      : 国外域名解析 → .6 (foreign AGH, 广告过滤 + 外国 CDN 解析,
#                   保障 YouTube 拿到正确的国外节点 IP)
# china_dns_server: 国内域名解析 → .7 (domestic AGH, 内网直达, 国内 CDN 就近)
# 二者都是内网地址, 全程不使用 ISP/公网 DNS → 杜绝 DNS 泄漏.
uci set homeproxy.config.dns_server="$_HP_DNS_FOREIGN"
uci set homeproxy.config.china_dns_server="$_HP_DNS_CN"
# Resolve strategy: 优先 IPv4, 避免无 IPv6 出口时的 AAAA 泄漏/超时.
uci set homeproxy.config.dns_strategy='prefer_ipv4'

# ── Subscription (复用 clash 的同一订阅, 构建时注入 URL) ──────
uci set homeproxy.subscription=subscription
uci set homeproxy.subscription.auto_update='1'
uci set homeproxy.subscription.auto_update_time='2'   # 每天 02:00 自动更新
uci set homeproxy.subscription.update_via_proxy='0'   # 直连更新, 打破"订阅鸡蛋"循环
uci -q delete homeproxy.subscription.subscription_url
_HP_SUB_URL='__CLASH_SUB_URL__'
case "$_HP_SUB_URL" in
    __CLASH_SUB_URL__)
        echo "[36-homeproxy] NOTE: subscription URL not injected (CLASH_SUB_URL unset)."
        echo "[36-homeproxy]       Fill it later in LuCI → HomeProxy → Node → Subscriptions."
        ;;
    *)
        uci add_list homeproxy.subscription.subscription_url="$_HP_SUB_URL"
        echo "[36-homeproxy] subscription URL configured"
        ;;
esac

# ── SAFETY: keep homeproxy DISABLED by default ────────────────
# No node selected yet (subscription fetched on demand) and service disabled,
# so homeproxy cannot grab tproxy or affect the running OpenClash setup.
uci set homeproxy.config.main_node='nil'
uci set homeproxy.config.main_udp_node='nil'

uci commit homeproxy

/etc/init.d/homeproxy disable 2>/dev/null || true
/etc/init.d/homeproxy stop 2>/dev/null || true

echo "[36-homeproxy] UCI pre-configured (bypass-CN + 内网分流DNS), DISABLED by default"
echo "[36-homeproxy] To activate: disable OpenClash/Nikki first, update the"
echo "[36-homeproxy] subscription, pick a node as main node, then enable homeproxy."

