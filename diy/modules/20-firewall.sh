#!/bin/sh
# =============================================================
# Module: 20-firewall.sh
# Scope:  Firewall defaults — flow offloading for max throughput
# Runs:   First boot via zzz-default-settings orchestrator
# =============================================================
#
# SOFTWARE flow offloading: ENABLED (accelerates domestic bypass traffic).
# HARDWARE flow offloading: DISABLED (breaks OpenClash tproxy).
#
# Why software flow offload is SAFE with OpenClash + china_ip_route:
#   Data-path analysis (nftables/fw4):
#     - PROXIED traffic: TPROXY marks packet in PREROUTING mangle → routed to
#       local Clash socket → traverses the INPUT chain (NOT forward).
#     - DOMESTIC bypass traffic: china_ip_route RETURNs the packet early →
#       it continues through the FORWARD chain to NAT/postrouting.
#   The software flowtable hooks ONLY the FORWARD chain. Therefore it accelerates
#   ONLY the domestic bypass flows and never touches proxied flows.
#   This is the single biggest lever for domestic (国内直连) line-rate throughput,
#   and is especially important for PPPoE WANs (software flow offload also
#   accelerates the PPPoE encap/decap path in recent kernels).
#
# If proxied sites ever misbehave (rare, version-dependent), revert with:
#   uci set firewall.@defaults[0].flow_offloading=0
#   uci commit firewall && /etc/init.d/firewall restart
#
# NOTE: Hardware flow offload (flow_offloading_hw) is kept OFF — it caches flows
# in the NIC and is incompatible with tproxy/mark-based routing.

uci set firewall.@defaults[0].flow_offloading='1'
uci set firewall.@defaults[0].flow_offloading_hw='0'
uci commit firewall

