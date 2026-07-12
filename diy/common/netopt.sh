#!/bin/sh /etc/rc.common
# Network performance optimization for OpenWrt on PVE/x86
# Target: 5Gbps NIC + 3×2Gbps WAN aggregation (≈6Gbps aggregate)
# Compatible with: OpenWrt Official (firewall4/nftables) and LEDE/Lean's OpenWrt
# Provides: CPU governor, TCP BBR, conservative buffers, NIC offloads and irqbalance

START=99
STOP=10

# ---- Helpers ----------------------------------------------------------------

_cpu_count() {
    nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1
}

# ---- Per-interface functions ------------------------------------------------

# Set CPU frequency governor to performance for consistent throughput.
# In PVE KVM, default governor is ondemand which throttles to base clock under
# light load — causes latency spikes and kills tproxy/forwarding throughput.
set_cpu_governor() {
    local changed=0 gov
    for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -f "$gov" ] || continue
        echo "performance" > "$gov" 2>/dev/null && changed=1
    done
    if [ "$changed" -eq 1 ]; then
        echo "[netopt] CPU governor set to performance ($(_cpu_count) cores)"
    else
        echo "[netopt] CPU governor: not available (host-passthrough KVM or unsupported)"
    fi
}

# Clear forced RPS/XPS settings. Native virtio/RSS multiqueue already maps each
# queue to an IRQ; forcing every queue onto every CPU destroys queue locality,
# increases packet reordering and was the main throughput regression on PVE.
clear_forced_rps_xps() {
    local iface="$1" q file
    for q in /sys/class/net/"$iface"/queues/rx-*; do
        [ -d "$q" ] || continue
        file="$q/rps_cpus"
        [ -f "$file" ] && echo 0 > "$file" 2>/dev/null || true
        file="$q/rps_flow_cnt"
        [ -f "$file" ] && echo 0 > "$file" 2>/dev/null || true
    done
    for q in /sys/class/net/"$iface"/queues/tx-*; do
        [ -d "$q" ] || continue
        file="$q/xps_cpus"
        [ -f "$file" ] && echo 0 > "$file" 2>/dev/null || true
    done
}

# Enable NIC hardware offloads (GRO/GSO/TSO/checksum/scatter-gather).
# At 5Gbps each packet costs CPU cycles; offloads batch 64KB super-packets.
apply_nic_offloads() {
    local iface="$1"
    command -v ethtool >/dev/null 2>&1 || return

    ethtool -K "$iface" gro on  2>/dev/null || true
    ethtool -K "$iface" gso on  2>/dev/null || true
    ethtool -K "$iface" tso on  2>/dev/null || true
    ethtool -K "$iface" rx-checksumming on 2>/dev/null || true
    ethtool -K "$iface" tx-checksumming on 2>/dev/null || true
    ethtool -K "$iface" sg on 2>/dev/null || true
    # LRO: DISABLED — incompatible with IP forwarding/tproxy/nftables.
    # LRO aggregates packets into super-frames that cannot be re-segmented for forwarding.
    # The kernel automatically disables LRO when forwarding is enabled, but explicit is better.
    # GRO (above) provides similar batching but IS compatible with forwarding.
    ethtool -K "$iface" lro off 2>/dev/null || true
    # rx-vlan-offload/tx-vlan-offload — VLAN tag processing in hardware
    ethtool -K "$iface" rxvlan on 2>/dev/null || true
    ethtool -K "$iface" txvlan on 2>/dev/null || true

    echo "[netopt] $iface: hardware offloads enabled (GRO/GSO/TSO/csum/sg, LRO=off)"
}

