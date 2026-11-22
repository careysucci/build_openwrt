#!/bin/sh
# =============================================================
# Module: 36-homeproxy.sh
# Scope:  luci-app-homeproxy (sing-box) UCI pre-configuration
# Runs:   First boot via zzz-default-settings orchestrator
#
# Purpose: 提供订阅驱动的安全初始化配置：
#   - 全端口进入 TUN 规则，国内明确直连，其余只走代理，故障时不回退直连
#   - 境外 DoH 经代理，国内 DoH 直连，不向公网发送明文 DNS
#   - 订阅更新后自动纳管全部有效节点到 URLTest，并强制证书校验
#   - 普通 TLS 节点缺少指纹时使用 chrome uTLS；保留订阅中的 REALITY/ECH
#
# 边界：国内直连会按设计向国内站点暴露真实出口；WebRTC host candidate
# 由浏览器本机网卡产生，普通 TLS 的节点 SNI 也无法由本模块隐藏。
#
# SAFETY: 默认禁用，避免与 OpenClash/Nikki/dae 同时接管流量。
# Subscription URL 可由构建变量 CLASH_SUB_URL 注入，也可在 LuCI 替换。
# =============================================================

[ -f /etc/init.d/homeproxy ] || {
    echo "[36-homeproxy] homeproxy not installed — skipping"
    return 0 2>/dev/null || exit 0
}

# 主 DNS 会固定 detour=main-out，必须使用可从公网到达的 DoH；内网 .6
# 不能填在这里，否则会让远端节点访问其自身网络的 172.16.3.6。
_HP_DNS_CN='https://223.5.5.5/dns-query'
_HP_DNS_FOREIGN='https://1.1.1.1/dns-query'

# ── 当前 small/HomeProxy 的 UCI 语义 ─────────────────────────
uci set homeproxy.config=homeproxy
uci set homeproxy.config.routing_mode='bypass_mainland_china'
# 空值才是全端口；common 会让非常见端口绕过代理。
uci -q delete homeproxy.config.routing_port
uci set homeproxy.config.ipv6_support='1'
uci set homeproxy.config.multi_queue='1'
uci set homeproxy.config.log_level='warn'
uci set homeproxy.config.main_node='urltest'
uci set homeproxy.config.main_urltest_interval='60'
uci set homeproxy.config.main_urltest_tolerance='60'
uci set homeproxy.config.main_urltest_interrupt_exist_connections='0'
uci -q delete homeproxy.config.main_urltest_nodes

# 删除旧版键，避免给出已生效的错误印象。
uci -q delete homeproxy.config.proxy_mode
uci -q delete homeproxy.config.main_udp_node
uci -q delete homeproxy.config.sniff_override
uci -q delete homeproxy.config.dns_strategy

# 对 IP 形式的 DoH 不需要额外引导解析；境外查询经 main-out，国内查询直连。
uci set homeproxy.config.dns_server="$_HP_DNS_FOREIGN"
uci set homeproxy.config.china_dns_server="$_HP_DNS_CN"
uci set homeproxy.config.dashboard_enabled='0'
uci set homeproxy.infra=homeproxy
uci set homeproxy.infra.ntp_server='nil'
uci set homeproxy.control=homeproxy
uci set homeproxy.control.lan_whitelist_mode='0'

# ── 订阅：首次直连引导，之后按完整 cron 表达式更新 ──────────
uci set homeproxy.subscription=subscription
uci set homeproxy.subscription.auto_update='1'
uci set homeproxy.subscription.auto_update_time='17 3 * * *'
uci set homeproxy.subscription.update_via_proxy='0'
uci set homeproxy.subscription.allow_insecure='0'
uci set homeproxy.subscription.auto_urltest='1'
uci set homeproxy.subscription.filter_nodes='blacklist'
uci -q delete homeproxy.subscription.filter_keywords
uci add_list homeproxy.subscription.filter_keywords='ExpireAt:|剩余流量|套餐到期|官方网址|官网|流量|到期|重置|感谢|帮助|通知'
uci -q delete homeproxy.subscription.subscription_url
_HP_SUB_URL='__CLASH_SUB_URL__'
case "$_HP_SUB_URL" in
    __CLASH_SUB_URL__)
        echo "[36-homeproxy] 未注入订阅；在 LuCI → HomeProxy → 节点 → 订阅中替换。"
        ;;
    *)
        uci add_list homeproxy.subscription.subscription_url="$_HP_SUB_URL"
        echo "[36-homeproxy] 订阅地址已配置（不输出敏感 URL）"
        ;;
esac

uci set homeproxy.server=homeproxy
uci set homeproxy.server.enabled='0'

uci commit homeproxy

/etc/init.d/homeproxy disable 2>/dev/null || true
/etc/init.d/homeproxy stop 2>/dev/null || true

echo "[36-homeproxy] 已配置全端口规则、DoH 分流和订阅自动 URLTest，默认禁用"
echo "[36-homeproxy] 一键接入：/root/setup-homeproxy.sh '你的订阅URL'"
echo "[36-homeproxy] 也可在 LuCI 替换订阅并更新节点，再手动启用 HomeProxy。"
echo "[36-homeproxy] 切换前必须停止其他透明代理；WebRTC 仍需浏览器侧加固。"

