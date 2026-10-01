# CR8806 手动配置为桥接 AP 模式操作手册

> 适用机型：Redmi CR8806（AX3000）
> 适用固件：WyWrt（本仓库构建的 ImmortalWrt 25.12）；步骤同样适用于 kmiit 或任何 OpenWrt/LuCI 系统
> 目标形态：**桥接 AP**——四个网口 + WiFi 全部二层互通，接入现有 `172.16.0.0/21` 主网；盒子不拨号、不 NAT、不发地址，仅保留一个管理 IP（`172.16.0.226`）
> 操作时长：约 10 分钟
> 撰写日期：2026-09-30（每步均按当日实机状态核对）

---

## 0. 当前状态快照（2026-09-30 实测）

| 项目 | 现状 | 目标 |
|---|---|---|
| 运行系统 | WyWrt（系统分区 2，固件为下午构建版） | 不变 |
| LAN 地址 | `172.16.3.19/24`（手动改的，掩码与主网不符） | `172.16.0.226/21` |
| LuCI 登录 | `http://172.16.3.19`，用户名 `root`，密码**空** | `http://172.16.0.226` |
| SSH | 密码登录被拒（root 空密码时 dropbear 只收公钥，属正常行为） | 设密码后解锁 |
| WiFi | WyHouse（5G 802.11ax 正常） | 不动 |
| DHCP 服务 | LAN 口 DHCP 开着 | 关闭 |
| WAN 口 | 独立 wan 接口（DHCP 客户端） | 并入 LAN 桥并删除 wan 接口 |

**为什么内核日志一直刷 `icmp: detected local route for 172.16.3.19 ... src 172.16.3.18`**：
盒子 LAN 是 `.19`，而默认网关指向 `172.16.3.18`（该地址在网内已不存在）。盒子自身发出的每个包（DNS、NTP 等）都要经死网关转发，内核生成"网关不可达"ICMP 差错报文时，发现收件人（`.19`）就是自己 → 打印该警告刷屏。AP 化之后无网关、无转发，该日志自然消失。详见附录 C。

---

## 1. 准备（2 分钟）

1. **确认接线**：电脑网线接盒子**任意标着 LAN 的网口**（不要接 WAN 口，接了管理页面不通），全程不要拔线。
2. **查主网三个参数**（在一台能上网的主网电脑上执行 `ipconfig`）：
   - 主网网关（"默认网关"字段）——**当前现场主网没有 IPv4 网关（PC 无默认路由，疑似靠 IPv6 出网）**，查不到就留空，AP 本身不上网也能正常工作；
   - 主网 DNS——同上，可留空；
   - 子网掩码：现场实测主网为 `/21` = `255.255.248.0`。
3. **确认目标 IP 没被占用**：在电脑上 `ping 172.16.0.226`，应当**不通**（通了说明有设备在用，换一个如 `.227`，后续文档中的 `.226` 同步替换）。
4. 浏览器打开 `http://172.16.3.19`，用户名 `root`、密码留空，登录。

> ⚠️ **本机型实测警告（2026-09-30）**：第 2–6 节的逐条“保存并应用”路径在本机踩坑——其中“WAN 口并入 br-lan”一步的在线重载会触发交换机硬件转发崩坏、管理彻底失联（症状与恢复见附录 A 条目 4）。**本机型请直接走第 9 节的“一次性 SSH 配置 + 重启生效”路径**；第 2–6 节保留作通用参考（单 conduit 机型可用）。

---

## 2. 第一步：关闭 DHCP 服务（必须最先做！）

> **为什么必须最先**：下一步把 WAN 口并入 LAN 桥后，盒子的 DHCP 服务器就直接暴露在主网网线上，会跟主网 DHCP 抢答、给全网设备发错误地址，造成主网大面积断网。先关它，再动桥。

1. 菜单 **网络 → 接口** → **LAN** 行，点 **「编辑」**。
2. 页面下拉到 **「DHCP 服务器」** 区 → **「常规设置」** 标签。
3. 勾选 **「忽略此接口」**（Ignore interface）。
4. 顺手切到同一区的 **「IPv6 设置」** 标签（避免 IPv6 RA 抢答）：
   - **路由通告服务**（RA 服务）：已禁用（disabled）
   - **DHCPv6 服务**：已禁用（disabled）
