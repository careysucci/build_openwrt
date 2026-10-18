#!/bin/sh
#
# internet-led.sh - CR881x LED state machine daemon
#
# Lamp semantics (field-verified pin map, only three real lamps):
#   gpio25 = red:status   (system fault indicator)
#   gpio26 = blue:wan     (internet reachable)
#   gpio27 = red:wan      (internet down / booting)
#
# State machine:
#   booting              -> red:status ON  + red:wan ON
#                           (both come from DTS default-state="on", lit
#                           as soon as gpio-leds probes, long before this
#                           daemon starts)
#   system ready         -> red:status OFF (there is NO system-blue lamp
#                           on this board - gpio24 is an unconnected pin)
#   internet reachable   -> blue:wan ON,  red:wan OFF
#   internet unreachable -> blue:wan OFF, red:wan ON
#
# "Internet up" = the box HAS a default gateway AND the gateway answers
# ICMP (uplink alive) - no public-internet probe by design, so a working
# uplink without actual WAN access still shows blue.
#
# The daemon probes the gateway with ICMP. On boards without this
# exact lamp set (e.g. CR880X) it exits silently and changes nothing.
#

SYS_RED=/sys/class/leds/red:status/brightness
WAN_BLUE=/sys/class/leds/blue:wan/brightness
WAN_RED=/sys/class/leds/red:wan/brightness

[ -f "$SYS_RED" ] && [ -f "$WAN_BLUE" ] && [ -f "$WAN_RED" ] || exit 0

# Let netifd/wifi settle before declaring the system ready.
sleep 10

# System is up: extinguish the boot red. The healthy "system on" state is
# lamp-off by design (red = fault semantics on this router).
echo 0 > "$SYS_RED"

while true; do
    # Re-read the default gateway every cycle (DHCP/static reconfig).
    GW="$(ip route show default 2>/dev/null | awk '/^default/ {print $3; exit}')"
    if [ -n "$GW" ] && ping -c 2 -W 2 "$GW" >/dev/null 2>&1; then
        echo 1 > "$WAN_BLUE"
        echo 0 > "$WAN_RED"
    else
        echo 0 > "$WAN_BLUE"
        echo 1 > "$WAN_RED"
    fi
    sleep 15
done
