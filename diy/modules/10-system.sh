#!/bin/sh
# =============================================================
# Module: 10-system.sh
# Scope:  System defaults — language, timezone, network, opkg
# Runs:   First boot via zzz-default-settings orchestrator
# =============================================================

# LuCI language
uci set luci.main.lang=zh_cn
uci commit luci

# Timezone (CST-8 = UTC+8, POSIX TZ convention)
uci set system.@system[0].timezone=CST-8
uci set system.@system[0].zonename=Asia/Hong_Kong
uci commit system

# Auto-mount
uci set fstab.@global[0].anon_mount=1
uci commit fstab

# /usr/bin/ip compat shim (some scripts expect it here)
ln -sf /sbin/ip /usr/bin/ip 2>/dev/null || true

# opkg: clean vendor feeds, remove signature check
sed -i '/lienol/d'          /etc/opkg/distfeeds.conf 2>/dev/null || true
sed -i '/other/d'           /etc/opkg/distfeeds.conf 2>/dev/null || true
sed -i "s/# //g"            /etc/opkg/distfeeds.conf 2>/dev/null || true
sed -i '/check_signature/d' /etc/opkg.conf            2>/dev/null || true
sed -i.bak '/^option overlay_root \/overlay/s/^/#/' /etc/opkg.conf 2>/dev/null || true

# DHCP / DHCPv6 / RA
uci set dhcp.lan.ra='server'
uci set dhcp.lan.dhcpv6='server'
uci set dhcp.lan.ra_management='1'
uci set dhcp.lan.ra_default='1'
uci commit dhcp

# LAN IP (matches config_generate patch in diy-part2)
uci set network.lan.ipaddr='172.16.3.18'
uci set network.lan.netmask='255.255.248.0'
uci set network.lan.ip6assign='64'
uci commit network

# Wireless: x86 has no wifi hardware — skip gracefully
sed -i '/option disabled/d' /etc/config/wireless 2>/dev/null || true
sed -i '/set wireless.radio${devidx}.disabled/d' /lib/wifi/mac80211.sh 2>/dev/null || true
if [ -d /sys/class/ieee80211 ] && ls /sys/class/ieee80211/ 2>/dev/null | grep -q .; then
    wifi up 2>/dev/null || true
fi

# Stamp release with first-boot date
sed -i '/DISTRIB_REVISION/d'    /etc/openwrt_release
sed -i '/DISTRIB_RELEASE/d'     /etc/openwrt_release
sed -i '/DISTRIB_DESCRIPTION/d' /etc/openwrt_release
echo "DISTRIB_REVISION='v$(date +'%Y.%m.%d')'"    >> /etc/openwrt_release
echo "DISTRIB_RELEASE='v$(date +'%Y.%m.%d')'"     >> /etc/openwrt_release
echo "DISTRIB_DESCRIPTION='Openwrt '"              >> /etc/openwrt_release

# LuCI version.lua — brand as Wy.House (covers 23.05 / 24.10 / 25.12 / future)
_ver_lua=/usr/lib/lua/luci/version.lua
if [ -f "$_ver_lua" ]; then
    sed -i "s/LuCI Master/Wy.House/g"                           "$_ver_lua"
    sed -i "s/LuCI openwrt-[0-9][0-9]\.[0-9][0-9]/Wy.House/g"  "$_ver_lua"
    sed -i "s/LuCI openwrt [0-9][0-9]\.[0-9][0-9].*/Wy.House/g" "$_ver_lua"
    sed -i '/luciversion/d'                                      "$_ver_lua"
    echo "luciversion ='$(date +'%m.%d')'"                    >> "$_ver_lua"
fi

# Remove unused admin status views
rm -rf /usr/lib/lua/luci/view/admin_status/index 2>/dev/null || true

