#!/bin/bash
#
#
# File name: diy-part1.sh
# Description: OpenWrt DIY script part 1 (Before Update feeds)
#
# Copyright (c) 2019-2024
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

# enter openwrt folder
pushd openwrt || exit

# clean plugin
rm -rf feeds/packages/utils/v2dat
rm -rf feeds/packages/net/{alist,adguardhome,brook,gost,mosdns,redsocks*,smartdns,trojan*,v2ray*,xray*}
rm -rf feeds/packages/luci/{*passwall*,*bypass*,*homeproxy*,*mihomo*,*openclash*}
# theme
rm -rf package/lean/luci-theme-argon
rm -rf package/lean/luci-app-argon-config
git clone -b 18.06 https://github.com/jerrykuku/luci-theme-argon.git package/lean/luci-theme-argon
git clone -b 18.06 https://github.com/jerrykuku/luci-app-argon-config.git package/lean/luci-app-argon-config
# update golang
rm -rf feeds/packages/lang/golang
git clone https://github.com/kenzok8/golang feeds/packages/lang/golang


# Clean a feed source
sed -i "/helloworld/d" "feeds.conf.default"

# Add a feed source
{
  echo "src-git helloworld https://github.com/fw876/helloworld.git"
  echo 'src-git passwall https://github.com/xiaorouji/openwrt-passwall'
  echo 'src-git passwall2 https://github.com/xiaorouji/openwrt-passwall2'
  echo "src-git OpenClash https://github.com/vernesong/OpenClash.git;master"
  echo "src-git netspeedtest https://github.com/sirpdboy/netspeedtest.git;master"
  echo "src-git diskman https://github.com/careysucci/luci-app-diskman.git;master"
  echo "src-git homeproxy https://github.com/immortalwrt/homeproxy.git;master"
  echo "src-git mihomo https://github.com/morytyann/OpenWrt-mihomo.git;main"
} >> "feeds.conf.default"

# back to root folder
popd || exit