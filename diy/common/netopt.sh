#!/bin/sh /etc/rc.common
# Network performance optimization for OpenWrt on PVE/x86
# Compatible with: OpenWrt Official (firewall4/nftables) and LEDE/Lean's OpenWrt
# Provides: CPU governor, virtio MSI-X IRQ distribution, RPS/XPS, multiqueue activation

START=99
STOP=10

# ---- Helpers ----------------------------------------------------------------

_cpu_count() {
    nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1
}

_all_mask_hex() {
    local n
    n=$(_cpu_count)
    printf "%x" "$(( (1 << n) - 1 ))"
}

# Set CPU frequency governor to performance for consistent throughput.
# In PVE KVM, default governor is ondemand which throttles to base clock under
# light load — 4560T drops to 1.9GHz, killing tproxy throughput.
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

# Apply RPS/XPS — spreads packet processing across all CPUs per interface queue
apply_rps_xps() {
    local iface="$1" mask q rps xps
    mask=$(_all_mask_hex)
    for q in $(seq 0 15); do
        rps="/sys/class/net/$iface/queues/rx-$q/rps_cpus"
        xps="/sys/class/net/$iface/queues/tx-$q/xps_cpus"
        [ -f "$rps" ] || break
        printf "%s\n" "$mask" > "$rps" 2>/dev/null || true
        [ -f "$xps" ] && printf "%s\n" "$mask" > "$xps" 2>/dev/null || true
    done
}

# Bind MSI-X IRQs to different CPUs (round-robin per queue).
# virtio-net multiqueue each queue gets its own MSI-X interrupt.
# Without explicit binding, all queues pile on CPU0 regardless of multiqueue setting.
bind_msix_irqs() {
    local iface="$1"
    local msi_dir="/sys/class/net/$iface/device/msi_irqs"
    local irq_file="/sys/class/net/$iface/device/irq"
    local n i cpu_index m mhex irq total
    n=$(_cpu_count)
    i=0

    if [ -d "$msi_dir" ]; then
        # Modern NIC (virtio, igb, ixgbe, e1000e, r8125): MSI-X per queue
        total=0
        for irq in $(ls "$msi_dir" 2>/dev/null | sort -n); do
            cpu_index=$(( i % n ))
            m=$(( 1 << cpu_index ))
            mhex=$(printf "%x" "$m")
            echo "$mhex" > "/proc/irq/$irq/smp_affinity" 2>/dev/null || true
            i=$(( i + 1 ))
            total=$(( total + 1 ))
        done
        echo "[netopt] $iface: distributed $total MSI-X IRQs across $n CPUs"
    elif [ -f "$irq_file" ]; then
        # Legacy single-IRQ NIC
        irq=$(cat "$irq_file" 2>/dev/null)
        [ -n "$irq" ] && echo "$(_all_mask_hex)" > "/proc/irq/$irq/smp_affinity" 2>/dev/null || true
        echo "[netopt] $iface: legacy IRQ $irq, affinity=0x$(_all_mask_hex)"
    fi
}

# Activate virtio-net multiqueue at runtime.
# PVE sets multiqueue count in VM config; OpenWrt must call ethtool to apply it.
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

# ---- Init entrypoints -------------------------------------------------------

start() {
    local n ifaces iface
    n=$(_cpu_count)
    echo "[netopt] starting — ${n} CPU(s) detected, mask=0x$(_all_mask_hex)"

    # 1. CPU governor → performance (critical for PVE KVM throughput)
    set_cpu_governor

    # 2. irqbalance (coexists with manual affinity; handles dynamic devices)
    if command -v irqbalance >/dev/null 2>&1; then
        /etc/init.d/irqbalance enable  2>/dev/null || true
        /etc/init.d/irqbalance restart 2>/dev/null || true
        echo "[netopt] irqbalance enabled"
    fi

    # 3. Per-interface: multiqueue → RPS/XPS → MSI-X IRQ binding
    ifaces=$(get_physical_ifaces)
    if [ -z "$ifaces" ]; then
        echo "[netopt] no physical NICs found"
        return 0
    fi

    for iface in $ifaces; do
        echo "[netopt] optimizing: $iface"
        activate_multiqueue "$iface"   # activate queues first (changes IRQ layout)
        apply_rps_xps       "$iface"
        bind_msix_irqs      "$iface"
    done

    echo "[netopt] completed"
}

stop() {
    return 0
}