5. 点 **「保存并应用」**（Save & Apply）。

**验证**：重新打开 LAN 编辑页 → DHCP 服务器 → 常规设置，「忽略此接口」处于勾选状态。

---

## 3. 第二步：把 WAN 口并入 LAN 桥（四口全通）

1. 菜单 **网络 → 接口** → 顶部 **「设备」标签页**（Devices）。
2. 找到 **br-lan** 行，点 **「配置」**。
3. 在 **「桥接端口」**（Bridge ports）多选框中，**勾选 `wan`**（原有 `lan1`–`lan3` 保持勾选；本机共 3 个 LAN 口 + 1 个 WAN 口）。
4. 「保存」→ 回到设备列表再 **「保存并应用」**。

> ⚠️ **本机型勿单独执行本节**——此步的在线重载正是 2026-09-30 实测触发失联的一步（附录 A 条目 4）。请改走第 9 节。

**验证**：br-lan 配置页端口列表显示 4 个口（lan1–lan3 + wan）。

---

## 4. 第三步：删除 wan / wan6 接口

1. 菜单 **网络 → 接口**（Interfaces 主页）。
2. **wan** 行最右侧 **「删除」** 按钮 → 点删除。
3. **wan6** 行同样 **「删除」**。
4. **「保存并应用」**。

**验证**：接口列表只剩 **LAN** 一行。WAN 口此刻已是纯桥端口，不再是独立接口。

---

## 5. 第四步：LAN 改成主网静态地址（网页会断开，属预期！）

1. 菜单 **网络 → 接口** → **LAN** 行 **「编辑」**：
   - **协议**：静态地址（Static address）
   - **IPv4 地址**：`172.16.0.226`
   - **子网掩码**：`255.255.248.0`（/21，与主网一致；**不要**保留默认的 255.255.255.0）
   - **IPv4 网关**：主网网关（查到就填；查不到留空）
   - **DNS 服务器**：同网关，或 `223.5.5.5`（可留空）
2. 「保存并应用」——**页面大概率转圈卡住，这是正常的**：地址已从 `.19` 切到 `.226`，浏览器跟旧地址的会话自然断开。等 30 秒即可，不用重试。
3. 浏览器打开新地址 **`http://172.16.0.226`**，重新登录（root / 空密码）。

> 若打不开：等 1 分钟再刷新；仍不行说明主网掩码/网段与预期不符——用附录 A 的办法排查。

---

## 6. 第五步（推荐）：设 root 密码 + 关闭防火墙/dnsmasq + 重启

1. **设密码**：菜单 **系统 → 管理权** → **路由器密码**：设一个（如 `111111`）。
   - 好处①：解锁 SSH 密码登录（`ssh root@172.16.0.226`），后面排障方便；
   - 好处②：设备不再"裸奔"在主网上。
2. **关防火墙**（纯二层 AP 用不到，关掉省内存）：菜单 **系统 → 启动项** → 找到 **firewall** 行 → 「禁用」→「保存并应用」。
3. **关 dnsmasq**（DHCP 已关，DNS 缓存对 AP 非必需，可留可关；关了更干净）：同页 **dnsmasq** 行 → 「禁用」。
4. **重启一次**：菜单 **系统 → 重启** →「执行重启」。重启后按第 7 节逐项验证，确认配置开机即生效。

---

## 7. 验证清单（全部打勾才算完成）

| # | 检查项 | 方法 | 期望结果 |
|---|---|---|---|
| 1 | 管理 IP 可达 | 主网电脑 `ping 172.16.0.226` | 通 |
| 2 | LuCI 可达 | 浏览器 `http://172.16.0.226` | 登录页出现 |
| 3 | WiFi 客户端拿到主网地址 | 手机连 WyHouse，看 WiFi 详情 | IP 是 `172.16.0.x/21`（**不是** 192.168.1.x） |
| 4 | WiFi 客户端可上网 | 手机开网页 | 正常打开 |
| 5 | ICMP 刷屏消失 | LuCI → 状态 → 内核日志 | 无 `detected local route` 新增 |
| 6 | 有线桥接 | 笔记本插 WAN 口（丝印 WAN 的口） | 同样拿到主网 IP、能上网 |
| 7 | 配置固化 | 重启盒子后重复 1–5 | 全部依旧成立 |

