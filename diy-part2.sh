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

# ERROR: package/feeds/packages/rust [host] failed to build.
# llvm.download-ci-llvm cannot be set to true on CI. Use if-unchanged instead.
# Set Rust build arg llvm.download-ci-llvm to false.
sed -i 's/--set=llvm\.download-ci-llvm=true/--set=llvm\.download-ci-llvm=false/' "${TARGET_MATRIX}"/feeds/packages/lang/rust/Makefile

# Modify default theme
sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' "${TARGET_MATRIX}"/feeds/luci/collections/luci/Makefile

#cp -f diy/common/zzz-default-settings "${TARGET_MATRIX}"/package/lean/default-settings/files/zzz-default-settings
# banner
cp -f diy/banner "${TARGET_MATRIX}"/package/base-files/files/etc/banner
sed -i "s/%D %V, %C/OpenWrt by ${AUTHORED_BY} $(date +'%Y-%m-%d')/g" "${TARGET_MATRIX}"/package/base-files/files/etc/banner
# openwrt-release
pushd "${TARGET_MATRIX}" || exit
short_commit_id=$(git rev-parse --short HEAD)
popd || exit
sed -i "s/%D/${RELEASE_NAME}/g" "${TARGET_MATRIX}"/package/base-files/files/etc/openwrt_release
sed -i "s/%V/${DATE4}/g" "${TARGET_MATRIX}"/package/base-files/files/etc/openwrt_release
sed -i "s/%C/git-${short_commit_id}/g" "${TARGET_MATRIX}"/package/base-files/files/etc/openwrt_release
sed -i "s/Openwrt/${RELEASE_NAME}/g" "${TARGET_MATRIX}"/package/base-files/files/etc/openwrt_release
# os-release
sed -i "s/%D/${RELEASE_NAME}/g" "${TARGET_MATRIX}"/package/base-files/files/usr/lib/os-release
sed -i "s/%V/${DATE4}/g" "${TARGET_MATRIX}"/package/base-files/files/usr/lib/os-release
sed -i "s/%C/git-${short_commit_id}/g" "${TARGET_MATRIX}"/package/base-files/files/usr/lib/os-release
# mkversion
case "${TARGET_MATRIX}" in
  "lede")
    sed -i "s/\${2:-Git}/${short_commit_id}/g" "${TARGET_MATRIX}"/package/feeds/luci/luci-lua-runtime/src/mkversion.sh
    ;;
  "official")
  # luci name
#    sed -i "s/\$\{3:-LuCI\}//g" "${TARGET_MATRIX}"/feeds/base/feeds/luci/luci-lua-runtime/src/mkversion.sh
    # luci version
    sed -i "s/\${2:-Git}/${short_commit_id}/g" "${TARGET_MATRIX}"/feeds/base/feeds/luci/luci-lua-runtime/src/mkversion.sh
    ;;
esac

# Modify default IP
sed -i 's/192.168.1.1/172.16.3.18/g' "${TARGET_MATRIX}"/package/base-files/files/bin/config_generate
sed -i 's/255.255.255.0/255.255.248.0/g' "${TARGET_MATRIX}"/package/base-files/files/bin/config_generate

# Modify hostname
sed -i "s/OpenWrt/${AUTHORED_BY}/g" "${TARGET_MATRIX}"/package/base-files/files/bin/config_generate
