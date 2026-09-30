# PVE + virtio 10G 榨干调优指南

> 适用场景：i5-9500（6C6T）物理机跑 PVE，OpenWrt 作为 VM 使用 virtio 网卡，
> WAN 宽带与内网需要承载 10G 级流量。
>
> 固件侧结论：**零改动**。netopt.sh 的 virtio 适配（RPS/XPS 清零、NAPI budget
> 300/2000μs、virtio 跳过 ring/coalescing）已是 PVE 实测最优，两个 x86 config
> 的驱动覆盖（profile 注入 + 显式选择）满足 1G/2.5G/5G/10G 全档——本文档只讲
> 宿主机侧需要做的事，按收益分三档。

---

## 第一档：必做（拿到约 90% 收益）

### 1. VM 网卡：VirtIO + 多队列（最大的单项杠杆）

`/etc/pve/qemu-server/<vmid>.conf`（或 `qm set`）：

```
net0: virtio=BC:24:11:AA:BB:CC,bridge=vmbr0,queues=6
net1: virtio=BC:24:11:AA:BB:DD,bridge=vmbr1,queues=6
```

- `queues=6` 对应 i5-9500 的 6C6T。**PVE 默认 queues=1，这是 virtio 10G
  最常见的隐性瓶颈**：单队列 = 单 vCPU 收包 + 单 vhost 线程，10G 单流必卡。
- 改动只触发 guest 内 virtio 设备重建，ethX 名称与 MAC 不变，
  OpenWrt 网络配置无需调整。
- 宿主确认 vhost 已启用（PVE 默认开启）：`lsmod | grep vhost_net`。

### 2. CPU 与内存

```
cpu: host          # host-passthrough，直出 AES-NI/AVX2
cores: 6
balloon: 0         # 关 ballooning，消除内存回收抖动（延迟敏感）
memory: 4096       # conntrack 52万条目 + mihomo 运行余量
```

### 3. 宿主机 CPU governor

OpenWrt VM 内 netopt.sh 的 governor 设置在无 cpufreq 直通时是 no-op
（脚本会打印跳过提示）——真正的频率开关在宿主机：

```bash
apt install linux-cpupower
cpupower frequency-set -g performance
```

持久化任选其一：

```bash
# 方式一：crontab
@reboot /usr/bin/cpupower frequency-set -g performance

# 方式二：systemd unit（/etc/systemd/system/cpu-performance.service）
[Unit]
Description=Set CPU governor to performance
[Service]
Type=oneshot
ExecStart=/usr/bin/cpupower frequency-set -g performance
[Install]
WantedBy=multi-user.target
```

---

## 第二档：可选极限档（再 +5~10%，管理成本递增）

| 项 | 做法 | 代价/前提 |
|---|---|---|
| 大页内存 | conf 加 `hugepages: 2048`（2MiB×2048 = 4GiB） | VM 必须在宿主预留后重启；提升 vhost DMA 映射效率 |
| 绑核 / isolcpus | 宿主内核参数 `isolcpus=4,5` + `taskset` 把 vhost 线程与 2 个 vCPU 固定同域核 | 消除跨核缓存迁移；配置繁琐，先看第一档实测再决定 |
| C-state 收紧 | GRUB：`intel_idle.max_cstate=1` | 延迟更稳；功耗/发热上升，10G 吞吐本身对此不敏感 |

---

## 第三档：特定场景才做——巨帧 9000

仅当 10G 流量主要在同宿主 VM 之间，或全链路可控（vmbr + 物理 10G 口 +
对端都支持 9000）时启用：

1. PVE：`/etc/network/interfaces` 中 vmbrX 加 `mtu 9000`
2. OpenWrt：LAN 接口（br-lan / ethX）`ip link set ... mtu 9000`（uci 持久化）
3. 对端设备同步 9000

- 收益：pps 降约 6 倍，CPU 占用大幅下降，VM↔VM 接近线速。
- **风险**：内网混有 1G/2.5G 物理设备时不要全局开（非对称 MTU 黑洞），
  PXE/老设备存在兼容性问题。默认 1500 下 10G 已可达线速。

---

## 验证清单（OpenWrt 固件自带 iperf3）

```bash
# 1. 多队列生效确认（OpenWrt 内执行）
ethtool -l eth0        # Combined 应为 6

# 2. 吞吐验证（对端为同宿主 VM 或 10G 设备）
iperf3 -c <对端> -R -P 1    # 单流：验证 vCPU/vhost 分核能否撑住 10G
iperf3 -c <对端> -R -P 8    # 多流聚合

# 3. 热点定位
mpstat -P ALL 1             # guest 内看 %soft 是否分散到多核
# 宿主机上（vhost 是内核线程，PSR 列即所在核）：
ps -eLo pid,tid,psr,comm | grep vhost
```

第一档预期：9~9.5 Gbps、CPU 占用 <40%；达不到再逐项检查队列/mpstat。

---

## 固件侧不动的理由（防止误改）

| netopt.sh 现状 | 不动的理由 |
|---|---|
| RPS/XPS 清零 | 多队列 virtio 每队列已独立 IRQ/vCPU；RPS 只增加 IPI 与缓存行迁移（PVE 实测回退项）。且 RPS 按 flow hash 映射，单流 10G 本来就落单核，RPS 救不了单流 |
| NAPI budget 300 / 2000μs | 实测教训：加大 budget 造成长软中断、virtio TX completion 饿死、测速爬坡慢 |
| TCP buffer max 64MB | 转发流量不经本机 TCP 栈；仅影响本机终止连接（代理隧道），够用 |
| LRO off / GRO on | LRO 与转发、流表 offload 不兼容；GRO 是兼容转发的批量聚合 |

## 性能边界（预期管理）

- **直连/NAT 流量**：10G 稳定最优（nft 软件流表 / Lean SFE fastpath）。
- **代理流量（OpenClash/mihomo）**：用户态核心约 2~4 Gbps 上限，与调优无关。
- **64B 小包线速**（14.8Mpps）：任何软件路由都做不到，实际流量不存在该场景。