---

## 8. 等效命令版（SSH，供命令行党）

> 前提：先完成第 6 步设好密码，SSH 才可登录（`ssh root@172.16.0.226`）。下列命令与上面图形步骤**等效**。
> ⚠️ **本机型注意**：这些命令若以 `/etc/init.d/network restart` 收尾，同样会触发附录 A 条目 4 的在线重载坑——本机型请改用第 9 节的幂等整合版（写盘后直接 `reboot`）。

```sh
# ---- 1. DHCP off（必须最先） ----
uci set dhcp.lan.ignore='1'
uci set dhcp.lan.ra='disabled'
uci set dhcp.lan.dhcpv6='disabled'
uci commit dhcp

# ---- 2. wan 并入 br-lan ----
# 先查 br-lan 对应的 device 段名（通常是 network.@device[0]）：
uci show network | grep '=device'
uci add_list network.@device[0].ports='wan'   # 段名以上一条查到的为准

# ---- 3. 删 wan/wan6 + LAN 改静态 ----
uci delete network.wan
uci delete network.wan6
uci set network.lan.ipaddr='172.16.0.226'
uci set network.lan.netmask='255.255.248.0'
# 网关/DNS 可选：
# uci set network.lan.gateway='主网网关'
# uci add_list network.lan.dns='223.5.5.5'
uci commit network

# ---- 4. 服务与密码 ----
/etc/init.d/firewall disable
/etc/init.d/dnsmasq disable
/etc/init.d/odhcpd disable
echo -e '密码\n密码' | passwd root   # 或交互式 passwd

# ---- 5. 生效（本机型勿用 network restart：在线重载有附录 A 条目 4 风险，直接重启） ----
reboot
```

---

## 9. 推荐路径：一次性 SSH 配置 + 重启生效（本机型专用）

> 背景（2026-09-30 / 10-01 实测，三个独立的坑）：①本机型“保存并应用”的网络改动走 netifd **在线重载**，其中“WAN 口并入 br-lan”一步会触发交换机硬件转发崩坏、管理彻底失联（机制与恢复见附录 A 条目 4）。②本平台 WAN 口默认走 eth0（GMAC0 PHY-to-PHY）conduit，该通路在主线 qca8k 驱动上**收方向是死的**（openwrt#24696，Redmi AX5400 同接线同病）——不改 conduit 的话 WAN 口并入桥后仍然不通（附录 A 条目 5）。③LuCI 设备页没有 conduit 字段，在那里保存过 wan/br-lan 设备会把 conduit **静默洗掉**、留下无名空壳段（附录 B）——2b 步因此自带空段清理。本路径把全部改动**一次性写盘、用重启代替在线重载**，并把 WAN conduit 归一到 eth1，一并绕开三个坑。脚本幂等，无论之前做到第几步都可以直接执行。

**前置**：盒子处于可达状态。若已失联，先按附录 A 条目 4 冷启动恢复。

1. 浏览器登录 `http://172.16.3.19`（root / 空密码）。
2. 菜单 **系统 → 管理权 → 路由器密码** 设一个密码（如 `111111`）——SSH 密码登录的前提（空密码时 dropbear 只收公钥）。
3. 电脑执行 `ssh root@172.16.3.19`（密码 = 第 2 步所设）。
4. 将下面整段脚本复制粘贴执行（等效完成第 2–6 节全部改动 + WAN conduit 归一 + 双分区 flag 归位）：

