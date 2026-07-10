#!/bin/sh /etc/rc.common
# Network performance optimization for OpenWrt on PVE/x86
# Target: 5Gbps NIC + 3×2Gbps WAN aggregation (≈6Gbps aggregate)
# Compatible with: OpenWrt Official (firewall4/nftables) and LEDE/Lean's OpenWrt
# Provides: CPU governor, TCP BBR, buffer tuning, NIC offloads, IRQ/RPS/XPS, multiqueue

START=99
STOP=10

# ---- Helpers ----------------------------------------------------------------

_cpu_count() {
    nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1
}

_all_mask_hex() {
    local n chunk suffix=""
    n=$(_cpu_count)
    # smp_affinity uses comma-separated 32-bit hexadecimal groups. Avoid
    # shell bit shifts wider than 31 bits, which overflow on BusyBox ash.
    while [ "$n" -gt 32 ]; do
        suffix="${suffix:+$suffix,}ffffffff"
        n=$((n - 32))
    done
    if [ "$n" -eq 32 ]; then
        chunk="ffffffff"
    else
        chunk=$(printf "%x" "$(( (1 << n) - 1 ))")
    fi
    printf "%s%s" "$chunk" "${suffix:+,$suffix}"
}

# Print the smp_affinity mask for one zero-based CPU index. Linux expects the
# least-significant 32 CPU bits at the right of a comma-separated mask.
_cpu_mask_hex() {
    local cpu group bit mask
    cpu="$1"
    group=$((cpu / 32))
    bit=$((cpu % 32))
    mask=$(printf "%x" "$((1 << bit))")
    while [ "$group" -gt 0 ]; do
        mask="${mask},00000000"
        group=$((group - 1))
    done
    printf "%s" "$mask"
}

# Detect VM/hypervisor environment.
# Returns 0 (true) if running inside a VM, 1 (false) on physical hardware.
# Used to choose between irqbalance (physical) and manual IRQ affinity (VM).
_is_vm() {
    # CPUID hypervisor flag — set by KVM, QEMU, VMware, Hyper-V, Xen
    grep -qw "hypervisor" /proc/cpuinfo 2>/dev/null && return 0
    # Xen guests may not expose the CPUID hypervisor flag or DMI data.
    [ -d /proc/xen ] && return 0
    # DMI sys_vendor fallback (covers cases where CPUID bit is hidden)
    local _sv
    _sv=$(cat /sys/devices/virtual/dmi/id/sys_vendor 2>/dev/null \
          | tr '[:upper:]' '[:lower:]')
    case "$_sv" in
        *qemu*|*kvm*|*vmware*|*virtualbox*|*xen*|*microsoft*) return 0 ;;
    esac
    return 1
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

# ---- Per-interface functions ------------------------------------------------

# Apply RPS/XPS — spreads packet processing across all CPUs per interface queue
apply_rps_xps() {
    local iface="$1" mask q rps xps flow_cnt
    mask=$(_all_mask_hex)
    for q in $(seq 0 31); do
        rps="/sys/class/net/$iface/queues/rx-$q/rps_cpus"
        xps="/sys/class/net/$iface/queues/tx-$q/xps_cpus"
        flow_cnt="/sys/class/net/$iface/queues/rx-$q/rps_flow_cnt"
        [ -f "$rps" ] || break
        printf "%s\n" "$mask" > "$rps" 2>/dev/null || true
        [ -f "$xps" ] && printf "%s\n" "$mask" > "$xps" 2>/dev/null || true
        # rps_flow_cnt per queue: enables per-flow CPU affinity tracking.
        [ -f "$flow_cnt" ] && echo "4096" > "$flow_cnt" 2>/dev/null || true
    done
}

# Bind MSI-X IRQs to different CPUs (round-robin per queue).
bind_msix_irqs() {
    local iface="$1"
    local msi_dir="/sys/class/net/$iface/device/msi_irqs"
    local irq_file="/sys/class/net/$iface/device/irq"
    local n i cpu_index mhex irq total
    n=$(_cpu_count)
    i=0

    if [ -d "$msi_dir" ]; then
        total=0
        for irq in $(ls "$msi_dir" 2>/dev/null | sort -n); do
            cpu_index=$(( i % n ))
            mhex=$(_cpu_mask_hex "$cpu_index")
            echo "$mhex" > "/proc/irq/$irq/smp_affinity" 2>/dev/null || true
            i=$(( i + 1 ))
            total=$(( total + 1 ))
        done
        echo "[netopt] $iface: distributed $total MSI-X IRQs across $n CPUs"
    elif [ -f "$irq_file" ]; then
        irq=$(cat "$irq_file" 2>/dev/null)
        [ -n "$irq" ] && echo "$(_all_mask_hex)" > "/proc/irq/$irq/smp_affinity" 2>/dev/null || true
        echo "[netopt] $iface: legacy IRQ $irq, affinity=0x$(_all_mask_hex)"
    fi
}

