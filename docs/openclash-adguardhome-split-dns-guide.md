# OpenClash + AdGuardHome 分流 DNS 配置教程

> 适用场景：OpenWrt 主路由安装 OpenClash，PVE 内网部署两个 AdGuardHome 实例（国内/国外分流），实现无 DNS 泄漏 + 广告过滤 + 国内直连 + 国外代理。

---

## 网络架构

```
客户端
  │
  ▼
172.16.3.16  主路由 (OpenWrt + OpenClash + Clash Meta)
  │               ┌─ tproxy 拦截所有流量
  │               └─ DNS 监听 :7874
  │
  ├── 172.16.3.6  国外 AdGuardHome（广告过滤 + 外国 DNS）
  │                上游：https://1.1.1.1/dns-query
  │                      https://8.8.8.8/dns-query
  │
  └── 172.16.3.7  国内 AdGuardHome（广告过滤 + 国内 DNS）
                   上游：https://223.5.5.5/dns-query
                         https://119.29.29.29/dns-query
                         (或 114.114.114.114)

以上三个虚拟机均运行于 172.16.0.223 PVE 物理主机
```

---

## 问题描述与根本原因分析

### 症状
- 所有国外网站/IP 无法访问，全部 timeout
- 从 .6 发起访问 1.1.1.1 也 timeout
- 停止 OpenClash 后一切恢复正常

### 根本原因链

```
原始配置中存在：
  SRC-IP-CIDR,172.16.3.6/32,DIRECT

→ .6 所有流量强制走直连
→ .6 的上游 DNS 查询（8.8.4.4:853 DoT）走直连
→ 运营商封锁了直连访问境外 DNS 端口
→ .6 无法解析任何域名
→ OpenClash 的 nameserver 是 .6，无法解析境外域名
→ 所有境外访问失败
```

---

## 排查过程记录

### 第一步：确认 OpenClash 是否根因

```bash
/etc/init.d/openclash stop
curl -m 5 https://1.1.1.1    # 能通 → 确认是 OpenClash 问题
```

### 第二步：查看 Clash 核心日志

```bash
cat /tmp/openclash.log | tail -100
```

**关键日志解读：**

| 日志内容 | 含义 |
|----------|------|
| `dial DIRECT 172.16.3.6 --> 8.8.4.4:853 i/o timeout` | .6 流量走直连，853端口被封 |
| `dial 国外 (match Match/) 172.16.3.6 --> 9.9.9.9:853 i/o timeout` | 规则已修正但代理节点封853端口 |
| `rjp03.holytechx.com:26000 connect error` | 代理节点可达，但服务器端封853端口 |
| `dns resolve failed: context deadline exceeded` | .6 上游用域名形式，Clash 解析时循环依赖 |

### 第三步：查看 OpenClash UCI 配置

```bash
uci show openclash
```

**发现的关键问题：**
- `enable_respect_rules='0'` → OpenClash 覆盖了 YAML 的 `respect-rules: true`
- 无订阅节点（`@subscription` 条目为空）

---

## 解决方案

### 修复一：删除 `.6` 的 DIRECT 规则（根本原因）

**clash.yaml 修改：**
```yaml
# 删除这一行（或不添加）：
# - SRC-IP-CIDR,172.16.3.6/32,DIRECT,no-resolve

# 保留 .7 的直连（国内DNS，上游为国内服务器，直连无问题）：
- SRC-IP-CIDR,172.16.3.7/32,DIRECT,no-resolve
```

**原理：** `.7` 的上游是国内 DNS（223.5.5.5 等），直连可达。`.6` 的上游是境外 DNS，需要走代理或其他方式。

---

### 修复二：AdGuardHome .6 上游改为 DoH + IP 形式

**问题：** `.6` 原来使用域名形式的 DoT/DoH（如 `tls://dns.cloudflare.com`），当 Clash 拦截这些连接时，需要先解析 `dns.cloudflare.com`，但解析又依赖 .6 → 循环依赖。同时，大多数机场服务器封锁出站 853 端口（DoT）防止 DNS 滥用。

**AdGuardHome .6 上游 DNS 设置（`http://172.16.3.6:3000`）：**

```
# 推荐配置（DoH + IP形式，无需 Clash 解析域名，且走443端口机场不封锁）
https://1.1.1.1/dns-query
https://8.8.8.8/dns-query
https://9.9.9.9/dns-query

# 不推荐的形式（会导致问题）：
# tls://dns.cloudflare.com  ← 域名形式 + 853端口，双重问题
# tls://1.1.1.1             ← IP形式但853端口，机场封锁
# https://dns.cloudflare.com/dns-query ← 域名形式，Clash解析循环依赖
```

**AdGuardHome .7 上游 DNS 设置：**

```
https://223.5.5.5/dns-query
https://119.29.29.29/dns-query
```

---

### 修复三：OpenClash 开启 respect-rules

**问题：** OpenClash UCI 配置 `enable_respect_rules='0'` 覆盖了 YAML 中的设置，导致 DNS 查询不走规则，.6 的上游请求无法被正确路由。