```sh
# ---------- CR8806 桥接 AP 一次性配置（幂等，可重复执行） ----------
# 1) DHCP / RA / DHCPv6 全关（第 2 节等效）
uci set dhcp.lan.ignore='1'
uci set dhcp.lan.ra='disabled'
uci set dhcp.lan.dhcpv6='disabled'
uci commit dhcp

# 2) 定位 br-lan 设备段（匿名/命名段通吃），WAN 并入桥（第 3 节等效，防重复）
sec=$(uci show network | sed -n "s/^\(network\.[^=]*\)\.name='br-lan'$/\1/p" | head -1)
[ -n "$sec" ] || { echo 'ERROR: br-lan device section not found'; exit 1; }
uci get "$sec.ports" | grep -qw wan || uci add_list "$sec.ports"='wan'

# 2b) WAN 口 conduit 归一到 eth1（关键！本平台 eth0/GMAC0 收方向死，openwrt#24696）
#     先清掉 LuCI 设备页保存时洗出的无名空 device 段（LuCI 设备编辑器没有
#     conduit 字段，保存会把不认识的选项洗掉、留下空壳段——conduit 修复被静默
#     撤销就是这个机制），再确保 wan 段存在且 conduit=eth1（已有则复用，防同名双段）
i=0
while uci -q get network.@device[$i] >/dev/null 2>&1; do
    if [ -z "$(uci -q get network.@device[$i].name)" ]; then
        uci delete network.@device[$i]
    else
        i=$((i + 1))
    fi
done
wsec="$(uci show network | sed -n "s/^\(network\.[^=]*\)\.name='wan'$/\1/p" | head -1)"
[ -n "$wsec" ] || wsec="$(uci add network device)"
uci set "$wsec.name=wan"
uci set "$wsec.conduit=eth1"

# 3) 删 wan/wan6（第 4 节等效；不存在则静默跳过）
uci -q delete network.wan
uci -q delete network.wan6

# 4) LAN = 172.16.0.226/21（第 5 节等效）
uci set network.lan.proto='static'
uci set network.lan.ipaddr='172.16.0.226'
uci set network.lan.netmask='255.255.248.0'
uci -q delete network.lan.gateway
uci -q delete network.lan.dns
# 主网查到网关的话解开下一行：
# uci set network.lan.gateway='172.16.0.1'
uci commit network

# 5) 纯 AP 用不到的服务禁自启（第 6 节等效）
/etc/init.d/firewall disable
/etc/init.d/dnsmasq disable
/etc/init.d/odhcpd disable

# 6) 双分区 flag 归位（锁死系统 2，防断电回退 kmiit，见附录 A 双分区说明）
fw_setenv flag_boot_rootfs 1
fw_setenv flag_last_success 1
fw_setenv flag_boot_success 1
fw_setenv flag_try_sys1_failed 0
fw_setenv flag_try_sys2_failed 0
fw_setenv flag_ota_reboot 0

# 7) 重启生效（SSH 会话断开属预期；勿用 /etc/init.d/network restart —— 见附录 A 条目 4）
reboot
```

**重启后**：等约 2 分钟，浏览器访问 **`http://172.16.0.226`**（root / 第 2 步所设密码），按第 7 节清单逐项验证。conduit 生效的内核级证据：`ls /sys/class/net/wan/` 里出现 `lower_eth1`（默认 eth0 时是 `lower_eth0`）。若 3 分钟后 IPv4 仍不可达，**别反复软重启**——本次同时改了桥成员和 conduit，`reboot` 也会概率性触发交换机数据面挂死（附录 A 条目 4 的 2026-10-01 补充），直接拔电 ≥10 秒冷启动。

---

## 附录 A：出问题怎么办

- **第 5 步后连不上 `.226`**：
  1. 等 1–2 分钟再试（netifd 重载较慢）；
  2. 电脑手动配一个 `172.16.0.x/21` 的静态 IP 再试；
  3. 都不行 → 走 failsafe：断电，按住 reset 上电，灯开始闪时松开，电脑配 `192.168.1.2/24` 后 `telnet 192.168.1.1`，执行 `firstboot && reboot` 恢复出厂（会丢掉 AP 配置，需从头再来）。
