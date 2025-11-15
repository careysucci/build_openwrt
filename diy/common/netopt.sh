#!/bin/sh /bin/sh
### BEGIN INIT INFO
# Provides:          rps_xps
# Required-Start:    $network $local_fs
# Required-Stop:
# Default-Start:     2 3 4 5
# Default-Stop:
# Short-Description: Setup RPS/XPS and IRQ affinity for high throughput NICs
### END INIT INFO

START=99

# CPU mask: use all CPUs (adjust if you want specific mask)
# e.g. for 4 cores use f (0xF), for 8 cores use ff (0xFF), here use all detected cpus:
cpu_count=$(nproc 2>/dev/null || echo 1)
# build mask: (1 << cpu_count) -1 in hex
mask=$(( (1 << cpu_count) - 1 ))
# convert to hex
mask_hex=$(printf "%x" "$mask")

apply_rps_xps() {
  wan_ifaces="$1"
  for ifn in $wan_ifaces; do
    # try generic queue indexes up to 16 (works for most drivers)
    for q in $(seq 0 15); do
      rps="/sys/class/net/$ifn/queues/rx-$q/rps_cpus"
      xps="/sys/class/net/$ifn/queues/tx-$q/xps_cpus"
      [ -f "$rps" ] && printf "%s\n" "$mask_hex" > "$rps" 2>/dev/null || break
      [ -f "$xps" ] && printf "%s\n" "$mask_hex" > "$xps" 2>/dev/null || true
    done
  done
}

bind_irqs_to_affinity() {
  # bind IRQs for given interfaces' IRQ numbers to a rotating mask across CPUs
  wan_ifaces="$1"
  i=0
  for ifn in $wan_ifaces; do
    # get PCI IRQ(s) by parsing /sys/class/net/<if>/device/msi_irqs or /sys/class/net/<if>/device/irq
    # fallback: /sys/class/net/<if>/device/irq
    irqfile="/sys/class/net/$ifn/device/irq"
    if [ -f "$irqfile" ]; then
      irq=$(cat "$irqfile" 2>/dev/null)
      if [ -n "$irq" ]; then
        # create per-if mask by rotating
        # compute mask for CPU index (i % cpu_count)
        cpu_index=$(( i % cpu_count ))
        m=$((1 << cpu_index))
        mhex=$(printf "%x" "$m")
        echo "$mhex" > "/proc/irq/$irq/smp_affinity" 2>/dev/null || true
      fi
    else
      # try list under /proc/interrupts mapping
      true
    fi
    i=$((i+1))
  done
}

start() {
  # Choose candidate WAN interfaces to apply on: common names
  candidates="eth0 eth1 eth2 enp0s3 enp0s25 ens33 eth0.2 vlan0 pppoe-wan wan"
  # also include virtio net names
  for v in /sys/class/net/*; do
    name=$(basename "$v")
    # heuristics: include interfaces that look like ethernet (not lo)
    if [ "$name" != "lo" ]; then
      candidates="$candidates $name"
    fi
  done

  # choose likely WANs by checking if it's a physical NIC (has device)
  wan_list=""
  for ifn in $candidates; do
    [ -d "/sys/class/net/$ifn/device" ] || continue
    # ignore bridge/tun/tap/ppp interfaces
    case "$ifn" in
      br*|tun*|tap*|ppp*|lo|vpn*|wg*|docker*|veth*) continue;;
    esac
    wan_list="$wan_list $ifn"
  done

  # remove duplicates
  wan_list=$(echo $wan_list | tr ' ' '\n' | awk '!a[$0]++' | tr '\n' ' ')

  if [ -z "$wan_list" ]; then
    echo "rps_xps: no candidate physical NICs found"
    return 0
  fi

  apply_rps_xps "$wan_list"
  bind_irqs_to_affinity "$wan_list"

  # enable irqbalance service if installed
  if command -v irqbalance >/dev/null 2>&1; then
    /etc/init.d/irqbalance enable >/dev/null 2>&1 || true
    /etc/init.d/irqbalance start >/dev/null 2>&1 || true
  fi

  echo "rps_xps: applied to: $wan_list"
}

stop() {
  # do nothing
  return 0
}

case "$1" in
  start|"")
    start
    ;;
  stop)
    stop
    ;;
  restart)
    stop
    start
    ;;
  *)
    echo "Usage: $0 {start|stop|restart}"
    exit 1
    ;;
esac

exit 0
