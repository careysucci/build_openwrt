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
- [HomeProxy 备用方案](#homeproxy-备用方案)
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
Clash 需连接代理节点 server.example-proxy.com
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
| `initcwnd / initrwnd` | **内核默认** | 避免过大初始突发触发丢包和拥塞窗口回退 |
| `netdev_max_backlog` | **5000** | 吸收合理突发且避免 bufferbloat |
| `netdev_budget / budget_usecs` | **300 / 2000** | 避免长时间 softirq 阻塞 virtio TX completion |
| `nf_conntrack_max` | **524288** | 多 WAN × 大量连接 |
| `nf_conntrack_tcp_timeout_established` | **7200s** | 快速释放过期连接（默认 5 天） |
| `ip_local_port_range` | **1024-65535** | 多 WAN 出站端口 28k→64k |
| `tcp_tw_reuse` / `tcp_fin_timeout` | **1 / 15s** | TIME_WAIT 快速回收 |
| `rp_filter` | **0** | 多 WAN 非对称路由兼容 |
| `bridge-nf-call-*` | **0** | bridge 帧不过 nftables，减少开销 |
| `rps_sock_flow_entries` | **0** | 使用 virtio/RSS 原生队列亲和，避免二次跨核 |

#### 每张物理网卡调优

| 优化项 | 说明 |
|--------|------|
| CPU governor → performance | 禁止降频，保持峰值主频 |
| multiqueue | 保留驱动/PVE 配置，不在运行时重建队列 |
| Ring buffer 最大化 (`ethtool -G`) | 仅物理网卡使用；virtio 保留驱动默认值 |
| 硬件卸载 GRO/GSO/TSO/csum/sg | 批处理 64KB super-packet，降低每包 CPU 开销 |
| **LRO = off** | LRO 聚合的 super-frame 无法被转发拆分，与路由/tproxy 冲突 |
| 中断合并 (`ethtool -C` adaptive) | 仅支持 adaptive 的物理网卡使用，virtio 跳过 |
| txqueuelen = 1000 | 保持正常队列长度，避免持续排队延迟 |
| IRQ 管理 | 统一交给 irqbalance，不与手动 affinity 混用 |

### 软件快速转发—打破国内直连瓶颈的关键

文件：`diy/modules/20-firewall.sh`

LEDE 使用 TurboACC SFE，Official 使用 nft software flow offload；两条路径互斥，硬件 offload 始终关闭。

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

### 本工程的 PPPoE 加速

| 层级 | 机制 | 文件 |
|------|------|------|
| **1. 软件快速转发** | LEDE 使用 SFE；Official 使用 nft flowtable；二者不会同时启用 | `20-firewall.sh` |
| **2. 原生多队列亲和** | 保留 virtio/RSS 队列映射并由 irqbalance 管理 IRQ；不再强制全核 RPS，避免跨核、乱序和 cache 抖动 | `netopt.sh` |

> PVE 中应在 VM 配置层启用 virtio 多队列，并让 guest 的 irqbalance 管理队列 IRQ。

### 验证 PPPoE 加速是否生效

```bash
# 1. 确认 flowtable 包含 pppoe-wan 设备（关键！）
nft list ruleset | grep -A3 flowtable
# 期望输出含: devices = { eth0, pppoe-wan, ... }
# 若 devices 里没有 pppoe-wan → flow offload 未覆盖 WAN，需检查防火墙 WAN 区域

# 2. 确认未强制全核 RPS（多队列环境应为 0）
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
  ├─ BBR + fq + 自动窗口 → 平稳建立拥塞窗口
  ├─ SFE 或 nft flowtable → 已建立连接走快速路径
  └─ virtio/RSS 多队列 + irqbalance → 保持队列和 CPU 亲和
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
| `china_ip6_route` | `1` | 同上（IPv6）：CN v6 在 mangle_v6 链 RETURN 内核直转，国外 v6 照常走代理（无泄露，实测验证） |
| `enable_redirect_dns` | `1` | 劫持所有 53 流量到 Clash DNS |
| `dnsmasq_noresolv` | `1` | 禁止 dnsmasq 查 ISP DNS（实为接管状态字段；真实防护在 dhcp 层 noresolv，由 watchdog 守护） |
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

## HomeProxy 备用方案

文件：`diy/modules/36-homeproxy.sh`

HomeProxy（luci-app-homeproxy）是基于 **sing-box** 内核的 LuCI 前端，作为 OpenClash / Nikki 之外的第三种备用方案。打包阶段由 `36-homeproxy.sh` 自动写入 `/etc/config/homeproxy`，LuCI 界面读取的就是这份 UCI，因此**界面与配置文件天然一致**。

### 与 clash.yaml 的对应关系

| 需求 | clash.yaml 做法 | homeproxy 做法（本模块） |
|------|----------------|--------------------------|
| 国内直连保速 | China/IP + China/Domain → DIRECT | `routing_mode='bypass_mainland_china'`（国内 IP/域名直连，不进 sing-box 用户态） |
| 国外走代理（含 YouTube） | GeoLocation-!CN / MATCH → 代理 | 默认出站 = 代理 |
| 国内 DNS | nameserver-policy geosite:cn → 172.16.3.7 | `china_dns_server='172.16.3.7'` |
| 国外 DNS（广告过滤） | nameserver → 172.16.3.6 | `dns_server='172.16.3.6'` |
| 无 DNS 泄漏 | 仅内网 AGH，dnsmasq_noresolv | 仅内网 AGH（.6/.7），不使用任何 ISP/公网 DNS |
| 无 IP 泄漏 | MATCH,国外 兜底 | 默认路由 = 代理；`sniff_override=1` 防 IP-only 漏判 |
| IPv6 | ipv6: true | `ipv6_support='1'` |
| 订阅 | proxy-providers cc-auto | `subscription` 段，复用同一 `CLASH_SUB_URL`（构建时注入） |

> 说明：homeproxy 按**目的地址**分流——`.6` 自身查询国外上游（DoH 1.1.1.1）时目的为国外地址，会被自动判定走代理；`.7` 查询国内上游目的为国内地址，自动直连。无需像 clash 那样手写 SRC-IP 规则。

### 默认禁用（安全）

与 Nikki 一致，homeproxy **默认禁用**（`main_node='nil'` + 服务 disable）。同一时间只能有一个透明代理占用 tproxy，OpenClash 仍是主力，**启用 homeproxy 不会自动发生，绝不影响当前网络与网速**。

### 切换方式

```bash
# 切换到 HomeProxy
/etc/init.d/openclash stop
/etc/init.d/nikki stop 2>/dev/null
# LuCI → HomeProxy → 节点：更新订阅 → 选择一个节点作为「主节点」
/etc/init.d/homeproxy enable
/etc/init.d/homeproxy start

# 切换回 OpenClash
/etc/init.d/homeproxy stop
/etc/init.d/homeproxy disable
/etc/init.d/openclash start
```

> ⚠️ OpenClash / Nikki / HomeProxy 三者互斥，任意时刻只启用一个。
> ⚠️ 启用后请用 `nslookup youtube.com` 与泄漏检测站点确认：DNS 只命中内网 .6/.7，出口仅显示代理节点 IP。

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

### 问题四：首次启动 / 订阅节点为 0 / 已刷 img 初始化

---

#### 4.1 设计说明：OpenClash 出厂默认禁用

**为什么禁用？**

OpenClash 启动后立即开启 tproxy。若此时 `proxy-providers` 尚无节点（空缓存），
所有外网流量（包括 `.6` AdGuardHome 的 DNS 上游查询）都会进入 Clash 规则引擎，
找不到可用节点 → **timeout → 断网**。

因此出厂固件将 OpenClash 默认设为 **禁用（disabled）**，
让用户在有网络的环境下完成订阅配置，再手动启用，避免循环依赖。

---

#### 4.2 proxy-providers URL 占位符设计

`clash-all-noicon-clash.yaml` 中使用的出厂占位 URL：

```yaml
proxy-providers:
  cc-auto:
    type: http
    url: "http://127.0.0.1:11111/subscription"   # 出厂占位，合法格式但本地不可达
    path: "/etc/openclash/config/providers/cc-auto.yaml"
    interval: 86400
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: 300
```

**为什么必须是合法 URL？**

mihomo（Meta 内核）在解析 YAML 时会校验 `proxy-providers` 的 `url` 字段格式。
若 URL 格式无效（如 `__CLASH_SUB_URL__`、空字符串），
**provider 整体初始化失败**，即使 `path` 缓存文件已手动放好，节点依然为 0。

`http://127.0.0.1:11111/subscription` 格式合法，连接会立即被拒绝（无人监听），
mihomo 此时回退读取 `path` 缓存文件，节点正常加载。

**当真实订阅 URL 已填入后（替换占位符）：**
mihomo 从真实 URL 拉取订阅，更新 `path` 缓存，按 `interval: 86400` 每天自动续期。

---

#### 4.3 首次启动标准流程（全新刷机）

```
1. 刷机 → 开机
   OpenClash 出厂禁用，无 tproxy → dnsmasq 用 ISP DNS → 网络完全正常

2. SSH 登录，停止 OpenClash（确保无 tproxy 干扰）
   /etc/init.d/openclash stop

3. 下载订阅文件到 path 指定路径
   mkdir -p /etc/openclash/config/providers
   curl -L -o /etc/openclash/config/providers/cc-auto.yaml "你的机场订阅地址"

   # 验证是 Clash YAML 格式，节点数 > 0
   head -3 /etc/openclash/config/providers/cc-auto.yaml
   grep -c '  - name:' /etc/openclash/config/providers/cc-auto.yaml

4. 在 OpenClash UI 或直接编辑 YAML，把 url 改为真实订阅地址
   /etc/openclash/config/clash-all-noicon-clash.yaml
     url: "https://你的机场订阅地址"    ← 替换占位符

5. 启用并启动 OpenClash
   /etc/init.d/openclash enable
   /etc/init.d/openclash start

结果：mihomo 读取 path 缓存 → 节点立即可用 → 按 interval 每天自动更新
```

**一条命令完成步骤 2–5（替换 YOUR_SUB_URL）：**

```bash
/etc/init.d/openclash stop && \
mkdir -p /etc/openclash/config/providers && \
curl -L -o /etc/openclash/config/providers/cc-auto.yaml "YOUR_SUB_URL" && \
grep -c '  - name:' /etc/openclash/config/providers/cc-auto.yaml && \
sed -i 's|url: "http://127.0.0.1:11111/subscription"|url: "YOUR_SUB_URL"|' \
    /etc/openclash/config/clash-all-noicon-clash.yaml && \
/etc/init.d/openclash enable && \
/etc/init.d/openclash start
```

---

#### 4.4 修复旧版已刷 img（URL 为无效占位符 `__CLASH_SUB_URL__`）

旧版固件的 YAML 使用了格式非法的占位符 `url: "__CLASH_SUB_URL__"`，
导致 provider 无法初始化，**手动放好订阅文件后节点仍为 0**。

**排查命令（判断是否受影响）：**

```bash
grep 'url:' /etc/openclash/config/clash-all-noicon-clash.yaml | head -3
# 若输出包含 __CLASH_SUB_URL__  → 需要执行下方修复
# 若输出为 http:// 或 https:// 开头 → 不受影响
```

**修复步骤：**

```bash
# 1. 停止 OpenClash
/etc/init.d/openclash stop

# 2. 修复无效占位符（改为合法的本地失败 URL）
sed -i 's|url: "__CLASH_SUB_URL__"|url: "http://127.0.0.1:11111/subscription"|' \
    /etc/openclash/config/clash-all-noicon-clash.yaml

# 3. 下载订阅（此时无 tproxy，可直连）
mkdir -p /etc/openclash/config/providers
curl -L -o /etc/openclash/config/providers/cc-auto.yaml "YOUR_SUB_URL"
grep -c '  - name:' /etc/openclash/config/providers/cc-auto.yaml   # 应 > 0

# 4. （推荐）把 url 改为真实地址，以后每天自动更新
sed -i 's|url: "http://127.0.0.1:11111/subscription"|url: "YOUR_SUB_URL"|' \
    /etc/openclash/config/clash-all-noicon-clash.yaml

# 5. 启用并启动
/etc/init.d/openclash enable
/etc/init.d/openclash start
```

> 新版固件（出厂 URL 已是 `http://127.0.0.1:11111/subscription`）跳过步骤 2，
> 直接从步骤 3 开始即可。

---

#### 4.5 运行中强制刷新订阅

```bash
# API secret 非固定：以 UCI 的 dashboard_password 为准（磁盘 YAML 里的 secret 可能已过期）
curl -X PUT "http://127.0.0.1:9090/providers/proxies/cc-auto" \
  -H "Authorization: Bearer $(uci get openclash.config.dashboard_password)"
```

验证 provider 更新状态（updatedAt 为最近时间即成功）：

```bash
curl "http://127.0.0.1:9090/providers/proxies" \
  -H "Authorization: Bearer $(uci get openclash.config.dashboard_password)" \
  | grep -o 'cc-auto.\{0,80\}'
```

---

### 问题七：订阅拉取 EOF / 无法获取节点（机场迁移订阅域名）

**症状：** OpenClash 无法更新订阅节点；`/tmp/openclash.log` 反复刷：

```
[Provider] cc-auto pull error: Get "https://旧订阅地址": EOF
```

**根因：** 机场迁移了订阅服务器域名，旧地址返回 `301 Moved Permanently`。
mihomo 的 provider 拉取不跟随跳转，读到 301 即失败报 EOF。
（实测案例：2026-10-15 某机场订阅域名整体迁移，
旧地址 301 后 provider 连续两天拉取失败，缓存节点过期后国外全线 timeout。）

**诊断：**

```bash
curl -sIL '旧订阅URL'     # 看 Location: 指向的新地址（301 + Location 头）
curl -sL -o /tmp/sub.yaml '旧订阅URL' && grep -c '^  - ' /tmp/sub.yaml   # 跟随跳转验证可得节点
```

**修复：**

```bash
# 1. 用 Location 指向的最终地址替换 YAML 中的 url（只换域名/路径，保留 sid/token 查询串）
sed -i 's|旧域名/旧路径|新域名/新路径|' /etc/openclash/config/clash-all-noicon-clash.yaml

# 2. 若新域名与旧域名不同，同步 nameserver-policy 与 fake-ip-filter 条目
sed -i 's|旧订阅域名|新订阅域名|g' /etc/openclash/config/clash-all-noicon-clash.yaml

# 3. 重启并验证
/etc/init.d/openclash restart
curl -X PUT "http://127.0.0.1:9090/providers/proxies/cc-auto" \
  -H "Authorization: Bearer $(uci get openclash.config.dashboard_password)"
```

**预防（已固化进 setup-openclash.sh / 模板 YAML）：**
- 脚本下载用 `curl -L` 并记录 `%{url_effective}`，把**最终生效地址**写入 YAML，
  后续 mihomo 拉取不会撞上 301；
- 订阅通道固化 `proxy: DIRECT` + 订阅域名 DNS → .7（内网直达），
  即使机场节点全部失效，订阅也能自动拉取最新节点自愈；
  前提是机场订阅端点国内可直达，若必须经代理则删掉 YAML 里的 `proxy: DIRECT` 行。

---

### 问题八：LEDE 打包 ext4 out of space

**症状：** `ext4_allocate_best_fit_partial: failed to allocate 2671 blocks`

**修复：** ROOTFS 从 500MB 调大到 1024MB：
```
CONFIG_TARGET_ROOTFS_PARTSIZE=1024
```

---

### 问题九：netopt.sh 从未执行

**症状：** CPU 始终降频，IRQ 全堆 CPU0

**原因：** shebang 错误 `#!/bin/sh /bin/sh` → 应为 `#!/bin/sh /etc/rc.common`

**修复：** 重写 netopt.sh，使用正确的 OpenWrt init 格式。

---

### 问题十：晚高峰节点大面积超时 / 网速不稳定（机场中转线路被干扰）

**症状：** 晚间大量节点延迟测试 5000ms 超时；`/tmp/openclash.log` 刷
`xxx:443 connect error: context deadline exceeded` 和成片的
`dial tcp <Cloudflare IP>:443: i/o timeout`；走代理的服务同时断流/变慢，
但在数百秒后部分恢复，反复抖动。

**定位思路（三步分层，区分机场侧 vs 本地侧）：**

1. **本地基线**：直连国内 204/baidu 应 <0.5s；DNS 分流正常；CPU/内存/conntrack 健康；
   PPPoE 未重拨（`ubus call network.interface.wan status` 看 uptime）。全绿 → 排除本地。
2. **SNI 对照测试（决定性一步）**：从路由器直连同一 CDN 的两个域名对比：
   ```bash
   curl -sk -o /dev/null -w "cloudflare.com tcp=%{time_connect}s tls=%{time_appconnect}s code=%{http_code}\n" -m 8 https://www.cloudflare.com/
   curl -sk -o /dev/null -w "机场节点域名 tcp=%{time_connect}s tls=%{time_appconnect}s code=%{http_code}\n" -m 8 https://机场节点域名/
   ```
   cloudflare.com TLS 正常（code=200）而机场中转域名 tls=0.000/code=000 →
   **SNI 级针对性干扰**（机场中转域名被针对，与本地线路无关）。
   注：tcp 时间远小于真实 RTT（如 <5ms，到 CF 边缘不可能）= 中间设备劫持应答，
   同样是干扰证据。
3. **错误时段分布**：
   ```bash
   grep error /tmp/openclash.log | grep -oE "T[0-9][0-9]" | sort | uniq -c
   ```
   错误集中在晚高峰时段（其他时段几乎为零）→ 干扰具有时段性，通常午夜后自动缓解。

**放大机制：** 多个 select 组指向同一 url-test 组；url-test 选中的节点挂掉时，
所有服务同时断流；且 url-test 有 300s 测试周期，切换存在 0-5 分钟延迟。
节点在"可用↔超时"间抖动时，体验就是断断续续。

**处置：**

```bash
# 1. 查看各组当前选中节点（确认是否选中了挂掉节点）
curl -s http://127.0.0.1:9090/proxies -H "Authorization: Bearer $(uci get openclash.config.dashboard_password)" \
  | tr '{' '\n' | grep '"now"' | sed 's/.*"name":"\([^"]*\)".*"now":"\([^"]*\)".*/\1 -> \2/'

# 2. 触发目标组重新测速，加速 url-test 切换（组名需 URL 编码）
curl -s "http://127.0.0.1:9090/group/%E6%97%A5%E6%9C%AC-%E8%87%AA%E5%8A%A8/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=5000" \
  -H "Authorization: Bearer $(uci get openclash.config.dashboard_password)"

# 3. 验证恢复（经认证代理口测 204，凭据在 uci openclash.@authentication）
curl -s -o /dev/null -w "code=%{http_code} t=%{time_total}s\n" \
  -x http://user:pass@127.0.0.1:7893 http://www.gstatic.com/generate_204
```

- 等待/触发 url-test 自动切换后通常即恢复，无需重启 OpenClash；
- 晚高峰可把主力组手动切到**直连线路组**（如 香港-自动/美国-自动，避开 CF 中转）；
- 若持续多日恶化，向机场反馈中转线路被干扰，请求修复/更换中转。

---

### 问题十一：配置是否泄露/暴露特征导致被针对（审计清单）

**背景：** 节点被 SNI 针对后自然要问：是不是我的配置暴露了什么？
先看证据定性：同一宽带线路上 cloudflare.com TLS 正常而机场中转域名被掐
→ 干扰基于**域名黑名单字符串**（机场域名被全网拉黑，所有用户同等受害），
不是基于用户 IP/身份的定点针对。配置审计的目标是消除叠加特征、缩小暴露面。

**已发现并修复的真实缺陷：**

1. **TLS 指纹根键写错（静默失效）**：YAML 根级别的 `client-fingerprint` 不是
   mihomo 合法键，会被**静默忽略**；正确键名为 `global-client-fingerprint`。
   后果：订阅节点未自带 `client-fingerprint` 时（实测：机场 24 个 CF 中转 ws 节点全都没有），
   TLS ClientHello 回退 **Go 语言默认指纹**——众所周知的标准代理工具特征。
   被 SNI 针对的节点同时暴露 Go ClientHello，双特征叠加。
   修复：`global-client-fingerprint: chrome`（已固化进模板 YAML 与设备运行时）。

2. **NTP 默认国外源**：`openwrt.pool.ntp.org` 是路由器自身唯一的常规直连国外 UDP 流量。
   修复：换 `ntp.aliyun.com` 等（已固化进 10-system.sh；uci 给 list 赋值必须
   `delete` + `add_list`，`uci set` 会报 Usage 错误）。

**审计过且干净的项（自检命令）：**

| 检查面 | 命令 | 判据 |
|--------|------|------|
| DNS 链路封闭 | `cat /etc/resolv.conf` | 仅 127.0.0.1/::1 |
| | `uci get dhcp.@dnsmasq[0].noresolv; uci get dhcp.@dnsmasq[0].server` | `1` + `127.0.0.1#7874` |
| | `nft list ruleset \| grep "dport 53"` | DNS Hijack 规则存在（v4/v6，含本机 skgid!=65534） |
| 路由器自身外联 | `netstat -tnp \| grep ESTAB \| grep -v clash \| grep -vE "172\\.16\\.|10\\."` | 空（无 mihomo 之外的国外连接） |
| QUIC 拒绝行为 | `nft list ruleset \| grep "udp dport 443"` | `reject with icmp port-unreachable`（正常网络行为，无特征） |
| IPv6 泄露 | `uci get openclash.config.china_ip6_route` | `1`（CN v6 内核直转，国外 v6 走代理） |
| 节点协议盘点 | 看 provider 缓存：`reality-opts`/`flow: xtls-rprx-vision`/`network: ws` | reality 节点抗 SNI 检测；ws+tls 节点靠指纹伪装 |
| API 监听 | 运行时 YAML `external-controller` | OpenClash 会改写为 0.0.0.0 供面板访问；WAN 入站 REJECT 兜底，属可控 LAN 面 |

**关于 BBR 的取舍：** 路由器开 BBR 后，mihomo→节点连接使用 BBR 拥塞控制
（浏览器用 cubic）。BBR 行为指纹在学术上可被行为分析识别，但需要长时间统计，
现实针对性检测主要靠 SNI/ClientHello；BBR 对代理链路吞吐收益明显，建议保留。

**结论：** 能被看到的本质特征 = 节点域名 SNI（vless+tls 类协议固有，配置无法隐藏，
只有 reality/ech 协议级方案能解决）+ 已修复的 Go ClientHello。DNS/自身外联/IP 泄露面
均为干净。若机场长期被 SNI 针对且无 reality 节点可选，考虑换机场或要求其提供
reality/vless-anytls 类抗封锁节点。

---

### 问题十二：DNS 突然全量泄露 + 节点渐进失效（特定坏内核 + 版本误判）

**症状（两个症状同源）：**
1. dnsleaktest 之类测试从"干净"突变为"全量泄露"（显示 ISP 解析器）；
2. 节点用着用着大面积失效、延迟飙升，`/tmp/openclash.log` 连片
   `connect error: context deadline exceeded`。

**根因链条（2026-10 实测案例，含归因修正）：**
自动更新拉到某个**特定坏版本**内核（嫌疑版本 alpha-94b13ae；注意**不是所有
alpha 都有问题**——alpha-gbc76c13 复测 7874 监听正常、无泄露）→ 问题内核运行时
mihomo DNS 未正常监听 7874（静默、无报错）→ dnsmasq 上游
`server=127.0.0.1#7874` 不可达 → 回退 `resolv.conf.auto` 里的 ISP DNS
→ LAN 所有查询经 nft 劫持进 dnsmasq 后**明文 53 出 WAN 到 ISP** →
"泄露很严重"。同时 mihomo 自身解析节点域名也走这条污染路径，与问题十的
SNI 干扰叠加放大节点失效。

> **归因修正（2026-10-17）**：最初怀疑"alpha 通道整体移除了 redir-host"，
> 但同一文件（alpha-gbc76c13）复测完全正常——初次诊断误把 `-v` 读到的
> **文件版本**当成**运行进程版本**（软链接脱节，见下），事故时进程内的
> 真实版本未被捕获。教训：排查内核问题必须同时核对文件与进程（`ps` +
> 启动时间），按"特定版本有 bug"而非"整个通道有 bug"定归因。

**两个叠加的坑：**
- `/etc/openclash/clash` 是指向 `core/clash_meta` 的软链接，内核文件被
  更新后**运行中的进程仍是旧二进制**（Linux 进程替换语义），直到服务重启
  才加载新内核——所以"换内核"与"发作"之间有数小时~数天延迟，时间线极易
  误导排查方向；
- `/configs` API **不回显 dns 字段**（v1.19.32 正式版同样如此），
  不能用 `configs.dns == null` 判断 DNS 是否启用。

**定位（四条命令定乾坤）：**

```bash
/etc/openclash/clash -v                                    # 文件版本；须结合 ps 启动时间判断进程是否已加载它
ss -lnptu | grep 7874                                      # 空 = mihomo DNS 没起来（真断链）
grep -hE '^(no-resolv|server)' /var/etc/dnsmasq.conf.cfg*  # 正常：no-resolv + server=127.0.0.1#7874
cat /proc/net/nf_conntrack | grep 'dport=53 ' | grep -vE '127\.0\.0\.1|172\.16\.3\.'  # 有到 ISP DNS 的条目 = 正在泄露
```

**修复：**

```bash
# 1. 换回确认正常的内核（直连 GitHub 慢时用 gh-proxy.org 前缀镜像下载）
gunzip -c mihomo-*.gz > /etc/openclash/core/clash_meta && chmod +x /etc/openclash/core/clash_meta

# 2. dnsmasq fail-fast 加固：上游 7874 挂了宁可 SERVFAIL 也不回退 ISP
#    （此项与内核版本无关，是防泄露的关键兜底，务必保持）
uci set openclash.config.dnsmasq_noresolv='1'

uci commit openclash && /etc/init.d/openclash restart   # 必须重启，热重载/不重启 = 白换
```

**防复发（已固化进项目）：**
- `30-openclash.sh`：固化 `dnsmasq_noresolv='1'`（fail-fast，与内核版本无关，
  是唯一真正的防泄露兜底）；`auto_update='1'` 保持自动更新（alpha 通道按实证
  放行——问题出在特定坏版本，不在通道本身）；
- `dnsmasq_noresolv` 在设备上曾漂移回 `'0'`（LuCI 保存/插件更新可覆盖），
  重新刷机/大改后按上面四条定位命令复查一遍；
- 若某次自动更新后再现"7874 不监听"，用上面命令确认后回滚内核文件并
  restart 即可，无需改配置。

---

### 问题十三：browserleaks 显示“IP 泄露”——WebRTC host candidate 暴露全局 v6（代理无解）

**症状**：修复 DNS 后复测 browserleaks.com/ip，WebRTC 栏出现真实运营商 IPv6
（如 `2408:8256:...`），看起来像“代理全面失效”。

**结论先行**：WebRTC 的 **host candidate 由浏览器直接从本机网卡枚举**（包含
SLAAC 获得的全局 IPv6），该信息不经过任何网络流量，路由器代理/TProxy/nft
**全部无法拦截**。这不是代理失效。

**分层取证法（排除法逐项证伪，2026-10-16 实测命令）：**

```bash
# 1. 主请求是否走代理：经 mixed 端口测出口
curl -x http://Clash:PASS@127.0.0.1:7893 https://api.ip.sb/ip   # 应返回节点 IP

# 2. DNS 是否泄露：查 whoami，看 resolver 出口
 curl -H "Authorization: Bearer $SEC" \
   "http://127.0.0.1:9090/dns/query?name=whoami.ds.akahelp.net&type=TXT"
#   正常：ns=Google/CF 等国外 resolver，ip/ecs=节点出口段；异常：ISP/国内 resolver

# 3. 客户端流量是否被劫持进 mihomo（conntrack 反向项 src=路由器:7892）
 cat /proc/net/nf_conntrack | grep <目标IP>

# 4. UDP(STUN)是否被 tproxy + mihomo UDP 转发是否工作
 nft list ruleset | grep -E 'tproxy'        # 应有 udp tproxy :7895 且计数在涨
 curl -H "Authorization: Bearer $SEC" http://127.0.0.1:9090/connections | grep udp

# 5. 测试机是否持有全局 v6（WebRTC host candidate 泄露源，实锤用）
 ip neigh show | grep <测试机IP>             # 拿 MAC
 ip -6 neigh show | grep <MAC>               # 有 2408:/2xxx: 全局地址 = 实锤
```

**修复（只能在浏览器侧）**：
- Chrome/Edge：装 “WebRTC Leak Prevent” 类扩展，IP handling policy 设为
  `disable non-proxied UDP`；
- Firefox：`about:config` → `media.peerconnection.enabled=false`；
- 路由器侧停发全局 v6 RA 可根治但代价是全家失去 IPv6 直连，一般不选。

**“之前不泄露”的常见解释**：PPPoE 重拨更换 v6 前缀后客户端重新 SLAAC，
测试机刚拿到全局 v6 的时间差导致对比错觉，与代理层改动无关。

**泄露判定标准（避免误读测试结果）**：
| 测试项 | 正常（未泄露） | 真泄露 |
|--------|----------------|--------|
| 主 IP | 节点 IP/节点国家 | 真实 v4（120.x 等） |
| DNS resolver | Google/CF/节点地区 | 本省 ISP resolver |
| WebRTC srflx | 节点 IP | 真实 v4/v6 |
| WebRTC host | **全局 v6 会显示，属浏览器本地行为，非代理问题** | — |

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

正常结果：**主连接与 DNS 只显示代理节点 IP**。注意：WebRTC 栏若显示客户端
本机的全局 IPv6（如 2408: 开头），属浏览器本地行为，代理无法拦截，详见问题十三。

---

## 模块化架构说明

### 目录结构

```
diy/
├── modules/                    # 首次启动执行的模块（进镜像）
│   ├── 10-system.sh           # 系统基础设置（hostname, timezone, feeds...）
│   ├── 20-firewall.sh         # 防火墙默认值
│   ├── 30-openclash.sh        # OpenClash UCI 预配置
│   ├── 35-nikki.sh            # Nikki UCI 预配置（备用，默认禁用）
│   ├── 36-homeproxy.sh        # HomeProxy UCI 预配置（备用，默认禁用）
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
| China IPv6 | v6全进用户态 | `china_ip6_route=1` | CN v6内核直转，国外v6不受影响 |

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

# 查看 china_ip (v4/v6) bypass set 条目数
nft list set inet fw4 openclash_cn_ip | wc -l
nft list set inet fw4 china_ip6_route | wc -l

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