```bash
uci set openclash.config.enable_respect_rules='1'
uci commit openclash
```

或在 OpenClash LuCI 界面：**覆写设置 → DNS 设置 → 开启"遵循规则(Respect Rules)"**

---

### 修复四：订阅节点加载（解决鸡蛋问题）

**问题：** 订阅 URL 本身是境外地址，需要代理才能下载；但代理没节点，无法下载订阅 → 循环依赖。

**解决方案：停止 OpenClash 后手动下载（每次重置时执行一次即可）**

```bash
# 1. 停止 OpenClash（直接用系统路由下载，绕开 tproxy）
/etc/init.d/openclash stop

# 2. 下载订阅到 OpenClash config 目录
mkdir -p /etc/openclash/config/providers
curl -L -o /etc/openclash/config/providers/cc-auto.yaml "https://subs.bid"

# 3. 确认文件内容正确（应是节点列表，而非 HTML 错误页）
head -3 /etc/openclash/config/providers/cc-auto.yaml

# 4. 重启 OpenClash
/etc/init.d/openclash start
```

> **说明：** OpenClash 运行稳定后，后续订阅自动按 `interval: 86400`（每24小时）自动更新。
> 只有在系统重置或节点全部失效时，才需要重新手动执行上述步骤。

**运行中强制刷新订阅（已有节点时使用）：**

```bash
curl -X PUT "http://127.0.0.1:9090/providers/proxies/cc-auto" \
  -H "Authorization: Bearer oc_6Qf9v2LmP8xT4rN1kY7sDz3aH5uWc"
```

---

### 修复五：proxy-server-nameserver（防止代理节点域名解析循环）

**问题：** 代理节点如果使用域名形式（如 `server.example.com`），Clash 需要先解析该域名才能连接。若解析走 .6（需代理），但代理节点本身还没解析出来 → 循环。

**解决：** 使用专用 DNS 解析代理服务器域名，直连到国内 DNS，绕开循环：

```yaml
dns:
  proxy-server-nameserver:
    - 172.16.3.7     # 国内AdGuardHome，内网直达
    - 223.5.5.5      # 阿里DNS备用
```

---

### 修复六：订阅自动更新间隔配置

```yaml
proxy-providers:
  cc-auto:
    url: "https://subs.bid"
    type: http
    interval: 86400    # 每24小时自动更新一次
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: 43200
```

> 无需配置 `path` 磁盘缓存，也无需将订阅域名加入直连规则。
> 统一采用手动命令方式更新订阅（见修复四）。

---

## 最终 DNS 工作流程

```
客户端查询 youtube.com
    ↓
OpenClash DNS (:7874, redir-host + respect-rules)
    ↓ 不匹配 nameserver-policy → 用 nameserver → .6
.6 AdGuardHome 收到查询 (广告过滤规则生效)
    ↓ 查上游 https://1.1.1.1/dns-query (DoH, 443端口)
.6 → 1.1.1.1:443 流量被 tproxy 拦截
    ↓ 匹配 Cloudflare IP 规则 → 走代理节点
代理节点转发 → 1.1.1.1 返回 youtube 真实IP
    ↓
OpenClash 获得真实IP → 返回给客户端
客户端流量访问 youtube 真实IP
    ↓ 被 tproxy 拦截 → 匹配 YouTube/Domain → 走代理 ✓


客户端查询 baidu.com  
    ↓
OpenClash DNS → 匹配 nameserver-policy geosite:cn → 用 .7
.7 AdGuardHome 收到查询 (广告过滤生效)
    ↓ 查上游 https://223.5.5.5/dns-query (国内DoH，直连可达)
返回 baidu 真实IP → 匹配 China/Domain → DIRECT ✓
```

---

## 关键配置对照表

| 配置项 | 错误做法 | 正确做法 | 原因 |
|--------|----------|----------|------|
| `.6` tproxy 规则 | `SRC-IP-CIDR,.6,DIRECT` | 不添加此规则 | DIRECT + tproxy 与直连行为不同，且机场封853端口 |
| `.6` 上游 DNS | `tls://dns.cloudflare.com` | `https://1.1.1.1/dns-query` | 消除域名解析循环依赖 + 避免853端口被封 |
| `.6` 上游端口 | DoT (853) | DoH (443) | 机场服务器封锁853出站端口 |
| DNS 模式 | fake-ip（此场景） | redir-host + respect-rules | 配合内网 AdGuardHome 使用，保留广告过滤功能 |
| OpenClash respect-rules | 默认关闭 | 开启 | 让 DNS 查询也走规则，.6上游经代理，无DNS泄漏 |
| 订阅加载 | 依赖节点已加载后自动下载 | 手动下载（停OpenClash后curl） | 解决鸡蛋循环问题 |
| 代理节点DNS | 无 proxy-server-nameserver | 配置 proxy-server-nameserver → .7 | 代理节点域名解析走内网DNS，不循环 |
| IPv6 泄漏 | block 所有 IPv6 | 开启 IPv6 代理（ipv6_enable=1）| 국内 IPv6 直连，国外 IPv6 走代理，体验完整 |

