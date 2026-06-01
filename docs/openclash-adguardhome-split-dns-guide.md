# OpenClash + AdGuardHome 分流 DNS 配置教程

> 适用场景：OpenWrt 主路由（Official / LEDE）安装 OpenClash，PVE 内网部署两个 AdGuardHome 实例（国内/国外分流），实现无 DNS 泄漏 + 广告过滤 + 国内 2000Mbps 直连 + 国外代理。

---

## 目录

- [网络架构](#网络架构)
- [核心设计原则](#核心设计原则)
- [DNS 完整流向](#dns-完整流向)
- [性能优化架构](#性能优化架构)
- [OpenClash UCI 预配置说明](#openclash-uci-预配置说明)
- [Nikki 备用方案](#nikki-备用方案)
- [问题排查与修复记录](#问题排查与修复记录)
- [IPv6 泄漏防护](#ipv6-泄漏防护)
- [模块化架构说明](#模块化架构说明)
- [常用排查命令](#常用排查命令)
- [注意事项](#注意事项)

---

## 网络架构

```
客户端 (LAN)
  │
  ▼
172.16.3.16  主路由 (OpenWrt + OpenClash + Clash Meta 内核)
  │               ┌─ nftables tproxy 拦截所有流量
  │               ├─ china_ip_route=1 → 国内IP内核层bypass，不进Clash
  │               ├─ DNS 监听 :7874 (Clash内部DNS)
  │               └─ dnsmasq(:53) → 127.0.0.1#7874 (noresolv)
  │
  ├── 172.16.3.6  国外 AdGuardHome（广告过滤 + 外国 DNS）
  │                上游：https://1.1.1.1/dns-query (DoH, IP形式)
  │                      https://8.8.8.8/dns-query
  │                      https://9.9.9.9/dns-query
  │                ⚠️ .6 所有流量强制走代理组「国外」
  │
  └── 172.16.3.7  国内 AdGuardHome（广告过滤 + 国内 DNS）
                   上游：https://223.5.5.5/dns-query
                         https://119.29.29.29/dns-query
                   ✓ .7 所有流量 DIRECT（内网直达）

以上三个虚拟机均运行于 172.16.0.223 PVE 物理主机
```

---

## 核心设计原则

### 1. 国内 2000Mbps 性能保障

```
china_ip_route=1
  → OpenClash 在 nftables 层加载 China IP 段到 bypass set
  → 目标为国内 IP 的数据包在 mangle 链直接 RETURN
  → 不经 Clash 用户态 → 内核速转发 → 2000Mbps 满速
```

### 2. 无 DNS 泄漏

```
enable_redirect_dns=1  → 劫持所有 53 端口流量到 Clash DNS(:7874)
dnsmasq_noresolv=1     → dnsmasq 禁止查询 ISP DNS
skip_proxy_address=0   → 禁止自动 bypass DNS 服务器 IP

结果：所有 DNS 查询必经 Clash → nameserver-policy 分流 → .7(CN) / .6(国外)
```

### 3. .6 死循环修复（关键）

**问题链：**
```
.6 AdGuardHome → 查上游 8.8.4.4:443
  → .6 流量被 tproxy 拦截进入 Clash
  → 如果走 DIRECT → 运营商封锁直连境外 DNS → timeout
  → 如果无规则 → MATCH → 国外代理组 → 代理节点域名需解析 → 依赖 .6 → 死循环
```

**解决方案（三管齐下）：**

| 配置位置 | 规则 | 作用 |
|----------|------|------|
| clash.yaml rules | `SRC-IP-CIDR,172.16.3.6/32,国外,no-resolve` | .6 流量强制走代理组 |
| clash.yaml dns | `proxy-server-nameserver: [172.16.3.7]` | 代理节点域名解析走 .7（内网直达） |
| OpenClash UCI | `skip_proxy_address='0'` | 禁止自动 bypass .6 IP |

**解析顺序（无循环）：**
```
1. Clash 启动 → 需解析代理节点域名 server.example.com
2. proxy-server-nameserver → 172.16.3.7 → 内网直达 → 返回代理IP ✓
3. 代理连接建立
4. .6 查询 8.8.4.4:443 → 被 tproxy → SRC-IP-CIDR 匹配 → 走已建立的代理 ✓
```

### 4. .7 安全直连

```yaml
rules:
  - SRC-IP-CIDR,172.16.3.7/32,DIRECT,no-resolve   # .7上游是国内DNS，直连无问题
```

---

## DNS 完整流向

### 国外域名查询（如 youtube.com）

```
客户端查询 youtube.com
    ↓
dnsmasq(:53) → 转发到 127.0.0.1#7874
    ↓
Clash DNS(:7874, redir-host 模式)
    ↓ 不匹配 nameserver-policy → 用 nameserver → 172.16.3.6
.6 AdGuardHome 收到查询
    ↓ 广告过滤规则生效（拦截广告域名）
    ↓ 查上游 https://1.1.1.1/dns-query (DoH, 443端口)
.6 → 1.1.1.1:443 流量被 tproxy 拦截
    ↓ SRC-IP-CIDR,172.16.3.6/32 → 走代理组「国外」
    ↓ 代理节点转发 → 1.1.1.1 返回 youtube 真实IP
    ↓
Clash 获得真实IP → 返回给客户端
客户端访问 youtube 真实IP
    ↓ 被 tproxy 拦截 → RULE-SET 匹配 YouTube → 走代理 ✓
```

### 国内域名查询（如 baidu.com）

```
客户端查询 baidu.com
    ↓
dnsmasq(:53) → 转发到 127.0.0.1#7874
    ↓
Clash DNS → 匹配 nameserver-policy "geosite:cn" → 用 172.16.3.7
.7 AdGuardHome 收到查询
    ↓ 广告过滤规则生效
    ↓ 查上游 https://223.5.5.5/dns-query (国内DoH，直连可达)
返回 baidu 真实IP
    ↓ china_ip_route bypass set 命中 → nftables RETURN → 内核直转
    ↓ 不经 Clash 用户态 → 2000Mbps 满速 ✓
```

### 代理节点域名解析

```
Clash 需连接代理节点 server.holytechx.com
    ↓
proxy-server-nameserver → 172.16.3.7 (内网直达，不经 tproxy)
    ↓ .7 查上游 223.5.5.5 → 返回代理IP
Clash 拿到代理IP → 建立 TCP 连接 → 正常工作 ✓
```

---

## 性能优化架构

> 目标场景：5Gbps 网卡 + 3×2G 宽带聚合（≈6Gbps），i7-9700K，追求极致带宽。

### netopt.sh（网络性能优化服务）

安装路径：`/etc/init.d/netopt`，开机自启 (START=99)。一次性配置内核网络栈 + 每张物理网卡。

#### TCP/IP 协议栈调优

| 参数 | 值 | 作用 |
|------|------|------|
| `tcp_congestion_control` | **bbr** | 消除 CUBIC 慢启动，2-3 秒达满速（解决"个位数慢慢涨"） |
| `default_qdisc` | **fq** | BBR 精确 pacing 必需 |
| `tcp_rmem / tcp_wmem max` | **64MB** | BDP=5Gbps×30ms=18.75MB，留足余量 |
| `tcp_slow_start_after_idle` | **0** | 空闲连接恢复不重新慢启动 |
| `initcwnd / initrwnd` | **128**（所有默认路由）| 首包即 192KB，多 WAN 全部生效 |
| `netdev_max_backlog` | **50000** | 5Gbps 突发不丢包 |
| `netdev_budget` | **1200** | NAPI 单次 poll 处理更多包 |
| `nf_conntrack_max` | **524288** | 多 WAN × 大量连接 |
| `nf_conntrack_tcp_timeout_established` | **7200s** | 快速释放过期连接（默认 5 天） |
| `ip_local_port_range` | **1024-65535** | 多 WAN 出站端口 28k→64k |
| `tcp_tw_reuse` / `tcp_fin_timeout` | **1 / 15s** | TIME_WAIT 快速回收 |
| `rp_filter` | **0** | 多 WAN 非对称路由兼容 |
| `bridge-nf-call-*` | **0** | bridge 帧不过 nftables，减少开销 |
| `rps_sock_flow_entries` | **65536** | per-flow CPU 亲和，减少 cache miss |

#### 每张物理网卡调优

| 优化项 | 说明 |
|--------|------|
| CPU governor → performance | 禁止降频，保持峰值主频 |
| multiqueue 激活 (`ethtool -L`) | 多队列分散到多核（**依赖 PVE VM 配置多队列**，见下） |
| Ring buffer 最大化 (`ethtool -G`) | 吸收调度抖动，避免丢包 |
| 硬件卸载 GRO/GSO/TSO/csum/sg | 批处理 64KB super-packet，降低每包 CPU 开销 |
| **LRO = off** | LRO 聚合的 super-frame 无法被转发拆分，与路由/tproxy 冲突 |
| 中断合并 (`ethtool -C` adaptive) | 5Gbps 减少 ~400k 中断/秒 |
| txqueuelen = 5000 | 5Gbps TX 队列不溢出 |
| MSI-X IRQ 多核绑定 | 每队列 IRQ 轮询到不同 CPU，避免全堆 CPU0 |

### 软件流量卸载（Flow Offload）— 打破国内直连瓶颈的关键

文件：`diy/modules/20-firewall.sh`

```bash
firewall.@defaults[0].flow_offloading=1      # 软件卸载：开启
firewall.@defaults[0].flow_offloading_hw=0   # 硬件卸载：关闭（破坏 tproxy）
```

**为什么软件卸载能与 OpenClash 共存？**（数据通路分析）

| 流量类型 | netfilter 路径 | flowtable 是否命中 |
|----------|----------------|---------------------|
| 代理流量 | tproxy 在 PREROUTING 标记 → 路由到本机 Clash socket → **INPUT 链** | ❌ 不命中（不走 forward） |
| 国内 bypass 流量 | china_ip_route RETURN → **FORWARD 链** → NAT | ✅ 命中并加速 |

软件 flowtable 只挂在 **FORWARD 链**，因此**只加速国内直连流量，完全不碰代理流量**。这是 x86 软路由国内跑满线速的核心机制，对 **PPPoE 宽带尤其重要**（新内核软件卸载同时加速 PPPoE 封包/解包）。

> 若个别代理站点异常（罕见，与 OpenClash 版本有关），回退：
> `uci set firewall.@defaults[0].flow_offloading=0 && uci commit firewall && /etc/init.d/firewall restart`

### 构建配置关键项

```
CONFIG_KERNEL_PREEMPT_NONE=y                 # 关闭内核抢占，最大吞吐（少 context switch）
CONFIG_PACKAGE_kmod-tcp-bbr=y                # BBR 拥塞控制
CONFIG_PACKAGE_kmod-sched-fq=y               # fq 队列调度器（BBR pacing 必需）
CONFIG_PACKAGE_kmod-nft-flow-offload=y       # nftables 软件流量卸载
CONFIG_KERNEL_CC_OPTIMIZE_FOR_PERFORMANCE=y  # 内核编译 -O2 优化
CONFIG_TARGET_ROOTFS_PARTSIZE=1024           # 足够空间存放核心+规则集
```

---

## ⚠️ 重要：x86 软路由 400M 瓶颈诊断（OpenWrt 配置无法解决的层面）

> **场景：bypass 已生效、CPU 是 i7-9700K（8 核 4.9GHz），国内测速仍卡 400M。**

i7-9700K 纯内核转发可轻松跑 **10Gbps 线速**。如果 bypass 国内流量仍卡 400M，**根因 100% 不在 OpenWrt 的 sysctl 参数**（那些只影响代理/TCP 收敛），而在以下数据通路层面。请逐项排查：

### ① PVE 虚拟机 virtio 多队列未开启（最常见）

netopt 用 `ethtool -L` 激活多队列，但**前提是 PVE VM 配置里给了多队列**。若 PVE VM 网卡 `queues=1`，则所有流量挤在单 vCPU。

**PVE 宿主机修复**（`/etc/pve/qemu-server/<vmid>.conf`）：
```
net0: virtio=XX:XX:XX:XX:XX:XX,bridge=vmbr0,queues=8
```
> queues 设为 vCPU 数量（9700K 给 8）。改后重启 VM，再确认 `ethtool -l ethX` 的 Combined 已 >1。

### ② PPPoE 宽带单线程瓶颈

中国宽带多为 PPPoE 拨号。PPPoE 封装历史上是**单 CPU 处理**，无卸载时单核可能卡在 400-940M。

**修复：**
- 已通过 `flow_offloading=1` 启用软件卸载（新内核加速 PPPoE 通路）
- 确认内核版本 ≥ 5.10（支持 PPPoE flowtable offload）
- 验证：`nft list ruleset | grep -i flow` 应能看到 flowtable 规则

### ③ 物理网卡链路协商 / 直通方式

- **虚拟机内 virtio**：宿主机 vmbr 桥接本身有开销，5Gbps 建议**网卡 PCI 直通（passthrough）**给 OpenWrt VM，绕过 vmbr
- 确认 5G 网卡实际协商速率：`ethtool ethX | grep Speed`（应为 5000Mb/s，若为 1000/2500 则是网线/交换机/对端口限制）
- 检查错误/重传：`ethtool -S ethX | grep -iE 'error|drop|discard'`

### ④ 测速方法本身

- **单线程测速受 RTT + 单连接窗口限制**，并非真实带宽上限
- 用**多线程测速**：speedtest-cli `--threads` 或网页版 multi-connection
- 路由器本机直测（排除客户端瓶颈）：`iperf3 -c <国内iperf服务器> -P 8`
- 确认对端服务器/源站本身不限速

### ⑤ 客户端侧瓶颈

- 客户端网卡是否千兆？（1G 网卡最高 ~940M）
- 客户端到路由器的网线/交换机是否千兆/2.5G/5G？
- 无线客户端：Wi-Fi 实际吞吐远低于标称

### 诊断命令速查

```bash
# 1. 确认多队列已激活（Combined 应 = vCPU 数）
ethtool -l ethX

# 2. 确认链路协商速率
ethtool ethX | grep Speed

# 3. 确认软件流量卸载已生效
nft list ruleset | grep -i flowtable

# 4. 确认网卡无丢包/错误
ethtool -S ethX | grep -iE 'error|drop|discard|fifo'

# 5. 本机直接压测（排除客户端因素，需国内 iperf3 服务器）
iperf3 -c <server> -P 8 -t 30

# 6. 实时观察各 CPU 软中断负载（看是否单核打满）
mpstat -P ALL 1     # 或 top 按 1 展开各核
```

> **结论：** 对 9700K 而言，OpenWrt 侧已优化到极致。剩余 400M 瓶颈几乎必然来自 **①virtio 单队列 / ②PPPoE 单线程 / ③链路协商 / ④单线程测速** 之一。按上表逐项验证即可定位。

---

## 🎯 实战定位：PVE 虚拟机 + PPPoE 拨号（已配 queues=8）

> 确认环境：PVE 虚拟机、PPPoE 拨号、virtio `queues=8` 已配、交换机无瓶颈、i7-9700K。
> 此组合下 ①virtio 队列、③交换机 已排除，**焦点锁定 PPPoE 单线程处理**。

### PPPoE 为什么是瓶颈

```
物理 virtio 网卡(8队列,8核) → PPPoE 解封装(pppoe-wan) → FORWARD链 → LAN
                                      ↑
   pppoe-wan 是单一逻辑设备，无 flow offload 时每个包都需 CPU 逐个解封装，
   且解封装后的处理倾向于串行到单核 → 单核打满即为吞吐天花板。
```

### 本工程的两层 PPPoE 加速（已落地）

| 层级 | 机制 | 文件 |
|------|------|------|
| **1. 软件流量卸载** | `flow_offloading=1`：已建立的连接走 flowtable 快速通路，跳过逐包 PPPoE 解封装。新内核 flowtable 原生支持 PPPoE 设备 | `20-firewall.sh` |
| **2. PPPoE 接口 RPS** | netopt 对 `pppoe-wan`/`ppp*` 接口施加 RPS + 增大 txqueuelen，把解封装后的软中断分散到 8 核（之前被显式跳过，现已修复） | `netopt.sh` |

> 配合物理 virtio 网卡的 8 队列 + RPS，不同 TCP 流落到不同 CPU，PPPoE 处理从"单核串行"变为"8 核并行"。

### 验证 PPPoE 加速是否生效

```bash
# 1. 确认 flowtable 包含 pppoe-wan 设备（关键！）
nft list ruleset | grep -A3 flowtable
# 期望输出含: devices = { eth0, pppoe-wan, ... }
# 若 devices 里没有 pppoe-wan → flow offload 未覆盖 WAN，需检查防火墙 WAN 区域

# 2. 确认 pppoe-wan 已应用 RPS（应为非 0 的 CPU 掩码，如 ff = 8核）
cat /sys/class/net/pppoe-wan/queues/rx-0/rps_cpus

# 3. 测速时观察是否单核打满（PPPoE 瓶颈的典型特征）
mpstat -P ALL 1
# 若某一核 %soft（软中断）接近 100% 而其他核空闲 → PPPoE 仍串行在单核
# 若 8 核软中断均摊 → 加速生效 ✓

# 4. 确认内核版本支持 PPPoE flowtable offload（≥ 5.10）
uname -r
```

### 若验证后仍单核打满（进阶手段）

1. **MSS / MTU 修复**：PPPoE MTU=1492。确认 WAN 口 `mtu_fix` 已开（OpenWrt 默认开），避免分片：
   ```bash
   uci show firewall | grep mtu_fix     # wan 区域应为 '1'
   ```

2. **网卡 PCI 直通（终极方案）**：PVE 中把物理网卡直通给 OpenWrt VM（而非 virtio + vmbr），由 OpenWrt 直接拨 PPPoE：
   - 消除 vmbr 桥接开销
   - 物理网卡的硬件多队列/RSS 直接对 PPPoE 生效
   - 这是 x86 软路由 PPPoE 跑满 2Gbps+ 的最稳方案

3. **确认 PPPoE 单线程测速 vs 多线程**：单条 PPPoE 拨号 2Gbps，用 8 线程测速才能体现 flow offload + 多核效果：
   ```bash
   iperf3 -c <国内iperf3> -P 8 -t 30
   ```

### 预期结果

```
修复前: PPPoE 单核串行 + CUBIC 慢启动 → 400M（个位数慢慢涨）
修复后:
  ├─ BBR + 64MB buffer + initcwnd=128 → 消除慢启动，秒达峰值
  ├─ flow_offloading=1 → 跳过逐包 PPPoE 解封装
  └─ pppoe-wan RPS + 物理网卡 8 队列 → 解封装分散到 8 核
  = 单条 PPPoE 跑满 2Gbps，3 条聚合接近 NIC 上限
```

---

## 性能优化补充配置

```
CONFIG_TARGET_KERNEL_PARTSIZE=256
```


---

## OpenClash UCI 预配置说明

文件：`diy/modules/30-openclash.sh`

首次启动时自动执行，将 UCI 值与 `clash-all-noicon-clash.yaml` 同步，**防止 LuCI 界面覆写关键配置**。

### 关键 UCI 设置解释

| UCI 键 | 值 | 作用 |
|---------|------|------|
| `config_path` | `/etc/openclash/config/clash-all-noicon-clash.yaml` | 指定使用我们的 yaml |
| `operation_mode` | `redir-host` | 配合 AdGuardHome 广告过滤 |
| `china_ip_route` | `1` | nftables 层 bypass 国内 IP → 内核直转线速 |
| `enable_redirect_dns` | `1` | 劫持所有 53 流量到 Clash DNS |
| `dnsmasq_noresolv` | `1` | 禁止 dnsmasq 查 ISP DNS |
| `skip_proxy_address` | `0` | 禁止自动 bypass DNS 服务器 IP |
| `bypass_gateway_compatible` | `0` | 关闭网关兼容（避免自动 bypass .6） |
| `enable_respect_rules` | `0` | 关闭（.6 流量已由 nftables + SRC-IP-CIDR 保护） |
| `ipv6_enable` | `1` | IPv6 代理，国内直连国外走代理 |
| `ipv6_dns` | `1` | DNS 返回 AAAA 记录 |
| `core_type` | `Meta` | 使用 mihomo 内核 |
| `core_version` | `linux-amd64-v1` | 最大兼容性（无 SSE4.2/AVX2 依赖） |
| `disable_udp_quic` | `1` | 禁用 QUIC 强制走 TCP（代理更稳定） |
| `router_self_proxy` | `1` | 路由器自身流量也走规则 |


### respect-rules 为什么关闭？

```
respect-rules: true  → 每个 DNS 查询都二次遍历 rules 列表
respect-rules: false → DNS 查询仅走 nameserver/nameserver-policy

.6 的上游流量保护由以下两层保障：
1. nftables tproxy 拦截 .6 所有出站流量
2. SRC-IP-CIDR,172.16.3.6/32,国外 → 强制走代理

无需 Clash 内部 DNS 层再做一次规则匹配 → 减少延迟
```

---

## Nikki 备用方案

文件：`diy/modules/35-nikki.sh` + `nikki-config.yaml`

Nikki（luci-app-nikki）是 mihomo 的另一个 LuCI 前端，作为 OpenClash 的备用方案。

### 端口分配（避免冲突）

| 服务 | OpenClash | Nikki (OpenClash +10) |
|------|-----------|----------------------|
| HTTP | 7890 | 7900 |
| SOCKS | 7891 | 7901 |
| Redir | 7892 | 7902 |
| Mixed | 7893 | 7903 |
| TProxy | 7895 | 7905 |
| DNS | 7874 | 7884 |
| API | 9090 | 9091 |

### 切换方式

```bash
# 切换到 Nikki
/etc/init.d/openclash stop
uci set nikki.config.enabled='1'
uci commit nikki
/etc/init.d/nikki start

# 切换回 OpenClash
/etc/init.d/nikki stop
uci set nikki.config.enabled='0'
uci commit nikki
/etc/init.d/openclash start
```

> ⚠️ 两者不能同时运行（共用 tproxy 链 + 端口冲突）

---

## 问题排查与修复记录

### 问题一：所有国外网站 timeout

**症状：** OpenClash 启动后，所有国外网站无法访问，停止后恢复正常。

**根因链：**
```
原始配置中：SRC-IP-CIDR,172.16.3.6/32,DIRECT
→ .6 所有流量走直连
→ .6 上游 DNS 查询（8.8.4.4:853 DoT）走直连
→ 运营商封锁直连境外 DNS 端口 → timeout
→ OpenClash nameserver 是 .6 → 无法解析境外域名
→ 所有境外访问失败
```

**修复：**
1. 删除 `.6` 的 DIRECT 规则
2. 添加 `SRC-IP-CIDR,172.16.3.6/32,国外,no-resolve`（强制走代理）
3. .6 上游改为 DoH IP 形式（443 端口）

---

### 问题二：.6 上游 DoT 853 端口被封

**症状：** 日志 `dial 国外 172.16.3.6 --> 8.8.4.4:853 i/o timeout`

**原因：** 大多数机场服务器封锁出站 853 端口（防 DNS 滥用）

**修复：** AdGuardHome .6 上游改为 DoH（443端口）：
```
https://1.1.1.1/dns-query
https://8.8.8.8/dns-query
https://9.9.9.9/dns-query
```

**不推荐的形式：**
```
tls://dns.cloudflare.com       ← 域名形式 + 853端口，双重问题
tls://1.1.1.1                  ← IP形式但853端口，机场封锁
https://dns.cloudflare.com/dns-query  ← 域名形式，Clash解析循环依赖
```

---

### 问题三：.6 走 DIRECT 到 8.8.4.4:443 timeout

**症状：** `dial DIRECT 172.16.3.6 --> 8.8.4.4:443 i/o timeout`

**原因：** OpenClash `skip_proxy_address` 自动将 DNS IP 加入 bypass → .6 走 DIRECT → 运营商封锁

**修复（三处）：**

1. **clash.yaml rules 顶部添加：**
```yaml
- SRC-IP-CIDR,172.16.3.6/32,国外,no-resolve   # 强制走代理
```

2. **OpenClash UCI：**
```bash
uci set openclash.config.skip_proxy_address='0'    # 禁止自动bypass
uci set openclash.config.bypass_gateway_compatible='0'
```

3. **proxy-server-nameserver 仅用 .7：**
```yaml
proxy-server-nameserver:
  - 172.16.3.7    # 内网直达，不依赖代理
```

---

### 问题四：订阅鸡蛋问题

**症状：** 订阅 URL 是境外地址，需要代理下载；但无节点无法代理 → 循环。
首次启动节点数为 0、无法访问国外网站。

**设计目标：** 开箱填一次订阅地址即用；自动定期更新；最多首次手动 bootstrap 一次，之后永不手动介入。

**provider 正确写法（本仓库已默认配置）：** `type: http` 提供 `url` 自动定期更新，同时用
`path` 做本地缓存——mihomo 启动时先读缓存（节点立即可用），再后台按 `interval` 自动更新：

```yaml
proxy-providers:
  cc-auto:
    type: http
    url: "你的机场订阅地址"           # 构建时由 CLASH_SUB_URL 注入，或刷机后在界面/YAML 填写
    path: "/etc/openclash/config/providers/cc-auto.yaml"   # 本地缓存
    interval: 86400                  # 每 24 小时自动更新
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: 300
```

**开箱即用：填一次订阅地址**

- 方式 A（推荐，构建时注入）：在 GitHub 仓库 Settings → Secrets and variables → Actions
  新增变量/密钥 `CLASH_SUB_URL`，值为订阅地址。`build-openclash.sh` 会把 YAML 里的占位符
  `__CLASH_SUB_URL__` 替换为该地址，刷机即用。
- 方式 B（刷机后）：在 OpenClash 界面或编辑
  `/etc/openclash/config/clash-all-noicon-clash.yaml`，把 `url` 改成订阅地址。

**首次 bootstrap（仅当订阅地址需代理才能下载时，做一次）：**
```bash
# 停止 OpenClash（绕开 tproxy）
/etc/init.d/openclash stop

# 手动下载订阅到 path 指定的缓存文件（仅这一次）
mkdir -p /etc/openclash/config/providers
curl -L -o /etc/openclash/config/providers/cc-auto.yaml "你的机场订阅地址"

# 确认是 clash 格式且含 proxies 列表
grep -c '^\s*-\s' /etc/openclash/config/providers/cc-auto.yaml   # 节点条目数应 > 0

# 重启：mihomo 先用缓存出网，之后按 interval 全自动更新，无需再手动介入
/etc/init.d/openclash start
```

> bootstrap 后节点已可用，mihomo 会按 `interval: 86400` 每 24 小时自动从 `url` 更新订阅；
> 失败时保留旧缓存，不会清空节点。若订阅地址在国内可直达，则连 bootstrap 都不需要，开箱即用。

**运行中强制刷新订阅：**
```bash
curl -X PUT "http://127.0.0.1:9090/providers/proxies/cc-auto" \
  -H "Authorization: Bearer oc_6Qf9v2LmP8xT4rN1kY7sDz3aH5uWc"
```

---

### 问题五：LEDE 打包 ext4 out of space

**症状：** `ext4_allocate_best_fit_partial: failed to allocate 2671 blocks`

**修复：** ROOTFS 从 500MB 调大到 1024MB：
```
CONFIG_TARGET_ROOTFS_PARTSIZE=1024
```

---

### 问题六：netopt.sh 从未执行

**症状：** CPU 始终降频，IRQ 全堆 CPU0

**原因：** shebang 错误 `#!/bin/sh /bin/sh` → 应为 `#!/bin/sh /etc/rc.common`

**修复：** 重写 netopt.sh，使用正确的 OpenWrt init 格式。

---

## IPv6 泄漏防护

### 方案：开启 IPv6 代理（推荐）

OpenClash 原生支持 IPv6 tproxy，行为与 IPv4 完全一致：

```bash
# UCI 预配置（30-openclash.sh 已包含）
uci set openclash.config.ipv6_enable='1'
uci set openclash.config.ipv6_dns='1'
```

YAML 对应：
```yaml
ipv6: true          # 全局 IPv6 代理
dns:
  ipv6: true        # DNS 返回 AAAA 记录
```

### 规则行为

| 流量类型 | 处理方式 |
|----------|----------|
| 国内 IPv6（China/IP 含 IPv6 段）| DIRECT ✓ |
| 国外 IPv6（GeoLocation-!CN、MATCH）| 代理 ✓ |
| 本地 IPv6（fc00::/7、fe80::/10）| DIRECT ✓ |
| ::1/128 loopback | DIRECT ✓ |

### yaml 中的 IPv6 本地地址直连规则

```yaml
rules:
  - IP-CIDR6,::1/128,DIRECT,no-resolve
  - IP-CIDR6,fc00::/7,DIRECT,no-resolve
  - IP-CIDR6,fe80::/10,DIRECT,no-resolve
  - MATCH,国外    # 其余IPv6跟随规则：国外走代理
```

### nftables 层（自动）

OpenClash 启用 `ipv6_enable=1` 后自动创建 `openclash_mangle_v6` 链，无需手写 ip6tables 规则。

### 验证

浏览器访问：
- https://browserleaks.com/ip
- https://ipleak.net
- https://ipv6leak.com

正常结果：**只显示代理节点 IP，无真实 IPv6 地址暴露**。

---

## 模块化架构说明

### 目录结构

```
diy/
├── modules/                    # 首次启动执行的模块（进镜像）
│   ├── 10-system.sh           # 系统基础设置（hostname, timezone, feeds...）
│   ├── 20-firewall.sh         # 防火墙默认值
│   ├── 30-openclash.sh        # OpenClash UCI 预配置
│   ├── 35-nikki.sh            # Nikki UCI 预配置
│   └── 40-cleanup.sh          # 服务清理（禁用无用服务）
├── scripts/                    # 构建时脚本（不进镜像）
│   └── build-openclash.sh     # 下载 clash_meta 核心 + 安装配置
├── common/
│   ├── netopt.sh              # 网络性能优化（/etc/init.d/netopt）
│   ├── default-settings       # zzz-default-settings 调度器
│   └── *.config               # 编译配置
└── config/
    └── 99-custom-firewall     # 自定义防火墙规则
```

### 模块执行顺序

`zzz-default-settings` 作为调度器，按文件名排序执行 `modules/` 下所有 `.sh`：

```bash
for mod in /etc/openclash/modules/*.sh; do
    . "$mod"
done
```

### 新增模块

创建 `diy/modules/NN-name.sh`（NN 为两位数序号），无需修改调度器。

---

## 关键配置对照表

| 配置项 | 错误做法 | 正确做法 | 原因 |
|--------|----------|----------|------|
| `.6` 流量规则 | `SRC-IP-CIDR,.6,DIRECT` | `SRC-IP-CIDR,.6,国外,no-resolve` | DIRECT→运营商封境外DNS→timeout |
| `.6` 上游 DNS | `tls://dns.cloudflare.com` | `https://1.1.1.1/dns-query` | IP形式消除循环 + 443端口不封 |
| `.6` 上游端口 | DoT (853) | DoH (443) | 机场封锁853出站 |
| DNS 劫持 | 不劫持/默认 | `enable_redirect_dns=1` | 确保所有DNS经Clash分流 |
| dnsmasq | 允许查ISP DNS | `dnsmasq_noresolv=1` | 杜绝DNS泄漏 |
| 地址bypass | 自动bypass DNS IP | `skip_proxy_address=0` | 防止.6被自动直连 |
| DNS 模式 | fake-ip | redir-host | 配合AdGuardHome广告过滤 |
| respect-rules | 开启 | 关闭 | .6已由SRC-IP-CIDR+nftables保护 |
| 代理节点DNS | 含.6或境外DNS | 仅 `172.16.3.7` | 内网直达打破循环 |
| IPv6 | block所有 | 开启IPv6代理 | 国内IPv6直连+国外走代理 |
| China IP | 经Clash用户态 | `china_ip_route=1` | nftables层bypass→2000Mbps |

---

## AdGuardHome 配置要点

### .6（国外）配置

访问：`http://172.16.3.6:3000`

**上游 DNS 服务器：**
```
https://1.1.1.1/dns-query
https://8.8.8.8/dns-query
https://9.9.9.9/dns-query
```

**Bootstrap DNS 服务器：**（上游已是IP形式，可留空）

**DNS 设置：**
- 监听端口：53
- 速率限制：0（内网无需限制）
- 启用 DNSSEC：是

### .7（国内）配置

访问：`http://172.16.3.7:3000`

**上游 DNS 服务器：**
```
https://223.5.5.5/dns-query
https://119.29.29.29/dns-query
```

**DNS 设置：**
- 监听端口：53
- 速率限制：0
- 启用 DNSSEC：是

---

## 常用排查命令

```bash
# 查看 Clash 核心实时日志
tail -f /tmp/openclash.log

# 查看 OpenClash 完整 UCI 配置
uci show openclash

# 查看 nftables tproxy 规则
nft list chain inet fw4 openclash_mangle
nft list chain inet fw4 openclash_mangle_v6

# 查看 china_ip bypass set 条目数
nft list set inet fw4 openclash_cn_ip | wc -l

# 手动更新订阅（OpenClash运行中）
curl -X PUT "http://127.0.0.1:9090/providers/proxies/cc-auto" \
  -H "Authorization: Bearer oc_6Qf9v2LmP8xT4rN1kY7sDz3aH5uWc"

# 重启 OpenClash
/etc/init.d/openclash restart

# 停止 OpenClash（验证问题来源）
/etc/init.d/openclash stop

# 测试代理是否工作
curl -x socks5h://127.0.0.1:7891 -m 10 https://www.google.com -o /dev/null -w "%{http_code}\n"

# 查看 netopt 服务状态
/etc/init.d/netopt status
logread | grep netopt

# 查看 CPU governor
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor

# 查看 IRQ 分布
cat /proc/interrupts | head -20

# DNS 泄漏测试（应只返回代理节点IP）
nslookup youtube.com 127.0.0.1
```

---

## 注意事项

1. **机场选择**：确认机场允许 DoH 流量（443端口）通过，绝大多数机场允许。
2. **订阅缓存**：首次使用需手动下载订阅（见问题四），之后自动更新。
3. **OpenClash 版本**：本教程基于 OpenClash + Clash Meta (mihomo) 内核，纯 Clash Premium 内核行为不同。
4. **DNS 泄漏**：redir-host 模式下，.6 上游 DoH 查询经代理到达 1.1.1.1，运营商无法看到查询内容。
5. **PVE 网关**：.6/.7 的网关是主路由 .16，`proxy-server-nameserver` 仅配 .7（内网直达），首次启动无死循环。
6. **firewall4**：本方案基于 nftables (firewall4)，兼容 Official OpenWrt 23.x+ 和支持 firewall4 的 LEDE。
7. **同时只运行一个**：OpenClash 和 Nikki 不能同时运行，切换前必须先停止当前服务。
