#!/bin/sh
# =============================================================
# Module: 20-firewall.sh
# Scope:  Firewall defaults
# Runs:   First boot via zzz-default-settings orchestrator
# =============================================================
#
# Flow offloading MUST be disabled when OpenClash (tproxy) is active.
# Both SFE/flow-offload and tproxy depend on netfilter hooks:
#   - flow offload: hardware/software fast-path that BYPASSES nftables after first packet
#   - tproxy:       requires EVERY packet to pass through nftables to be redirected
# Enabling both simultaneously causes tproxy rules to become invisible to the kernel.
#
# To switch to max-throughput mode (no proxy):
#   /etc/init.d/openclash stop
#   uci set firewall.@defaults[0].flow_offloading=1
#   uci commit firewall && /etc/init.d/firewall restart

uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].flow_offloading_hw='0'
uci commit firewall