# Maximize NIC ring buffer size.
# 5Gbps with small packets (ACKs, DNS) generates millions of pps.
# Larger ring buffers absorb CPU scheduling jitter without packet drops.
maximize_ring_buffer() {
    local iface="$1"
    command -v ethtool >/dev/null 2>&1 || return
    [ "$(ethtool -i "$iface" 2>/dev/null | awk '/^driver:/{print $2}')" = "virtio_net" ] && return

    local max_rx max_tx
    max_rx=$(ethtool -g "$iface" 2>/dev/null | awk '/^RX:/{print $2; exit}')
    max_tx=$(ethtool -g "$iface" 2>/dev/null | awk '/^TX:/{print $2; exit}')

    [ -n "$max_rx" ] && [ "$max_rx" != "0" ] && \
        ethtool -G "$iface" rx "$max_rx" 2>/dev/null || true
    [ -n "$max_tx" ] && [ "$max_tx" != "0" ] && \
        ethtool -G "$iface" tx "$max_tx" 2>/dev/null || true

    [ -n "$max_rx" ] && echo "[netopt] $iface: ring buffer rx=$max_rx tx=$max_tx"
}

# Set interrupt coalescing — reduce interrupt rate at high throughput.
# Without coalescing: 5Gbps ≈ 400k interrupts/sec → CPU spends all time in ISR.
# With coalescing: batch interrupts → fewer context switches → more CPU for forwarding.
apply_interrupt_coalescing() {
    local iface="$1"
    command -v ethtool >/dev/null 2>&1 || return
    [ "$(ethtool -i "$iface" 2>/dev/null | awk '/^driver:/{print $2}')" = "virtio_net" ] && return

    # Use adaptive mode only; do not force a 50us delay on unsupported devices.
    ethtool -C "$iface" adaptive-rx on adaptive-tx on 2>/dev/null || return

    echo "[netopt] $iface: interrupt coalescing configured"
}

# Restore the normal TX queue length; oversized queues add latency under load.
set_txqueuelen() {
    local iface="$1"
    ip link set "$iface" txqueuelen 1000 2>/dev/null || true
}

