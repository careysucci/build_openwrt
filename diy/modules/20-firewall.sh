#!/bin/sh
# =============================================================
# Module: 20-firewall.sh
# Scope:  Firewall defaults — flow offloading for max throughput
# Runs:   First boot via zzz-default-settings orchestrator
# =============================================================
#
# Select one software acceleration path and keep hardware offload disabled:
#   LEDE + TurboACC/shortcut-fe: SFE only
#   Official OpenWrt: nft software flow offload only
#
# Why the software fast path is compatible with this OpenClash setup:
#   Data-path analysis:
#     - PROXIED traffic: TPROXY marks packet in PREROUTING mangle → routed to
#       local Clash socket → traverses the INPUT chain (NOT forward).
#     - DOMESTIC bypass traffic: china_ip_route RETURNs the packet early →
#       it continues through the FORWARD chain to NAT/postrouting.
#   The fast path accelerates forwarded traffic. Therefore it accelerates
#   ONLY the domestic bypass flows and never touches proxied flows.
#   This is the single biggest lever for domestic (国内直连) line-rate throughput,
#   and is especially important for PPPoE WANs (software flow offload also
#   accelerates the PPPoE encap/decap path in recent kernels).
#
# NOTE: Hardware flow offload (flow_offloading_hw) is kept OFF — it caches flows
# in the NIC and is incompatible with tproxy/mark-based routing.

if uci -q get turboacc.config.sfe_flow >/dev/null 2>&1; then
	# Avoid running SFE and nft flowtable at the same time.
	uci set firewall.@defaults[0].flow_offloading='0'
	uci set firewall.@defaults[0].flow_offloading_hw='0'
	uci set turboacc.config.sw_flow='0'
	uci set turboacc.config.hw_flow='0'
	uci set turboacc.config.sfe_flow='1'
	uci commit turboacc
	echo "[20-firewall] LEDE: SFE enabled; nft/hardware flow offload disabled"
else
	uci set firewall.@defaults[0].flow_offloading='1'
	uci set firewall.@defaults[0].flow_offloading_hw='0'
	echo "[20-firewall] Official: nft software flow offload enabled"
fi
uci commit firewall