# Activate NIC multiqueue at runtime.
activate_multiqueue() {
    local iface="$1" n max_q target
    command -v ethtool >/dev/null 2>&1 || return
    n=$(_cpu_count)
    max_q=$(ethtool -l "$iface" 2>/dev/null | awk '/^Combined:/{print $2; exit}')
    [ -z "$max_q" ] || [ "$max_q" = "0" ] || [ "$max_q" = "n/a" ] && return
    target=$(( max_q > n ? n : max_q ))
    ethtool -L "$iface" combined "$target" 2>/dev/null && \
        echo "[netopt] $iface: multiqueue combined=$target" || true
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

    # Adaptive coalescing: NIC driver auto-tunes based on traffic load
    ethtool -C "$iface" adaptive-rx on adaptive-tx on 2>/dev/null || \
    # Fallback: manual coalescing if adaptive not supported
    ethtool -C "$iface" rx-usecs 50 tx-usecs 50 rx-frames 64 tx-frames 64 2>/dev/null || true

    echo "[netopt] $iface: interrupt coalescing configured"
}

# Increase TX queue length for high-speed interfaces.
# Default txqueuelen=1000; at 5Gbps this fills in <1ms causing drops during bursts.
set_txqueuelen() {
    local iface="$1"
    ip link set "$iface" txqueuelen 5000 2>/dev/null || true
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
# These are virtual netdevs (no /device dir) so get_physical_ifaces skips them,
# but PPPoE decapsulation processing benefits from RPS to spread softirq load.
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

    # --- Increase initial congestion window on ALL default routes ---
    # Multi-WAN: may have multiple default routes (metric-based).
    # initcwnd=128 (~192KB) lets BBR probe at high speed from first packet.
    local route
    ip route show default 2>/dev/null | while read -r route; do
        ip route change $route initcwnd 128 initrwnd 128 2>/dev/null || true
    done
    echo "[netopt] all default routes: initcwnd=128, initrwnd=128"

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
    # 5Gbps with mixed packet sizes: ~400k-4M pps depending on payload.
    # netdev_max_backlog: inter-CPU packet queue. Default 1000 → drops at 5Gbps.
    echo "50000" > /proc/sys/net/core/netdev_max_backlog 2>/dev/null || true
    # NAPI budget: packets processed per softirq cycle.
    # Higher = more throughput, slightly more latency jitter (acceptable for router).
    echo "1200" > /proc/sys/net/core/netdev_budget 2>/dev/null || true
    echo "30000" > /proc/sys/net/core/netdev_budget_usecs 2>/dev/null || true
    echo "[netopt] net.core: backlog=50000, budget=1200, budget_usecs=30000"

    # --- Socket listen backlog ---
    echo "16384" > /proc/sys/net/core/somaxconn 2>/dev/null || true
    echo "16384" > /proc/sys/net/ipv4/tcp_max_syn_backlog 2>/dev/null || true

    # --- RPS socket flow entries ---
    # 65536 entries (power of 2) for 5w+ concurrent flows across 3 WANs.
    echo "65536" > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true

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
    local n ifaces iface _VM_ENV
    n=$(_cpu_count)
    echo "[netopt] starting — ${n} CPU(s) detected, mask=0x$(_all_mask_hex)"
    echo "[netopt] target: 5Gbps NIC + 3×2G WAN aggregate"

    # 1. CPU governor → performance
    set_cpu_governor

    # 2. TCP/IP stack tuning (BBR + buffers + conntrack + multi-WAN)
    apply_tcp_tuning

    # 3. IRQ balancing strategy — VM vs physical
    # Problem: irqbalance is a daemon that re-distributes IRQ affinity every
    # ~10 seconds. If we start irqbalance AND then set smp_affinity manually
    # (bind_msix_irqs), irqbalance will silently override our settings.
    #
    # Physical host: irqbalance understands real NUMA/cache topology and does
    #   a better job than static round-robin. Let it handle IRQs; skip manual
    #   bind_msix_irqs so the two don't fight each other.
    #
    # VM (PVE/KVM/VMware/…): all vCPUs are topologically equal — irqbalance
    #   has no meaningful topology info and often consolidates all virtio queue
    #   IRQs onto 1-2 vCPUs, creating a bottleneck. Manual round-robin across
    #   all vCPUs (bind_msix_irqs, step 4) is more predictable and persistent.
    _VM_ENV=0
    if _is_vm; then
        _VM_ENV=1
        # irqbalance may already have been started earlier in the boot order.
        # It continuously rewrites smp_affinity, so it must be stopped as well
        # as disabled before the manual settings below are applied.
        if [ -x /etc/init.d/irqbalance ]; then
            /etc/init.d/irqbalance stop 2>/dev/null || true
            /etc/init.d/irqbalance disable 2>/dev/null || true
        fi
        echo "[netopt] VM/hypervisor detected — irqbalance stopped; manual IRQ affinity will be applied"
    elif [ -x /etc/init.d/irqbalance ]; then
        /etc/init.d/irqbalance enable  2>/dev/null || true
        # Do not restart a running daemon at S99: its restart needlessly
        # reshuffles active IRQs. Start it only when it is not already running.
        /etc/init.d/irqbalance status >/dev/null 2>&1 || \
            /etc/init.d/irqbalance start 2>/dev/null || true
        echo "[netopt] physical host — irqbalance enabled (manual IRQ affinity skipped)"
    fi

    # 4. Per-interface optimization (physical NICs)
    ifaces=$(get_physical_ifaces)
    if [ -z "$ifaces" ]; then
        echo "[netopt] no physical NICs found"
    else
        for iface in $ifaces; do
            echo "[netopt] optimizing: $iface"
            activate_multiqueue      "$iface"
            maximize_ring_buffer     "$iface"
            apply_nic_offloads       "$iface"
            apply_interrupt_coalescing "$iface"
            set_txqueuelen           "$iface"
            apply_rps_xps            "$iface"
            # Manual IRQ affinity: VM only.
            # On physical host irqbalance (step 3) handles distribution;
            # calling bind_msix_irqs here would conflict with it.
            [ "$_VM_ENV" -eq 1 ] && bind_msix_irqs "$iface"
        done
    fi

    # 5. PPPoE/PPP WAN interfaces — apply RPS to spread decapsulation softirq load.
    # PPPoE is a classic x86 bottleneck: the pppoe-wan netdev processing tends to
    # serialize on one CPU. RPS on the ppp interface distributes the post-decap
    # packet processing across all cores. Combined with software flow_offloading
    # (set in 20-firewall.sh), this lets PPPoE traffic reach near line rate.
    # txqueuelen on ppp also enlarged to absorb bursts.
    for iface in $(get_ppp_ifaces); do
        echo "[netopt] optimizing PPPoE iface: $iface"
        apply_rps_xps  "$iface"   # only touches rx/tx queues (safe on virtual netdev)
        set_txqueuelen "$iface"
    done

    # 6. Install persistent initcwnd hotplug script
    # apply_tcp_tuning() runs `ip route change ... initcwnd 128` above, but that
    # only patches the route object that exists at boot time.  A PPPoE reconnect
    # or DHCP renew replaces the route object entirely, silently resetting
    # initcwnd back to the kernel default (10).  This hotplug fires on every
    # interface "ifup" event and re-stamps the current default route(s).
    mkdir -p /etc/hotplug.d/iface
    cat > /etc/hotplug.d/iface/99-initcwnd << 'HOTPLUG_EOF'
#!/bin/sh
# Installed by netopt: re-apply initcwnd=128 / initrwnd=128 after every WAN
# reconnect (PPPoE, DHCP renew, etc.) so TCP slow-start always uses the large
# initial window regardless of how many times the WAN interface has cycled.
[ "$ACTION" = "ifup" ] || exit 0
ip route show default | while IFS= read -r _r; do
    ip route change $_r initcwnd 128 initrwnd 128 2>/dev/null || true
done
HOTPLUG_EOF
    chmod +x /etc/hotplug.d/iface/99-initcwnd
    echo "[netopt] hotplug/99-initcwnd installed (initcwnd=128 persists across WAN reconnects)"

    echo "[netopt] completed"
}

stop() {
    return 0
}