# Enumerate physical NICs — skip bridges, tun, ppp, virtual
get_physical_ifaces() {
    local list="" name
    for dev in /sys/class/net/*; do
        name=$(basename "$dev")
        [ "$name" = "lo" ] && continue
        case "$name" in
            br*|tun*|tap*|ppp*|vpn*|wg*|docker*|veth*|utun*|dummy*|sit*|gre*|ip6tnl*) continue ;;
        esac
        [ -d "/sys/class/net/$name/device" ] || continue
        list="$list $name"
    done
    echo "$list"
}

# Enumerate PPPoE / PPP WAN interfaces.
get_ppp_ifaces() {
    local list="" name
    for dev in /sys/class/net/*; do
        name=$(basename "$dev")
        case "$name" in
            ppp*|pppoe*) list="$list $name" ;;
        esac
    done
    echo "$list"
}

# ---- TCP/IP Stack Tuning ---------------------------------------------------

# TCP stack tuning for extreme bandwidth (5Gbps NIC, 3×2G WAN aggregate ≈6Gbps).
# BBR eliminates CUBIC's slow-start ramp-up; fq qdisc enables BBR pacing.
# Buffer sizing: BDP = 5Gbps × 30ms RTT = 18.75MB; set max=64MB for safety margin.
apply_tcp_tuning() {
    # --- BBR congestion control ---
    if grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        echo "bbr" > /proc/sys/net/ipv4/tcp_congestion_control
        echo "[netopt] TCP congestion control: BBR enabled"
    else
        echo "[netopt] TCP congestion control: BBR not available, using default"
    fi

    # --- fq (Fair Queue) qdisc ---
    # BBR requires fq for packet pacing; without it BBR falls back to burst mode.
    if [ -f /proc/sys/net/core/default_qdisc ]; then
        echo "fq" > /proc/sys/net/core/default_qdisc 2>/dev/null || true
        echo "[netopt] default qdisc: fq"
    fi

    # --- TCP buffer sizes (min / default / max) ---
    # BDP for 5Gbps × 30ms = 18.75MB. Max=64MB covers high-latency paths + parallel streams.
    # Default=4MB allows single connection to quickly grow window without waste.
    echo "4096 4194304 67108864" > /proc/sys/net/ipv4/tcp_rmem 2>/dev/null || true
    echo "4096 2097152 67108864" > /proc/sys/net/ipv4/tcp_wmem 2>/dev/null || true
    echo "67108864"              > /proc/sys/net/core/rmem_max 2>/dev/null || true
    echo "67108864"              > /proc/sys/net/core/wmem_max 2>/dev/null || true
    # NOTE: Do NOT set rmem_default/wmem_default to 64MB!
    # tcp_rmem/tcp_wmem auto-tunes per-connection. rmem_default only affects non-TCP sockets.
    # Setting it too high wastes RAM (each socket pre-allocates this amount).
    # Keep kernel default (~212KB) for UDP/raw sockets; large UDP buffers use SO_RCVBUF explicitly.
    echo "[netopt] TCP buffers: rmem/wmem max=64MB, tcp default=4MB/2MB (auto-tuned)"

    # --- TCP fast open (reduce connection setup latency) ---
    echo "3" > /proc/sys/net/ipv4/tcp_fastopen 2>/dev/null || true

    # --- Connection tracking tuning ---
    # 3×2G WAN aggregate with 2.5w+ concurrent connections per service.
    # max=524288 entries, buckets=131072 (ratio 1:4 — keeps hash chain length ≤4,
    # preventing O(n) conntrack lookup degradation under high connection rates)
    echo "524288" > /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || true
    echo "131072" > /proc/sys/net/netfilter/nf_conntrack_buckets 2>/dev/null || \
        echo "131072" > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
    # Reduce established timeout: default 432000s (5 days) wastes entries.
    # 7200s (2 hours) is enough for any legitimate long-lived connection.
    echo "7200" > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established 2>/dev/null || true
    # Reduce TIME_WAIT timeout for faster entry recycling
    echo "60" > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_time_wait 2>/dev/null || true
    echo "[netopt] conntrack: max=524288, buckets=131072, established_timeout=7200s"

    # --- Kernel network stack backlog & NAPI budget ---
    # Keep NAPI close to upstream defaults. Very long 30ms softirq runs starve
    # virtio TX completion and make repeated speed tests ramp up extremely slowly.
    echo "5000" > /proc/sys/net/core/netdev_max_backlog 2>/dev/null || true
    echo "300" > /proc/sys/net/core/netdev_budget 2>/dev/null || true
    echo "2000" > /proc/sys/net/core/netdev_budget_usecs 2>/dev/null || true
    echo "[netopt] net.core: backlog=5000, budget=300, budget_usecs=2000"

    # --- Socket listen backlog ---
    echo "16384" > /proc/sys/net/core/somaxconn 2>/dev/null || true
    echo "16384" > /proc/sys/net/ipv4/tcp_max_syn_backlog 2>/dev/null || true

    # RPS is intentionally disabled: virtio/RSS multiqueue preserves queue/CPU
    # locality better than software redistribution on this router workload.
    echo "0" > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true

    # --- Port range (multi-WAN needs more ephemeral ports) ---
    # Default 32768-60999 = 28231 ports; with 3 WANs this limits concurrent connections.
    echo "1024 65535" > /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null || true

    # --- TIME_WAIT bucket limit ---
    # High-throughput routers churn connections fast; limit TIME_WAIT accumulation.
    echo "262144" > /proc/sys/net/ipv4/tcp_max_tw_buckets 2>/dev/null || true

    # --- MTU probing ---
    # Avoids PMTU black holes (some paths silently drop >1400B packets).
    echo "1" > /proc/sys/net/ipv4/tcp_mtu_probing 2>/dev/null || true

    # --- Disable bridge netfilter calls ---
    # When bridge is used (br-lan), kernel by default passes bridged frames
    # through nftables/iptables. This is unnecessary for routed traffic and
    # adds significant per-packet overhead at 5Gbps.
    echo "0" > /proc/sys/net/bridge/bridge-nf-call-iptables  2>/dev/null || true
    echo "0" > /proc/sys/net/bridge/bridge-nf-call-ip6tables 2>/dev/null || true
    echo "0" > /proc/sys/net/bridge/bridge-nf-call-arptables 2>/dev/null || true
    echo "[netopt] bridge-nf-call disabled (no bridged traffic through nftables)"

    # --- Misc TCP optimizations ---
    echo "1" > /proc/sys/net/ipv4/tcp_window_scaling 2>/dev/null || true
    echo "1" > /proc/sys/net/ipv4/tcp_timestamps 2>/dev/null || true
    echo "1" > /proc/sys/net/ipv4/tcp_sack 2>/dev/null || true
    echo "2" > /proc/sys/net/ipv4/tcp_syn_retries 2>/dev/null || true
    echo "2" > /proc/sys/net/ipv4/tcp_synack_retries 2>/dev/null || true
    echo "1" > /proc/sys/net/ipv4/tcp_no_metrics_save 2>/dev/null || true
    echo "0" > /proc/sys/net/ipv4/tcp_slow_start_after_idle 2>/dev/null || true
    # tcp_tw_reuse: allow reusing TIME_WAIT sockets for new outgoing connections
    echo "1" > /proc/sys/net/ipv4/tcp_tw_reuse 2>/dev/null || true
    # tcp_fin_timeout: reduce FIN_WAIT2 timeout (default 60s → 15s)
    echo "15" > /proc/sys/net/ipv4/tcp_fin_timeout 2>/dev/null || true
    # Disable IPv4 reverse path filtering on WAN for multi-WAN compatibility
    echo "0" > /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null || true
    echo "0" > /proc/sys/net/ipv4/conf/default/rp_filter 2>/dev/null || true
    echo "[netopt] TCP: tw_reuse, fin_timeout=15, rp_filter=0, no_slow_start_after_idle"
}

# ---- Main entrypoints -------------------------------------------------------

start() {
    local n ifaces iface
    n=$(_cpu_count)
    echo "[netopt] starting — ${n} CPU(s) detected"
    echo "[netopt] target: 5Gbps NIC + 3×2G WAN aggregate"

    # 1. CPU governor → performance
    set_cpu_governor

    # 2. TCP/IP stack tuning (BBR + buffers + conntrack + multi-WAN)
    apply_tcp_tuning

    # 3. Let irqbalance manage MSI-X/virtio IRQs on both VM and bare metal.
    # Do not combine it with manual affinity writes.
    if [ -x /etc/init.d/irqbalance ]; then
        /etc/init.d/irqbalance enable  2>/dev/null || true
        /etc/init.d/irqbalance status >/dev/null 2>&1 || \
            /etc/init.d/irqbalance start 2>/dev/null || true
        echo "[netopt] irqbalance enabled; manual IRQ affinity disabled"
    fi

    # 4. Per-interface optimization (physical NICs)
    ifaces=$(get_physical_ifaces)
    if [ -z "$ifaces" ]; then
        echo "[netopt] no physical NICs found"
    else
        for iface in $ifaces; do
            echo "[netopt] optimizing: $iface"
            maximize_ring_buffer     "$iface"
            apply_nic_offloads       "$iface"
            apply_interrupt_coalescing "$iface"
            set_txqueuelen           "$iface"
            clear_forced_rps_xps     "$iface"
        done
    fi

    # 5. PPPoE/PPP WAN interfaces — clear legacy forced RPS and enlarge TX queue.
    for iface in $(get_ppp_ifaces); do
        echo "[netopt] optimizing PPPoE iface: $iface"
        clear_forced_rps_xps "$iface"
        set_txqueuelen "$iface"
    done

    # Remove the regression-prone hotplug file from images upgraded in place.
    rm -f /etc/hotplug.d/iface/99-initcwnd

    echo "[netopt] completed"
}

stop() {
    return 0
}

