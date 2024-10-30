#!/bin/bash
#
#
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#
# Copyright (c) 2019-2024
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

# clear small duplicate packages
ls -l openwrt/feeds/small/
ls -l openwrt/feeds/small.index/
rm -rf openwrt/feeds/small/luci-app-passwall
rm -rf openwrt/feeds/small/luci-app-passwall2
rm -rf openwrt/feeds/small/luci-app-openclash
rm -rf openwrt/feeds/small/luci-app-homeproxy
rm -rf openwrt/feeds/small/mihomo

# switch theme
sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' openwrt/feeds/luci/collections/luci/Makefile

cp -f diy/common/default-settings openwrt/package/lean/default-settings/files/zzz-default-settings
# banner
cp -f diy/banner openwrt/package/base-files/files/etc/banner
sed -i "s/%D %V, %C/OpenWrt by ${AUTHORED_BY} $(date +'%Y-%m-%d')/g" openwrt/package/base-files/files/etc/banner

# Modify default IP
sed -i 's/192.168.1.1/172.16.3.18/g' openwrt/package/base-files/files/bin/config_generate

# Modify default theme
sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' openwrt/feeds/luci/collections/luci/Makefile

# Modify hostname
sed -i "s/OpenWrt/${AUTHORED_BY}/g" openwrt/package/base-files/files/bin/config_generate
