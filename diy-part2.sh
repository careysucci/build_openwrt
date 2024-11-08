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
rm -rf "${TARGET_MATRIX}"/feeds/small/luci-app-passwall
rm -rf "${TARGET_MATRIX}"/feeds/small/luci-app-passwall2
rm -rf "${TARGET_MATRIX}"/feeds/small/luci-app-openclash
#rm -rf "${TARGET_MATRIX}"/feeds/small/luci-app-homeproxy
rm -rf "${TARGET_MATRIX}"/feeds/small/mihomo
rm -rf "${TARGET_MATRIX}"/feeds/small/luci-app-mihomo

# Modify default theme
sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' "${TARGET_MATRIX}"/feeds/luci/collections/luci/Makefile

cp -f diy/common/zzz-default-settings "${TARGET_MATRIX}"/package/lean/default-settings/files/zzz-default-settings
# banner
cp -f diy/banner "${TARGET_MATRIX}"/package/base-files/files/etc/banner
sed -i "s/%D %V, %C/OpenWrt by ${AUTHORED_BY} $(date +'%Y-%m-%d')/g" "${TARGET_MATRIX}"/package/base-files/files/etc/banner
# openwrt-release
pushd "${TARGET_MATRIX}" || exit
short_commit_id=$(git rev-parse --short HEAD)
popd || exit
sed -i "s/%D/WyWrt/g" "${TARGET_MATRIX}"/package/base-files/files/etc/openwrt_release
sed -i "s/%V/${DATE4}/g" "${TARGET_MATRIX}"/package/base-files/files/etc/openwrt_release
sed -i "s/%C/git-${short_commit_id}/g" "${TARGET_MATRIX}"/package/base-files/files/etc/openwrt_release
sed -i "s/Openwrt/Wywrt/g" "${TARGET_MATRIX}"/package/base-files/files/etc/openwrt_release

# Modify default IP
sed -i 's/192.168.1.1/172.16.3.18/g' "${TARGET_MATRIX}"/package/base-files/files/bin/config_generate

# Modify hostname
sed -i "s/OpenWrt/${AUTHORED_BY}/g" "${TARGET_MATRIX}"/package/base-files/files/bin/config_generate
