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


# clean plugin
rm -rf feeds/packages/lang/golang
git clone https://github.com/kenzok8/golang feeds/packages/lang/golang
rm -rf feeds/packages/net/{alist,adguardhome,brook,gost,mosdns,redsocks*,smartdns,trojan*,v2ray*,xray*}
rm -rf feeds/packages/luci/{luci-app-homeproxy,luci-app-openclash,luci-app-passwall}


# Clean a feed source
sed -i "/helloworld/d" "feeds.conf.default"

# Add a feed source
echo "src-git helloworld https://github.com/fw876/helloworld.git" >> "feeds.conf.default"
echo 'src-git passwall https://github.com/xiaorouji/openwrt-passwall' >>feeds.conf.default