---

## IPv6 泄漏防护

### 泄漏原因

```
客户端有 IPv6 地址
    ↓
访问支持 IPv6 的网站（如 Google、YouTube）
    ↓
若 OpenWrt 有 IPv6 连通性且 ip6tables 未配置 tproxy
→ IPv6 流量直接出口，完全绕过 Clash
→ 真实 IPv6 地址暴露 = IPv6 泄漏
```

### 修复层级

IPv6 泄漏需要两层修复，**仅 yaml 不够**：

#### 层级一：yaml（处理进入 Clash 的 IPv6 流量）

**tun.route-exclude-address 增加 IPv6 本地地址：**
```yaml
tun:
  route-exclude-address:
    # IPv4（原有）
    - 10.0.0.0/8
    - 172.16.0.0/12
    - 192.168.0.0/16
    # IPv6 增加
    - "::1/128"       # loopback
    - "fc00::/7"      # ULA 私有
    - "fe80::/10"     # 链路本地
    - "ff00::/8"      # 组播
```

**rules 末尾增加 IPv6 拒绝规则：**
```yaml
rules:
  # ... 其他规则 ...
  - IP-CIDR6,::1/128,DIRECT,no-resolve       # loopback 直连
  - IP-CIDR6,fc00::/7,DIRECT,no-resolve      # ULA 私有直连
  - IP-CIDR6,fe80::/10,DIRECT,no-resolve     # 链路本地直连
  - IP-CIDR6,::/0,REJECT,no-resolve          # 拦截所有其他 IPv6
  - MATCH,国外
```

#### 层级二：OpenWrt 防火墙 + OpenClash IPv6 代理

**推荐方案：开启 IPv6 代理**，让国内 IPv6 直连、国外 IPv6 走代理，行为与 IPv4 完全一致。无需手写 ip6tables 规则，OpenClash 原生支持。

##### 方案A：开启 IPv6 代理（推荐）

OpenClash 有内建的 IPv6 tproxy 支持，启用后自动配置 ip6tables 规则：

```bash
# 开启 OpenClash IPv6 代理
uci set openclash.config.ipv6_enable='1'
uci set openclash.config.ipv6_dns='1'
uci commit openclash
/etc/init.d/openclash restart
```

同时 yaml 需对应开启（已在配置中）：
```yaml
ipv6: true          # 全局 IPv6 代理支持
dns:
  ipv6: true        # DNS 返回 AAAA 记录
```

规则行为：
- 国内 IPv6（China/IP 规则集含 IPv6 段）→ DIRECT ✓
- 国外 IPv6（GeoLocation-!CN、MATCH）→ 代理 ✓
- 本地 IPv6（fc00::/7、fe80::/10）→ DIRECT ✓

##### 方案B：彻底禁用 IPv6（最简单，无 IPv6 访问）

如果完全不需要 IPv6 访问：

```bash
# OpenClash 保持 ipv6_enable=0（默认）
# 同时禁用 WAN6 接口
uci set network.wan6.disabled='1'
uci commit network
/etc/init.d/network restart
```

##### 不推荐的方案：直接 block 所有 IPv6

```bash
# 此方案会导致国内 IPv6 网站也无法访问，不推荐
ip6tables -I FORWARD -i br-lan -j DROP
```

### 验证 IPv6 泄漏是否已修复

在浏览器访问以下网站检测：
- https://browserleaks.com/ip
- https://ipleak.net
- https://ipv6leak.com

正常结果：**只显示代理节点的 IPv4 地址，无 IPv6 地址**。

---

## 常用排查命令

```bash
# 查看 Clash 核心实时日志
tail -f /tmp/openclash.log

# 查看 OpenClash 配置
uci show openclash

# 手动更新订阅（OpenClash运行中）
curl -X PUT "http://127.0.0.1:9090/providers/proxies/cc-auto" \
  -H "Authorization: Bearer oc_6Qf9v2LmP8xT4rN1kY7sDz3aH5uWc"

# 重启 OpenClash
/etc/init.d/openclash restart

# 停止 OpenClash（验证问题来源）
/etc/init.d/openclash stop

# 测试代理是否工作
curl -x socks5h://127.0.0.1:7891 -m 10 https://www.google.com -o /dev/null -w "%{http_code}\n"
```

---

## 注意事项

1. **机场选择**：确认机场允许 DoH 流量（443端口）通过，绝大多数机场允许。
2. **订阅缓存**：`path` 字段对应 `/etc/openclash/config/providers/cc-auto.yaml`，首次需手动下载。
3. **OpenClash 版本**：本教程基于 OpenClash + Clash Meta 内核，纯 Clash Premium 内核行为略有差异。
4. **DNS 泄漏说明**：redir-host + respect-rules 模式下，.6 的上游 DoH 查询经代理到达 1.1.1.1，运营商无法看到查询内容，无 DNS 泄漏。

