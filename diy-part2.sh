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

#
echo "OPENWRT_SOURCE_DIR = ${TARGET_MATRIX}" >> $GITHUB_ENV


# clear small duplicate packages
rm -rf "${OPENWRT_SOURCE_DIR}"/feeds/small/luci-app-passwall
rm -rf "${OPENWRT_SOURCE_DIR}"/feeds/small/luci-app-passwall2
rm -rf "${OPENWRT_SOURCE_DIR}"/feeds/small/luci-app-openclash
#rm -rf "${OPENWRT_SOURCE_DIR}"/feeds/small/luci-app-homeproxy
rm -rf "${OPENWRT_SOURCE_DIR}"/feeds/small/mihomo
rm -rf "${OPENWRT_SOURCE_DIR}"/feeds/small/luci-app-mihomo

# Modify default theme
sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' "${OPENWRT_SOURCE_DIR}"/feeds/luci/collections/luci/Makefile

cp -f diy/common/zzz-default-settings "${OPENWRT_SOURCE_DIR}"/package/lean/default-settings/files/zzz-default-settings
# banner
cp -f diy/banner "${OPENWRT_SOURCE_DIR}"/package/base-files/files/etc/banner
sed -i "s/%D %V, %C/OpenWrt by ${AUTHORED_BY} $(date +'%Y-%m-%d')/g" "${OPENWRT_SOURCE_DIR}"/package/base-files/files/etc/banner

# Modify default IP
sed -i 's/192.168.1.1/172.16.3.18/g' "${OPENWRT_SOURCE_DIR}"/package/base-files/files/bin/config_generate

# Modify hostname
sed -i "s/OpenWrt/${AUTHORED_BY}/g" "${OPENWRT_SOURCE_DIR}"/package/base-files/files/bin/config_generate