- **双分区说明**：本机系统 1 = 老 kmiit（ImmortalWrt 24.10，LAN 固定 `172.16.3.19`，密码 `111111`）；系统 2 = WyWrt（当前在用）。U-Boot 按 `flag_boot_rootfs` 选分区（0=系统1，1=系统2）。
  在 WyWrt 下切换/校准引导标记（已实测的组合）：
  ```sh
  fw_setenv flag_boot_rootfs 1    # 下次启动进系统2（WyWrt）；0 = 系统1
  fw_setenv flag_last_success 1
  fw_setenv flag_boot_success 1
  fw_setenv flag_try_sys1_failed 0
  fw_setenv flag_try_sys2_failed 0
  fw_setenv flag_ota_reboot 0
  ```
  > 注意：下午构建的固件里 `/etc/init.d/uboot_env` 是旧版逻辑，启动成功后**不会**清 `flag_try_sys2_failed`——U-Boot 引导前会把它预置为 1，若期间断电重启过一次，U-Boot 会认为系统 2 启动失败而**回退到系统 1（kmiit）**。所以 AP 化完成后建议把上面 6 条命令跑一遍，把所有标记归位（尤其 `flag_try_sys2_failed=0`）。仓库最新代码（commit `e5dbf81`）已修复该逻辑，之后用新固件刷新即无此问题。
- **「WAN 口并入 br-lan」保存并应用后彻底失联（本机实测 2026-09-30）**：
  - 症状：LuCI 转圈后断开，此后 `ping 172.16.3.19` 全部失败、ARP 无应答（网口链路灯仍正常）；IPv6 link-local 探测可见内核存活但管理服务全不可用（22/53 端口拒连 = dropbear/dnsmasq 已不监听，80 超时 = uhttpd 无响应）——CPU 活着，网络数据面崩了。
  - 机制：LuCI 的“保存并应用”= netifd **在线重载**（且带约 90 秒未确认自动回滚）。CR8806 为双 conduit 拓扑（LAN1-3 → eth1/SGMII，WAN → eth0/GE PHY，见 `adapter-25.12/ipq5000-ax3000.dts`），WAN 口从独立接口转入 br-lan 触发**跨 conduit 的桥在线重建**，QCA8337 交换机硬件转发表与内核桥状态脱节（本仓库已知坑“QCA 交换机内核桥状态与硬件转发脱节”），数据面全黑。
  - 疗法：**拔电源 ≥10 秒冷启动**（交换机硬件状态需断电复位）。未确认的应用约 90 秒后自动回滚——重启后通常回到改动前状态（LAN 仍为 `172.16.3.19` 可达，已确认过的第 2 节 DHCP 关闭保留，第 3 节的 WAN 入桥被撤销）；若个别情形回滚未发生，br-lan 会带 WAN 直接启动，同样正常。两种结果都不影响第 9 节脚本（幂等）。恢复后**勿再分步应用**，直接走第 9 节。
  - 补充（2026-10-01 实测）：**`reboot` 也不保证干净**——桥成员与 conduit 双变更后的一次软重启再次复现同样症状（IPv4 全网段不通、ARP 无条目，但 IPv6 link-local ping 1ms 通、HTTP 200、SSH 超时 = CPU 活着、数据面黑）。判定口诀：**link-local 通而 IPv4 全黑 = 交换机数据面挂了**，软件重启救不了，直接拔电 ≥10 秒冷启动。
- **WAN 口已在桥里、链路灯也亮，但就是不通过流量（本机实测 2026-09-30）**：
  - 症状：br-lan 成员含 wan、网线插上链路 up，但接在 WAN 口的设备完全不通；dmesg 有 `adpt_mp_port_netdev_change_notify ... incorrect port 0` / `ssdk_dev_event ... netdev change notify failed`。
  - 机制：本机 WAN 口默认 DSA conduit 是 eth0（IPQ5018 GMAC0 经内置 GE PHY 与 QCA8337 port5 PHY-to-PHY 相接），该通路在主线 qca8k 驱动上**收方向不工作**（openwrt#24696；Redmi AX5400 同接线同病。本仓库 NSS 线的 99-nss-topology 正是因此把 WAN 归一到 eth1——社区实测 AX5400 同拓扑 914/856 Mbps）。
  - 疗法：给 wan 口单独建 `config device` 段设 `option conduit 'eth1'`（第 9 节脚本 2b 步已含）+ 重启。注意：conduit 变更**必须重启生效**，在线重载无效（且会踩条目 4）。
  - 波及范围：**路由模式同样中招**——WAN 口走 eth0 conduit 时 DHCP 拨号/静态 IP 都收不到包。任何用 WAN 口的形态都应把 conduit 归一到 eth1。
- **彻底救砖**：U-Boot TFTP——电脑配 `192.168.31.100`，上电时按住 reset 进 TFTP 模式，推 `factory.ubi`（192.168.31.x 网段，与运行网段无关）。

## 附录 B：常见坑

| 坑 | 后果 | 规避 |
|---|---|---|
| 先桥接 WAN 后关 DHCP | 盒子在主网抢发地址，全网断网 | 严格按本文顺序：DHCP 永远最先关 |
| 掩码填了 255.255.255.0 | 主网是 /21，盒子看不到 172.16.0.x 大部分地址 | 掩码填 `255.255.248.0` |
| root 空密码时折腾 SSH | dropbear 拒绝密码登录（只收公钥），误以为 SSH 坏了 | 先在 LuCI 设密码即解锁 |
| 刷新固件时勾选"保留配置" | 旧配置（含本 AP 配置）会带入新固件 | 想回到出厂路由形态就用 `sysupgrade -n`；想保留 AP 形态就保留配置 |
| 刷新固件不保留配置 | 回到固件预配置的**标准路由模式**（LAN `172.16.3.19/24`，见仓库 commit `712949f`） | 刷完后重跑本手册即可 |
| 分步“保存并应用”网络改动（尤其 WAN 入桥） | 在线桥重建触发交换机转发崩坏，管理失联（附录 A 条目 4） | 本机型走第 9 节一次性脚本 + 重启生效 |
| WAN 口沿用默认 eth0 conduit | 桥接/路由模式下 WAN 口收方向全死（附录 A 条目 5，openwrt#24696） | 给 wan 设 `conduit 'eth1'`（第 9 节脚本 2b 步已含） |
| 在 LuCI 设备页编辑/保存过 wan 或 br-lan 设备 | LuCI 设备编辑器没有 conduit 字段，保存时把它**静默洗掉**、留下无名空段——conduit 归一被撤销，WAN 再次不通，且空壳段会干扰后续修复 | conduit 只用第 9 节脚本 2b 步设置（自带空段清理）；设备页只看不动 |
| 保留配置升级到 61d0fba 时期固件后 `.226` 失联 | 首启 uci-defaults 无条件把已部署 AP 的管理 IP 重置回 `172.16.3.19`（该批脚本不幂等；2026-10-01 已加守卫，新固件不再有） | 先连 `http://172.16.3.19` 找回盒子，再跑第 9 节脚本改回；升级到含守卫的固件即无此问题 |
| netmask 填 /24 同时又填网关 172.16.3.x | 网关不在链路上，默认路由装不上，盒子自身不出网 | 主网是 /21：掩码 `255.255.248.0`，网关自然 on-link（第 9 节脚本已含） |

## 附录 C：`icmp: detected local route ...` 日志的完整解释

内核（`net/ipv4/icmp.c`）在为某个转发失败的包生成 ICMP 差错报文时，会对**原包的五元组做反向流查找**来决定差错报文怎么发。若发现差错报文的目的地址（= 原包的源地址）居然是**本机自己的地址**（`RTN_LOCAL`），就会打印：

```
icmp: detected local route for 172.16.3.19 during ICMP sending, src 172.16.3.18
```

含义拆解：有一个 **源=`172.16.3.19`、目的=`172.16.3.18`** 的包转发失败（`.18` ARP 不通），内核要给源地址 `.19` 回"不可达"，但 `.19` 正是盒子自己的 LAN 地址——包是盒子自己发的，差错报文发给自己。

本例触发链：盒子 LAN 被手动设为 `.19/24` 且网关指向 `.18`（该网关已不存在）→ 盒子自身周期性流量（DNS 解析、NTP 对时等）全部涌向死网关 → 每个包产生一条该警告，于是刷屏。

AP 化后：LAN 无网关（或指向真实网关）、不再做三层转发，该日志必然消失。若验证清单第 5 项不成立，说明网关仍指向 `.18`，回到第 5 步检查。
