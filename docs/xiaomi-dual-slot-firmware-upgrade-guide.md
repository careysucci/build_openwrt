# 小米 CR8806 / CR881x 双分区固件升级教程

本文适用于本仓库构建的以下设备：

| 管理地址 | 设备 | OpenWrt `board_name` | 应使用的固件型号 |
|---|---|---|---|
| `172.16.0.226` | 小米 CR8806 / Redmi AX3000 | `redmi,ax3000` | `redmi_ax3000` |
| `172.16.0.248` | 小米 CR8816，属于 CR881x | `xiaomi,cr881x` | `xiaomi_cr881x` |

> **严禁交叉刷入。** CR8806 与 CR881x 的交换芯片和设备树不同，文件名相似不代表可以混用。

## 1. 先区分 tar sysupgrade 与裸 UBI

这是最容易出错、也最关键的一步。

### 1.1 `*-squashfs-sysupgrade.bin`：tar 容器

本仓库目前生成的 sysupgrade 包是 tar，内部通常包含：

```text
sysupgrade-<board>/CONTROL
sysupgrade-<board>/kernel
sysupgrade-<board>/root
```

其中：

- `kernel` 是 FIT 内核；
- `root` 是 squashfs 根文件系统；
- 它不是完整的 UBI 镜像；
- **不能直接执行 `ubiformat -f sysupgrade.bin`。**

检查方法：

```sh
FW=/tmp/sysupgrade.bin
head -c 16 "$FW" | hexdump -v -e '1/1 "%02x"'
tar tf "$FW"
```

tar 包的开头通常是 ASCII 字符串 `sysupgrade-`，而不是 `UBI#`。

### 1.2 `*-squashfs-factory.ubi` / `factory.img`：完整裸 UBI

这种文件包含完整的 UBI 卷表和卷数据，可对**非运行槽**执行 `ubiformat`。

检查方法：

```sh
FW=/tmp/factory.ubi
[ "$(head -c 3 "$FW")" = "UBI" ] && echo "raw UBI image"
```

只有明确为裸 UBI 的文件，才使用本文第 6 节的 `ubiformat` 方法。

### 1.3 不要把以下命令混用

| 固件内容 | 正确写入方式 |
|---|---|
| tar 中的 kernel + squashfs root | `nand_do_flash_file`，解包后写 kernel/rootfs 卷 |
| 完整裸 UBI | `ubiformat` 写目标 MTD |
| 单独 UBIFS 根卷 | `ubiupdatevol`，不属于本文两种固件 |

`ubiformat` 会擦除目标 MTD 并重建整个 UBI；`ubiupdatevol` 只更新一个已存在的 UBI 卷。完整 factory UBI 不能交给 `ubiupdatevol`。

## 2. 当前构建为何需要手动 tar 流程

当前设备的 `/lib/upgrade/mi_dualboot.sh` 仍有以下限制：

1. `mi_dualboot_check_image` 只接受文件头为 `UBI` 的镜像；
2. `mi_dualboot_do_upgrade` 直接把输入文件交给 `ubiformat`；
3. tar sysupgrade 与该接口不匹配。

因此，在这项构建逻辑修复前，不建议把当前 tar `sysupgrade.bin` 直接交给旧版 LuCI/sysupgrade 双分区路径。下面的手动流程实际调用 OpenWrt 自带的 `nand_do_flash_file`，它会识别 tar 并分别创建、写入 kernel/rootfs/rootfs_data 卷。

## 3. 升级前准备

### 3.1 在 Windows 计算哈希并上传

PowerShell 示例：

```powershell
Get-FileHash "C:\path\to\immortalwrt-qualcommax-ipq50xx-redmi_ax3000-squashfs-sysupgrade.bin" -Algorithm SHA256
scp "C:\path\to\immortalwrt-qualcommax-ipq50xx-redmi_ax3000-squashfs-sysupgrade.bin" root@172.16.0.226:/tmp/sysupgrade.bin
```

CR881x 示例应同时替换固件文件名和目标地址：

```powershell
scp "C:\path\to\immortalwrt-qualcommax-ipq50xx-xiaomi_cr881x-squashfs-sysupgrade.bin" root@172.16.0.248:/tmp/sysupgrade.bin
```

文件传到 `/tmp` 会占用内存，断电后消失。升级过程中不要关闭当前 SSH 会话后开始拔电测试。

### 3.2 登录设备并检查当前状态

```sh
ssh root@172.16.0.226       # CR881x 改为 root@172.16.0.248
```

执行：

```sh
cat /tmp/sysinfo/board_name
cat /tmp/sysinfo/model
cat /etc/openwrt_release
cat /proc/cmdline
cat /proc/mtd
ubinfo -a
mount | grep -E ' on / | on /overlay '
df -h / /overlay /tmp
fw_printenv | grep -E 'flag_(boot_rootfs|boot_success|last_success|try_sys[12]_failed|ota_reboot)'
sha256sum /tmp/sysupgrade.bin
```

必须确认：

- `board_name` 与固件型号一致；
- `/proc/cmdline` 中是 `ubi.mtd=rootfs` 或 `ubi.mtd=rootfs_1`；
- 根文件系统为 `overlayfs:/overlay on /`，不是 `/tmp/root` 的 ramoverlay；
- `/overlay` 有足够空间；
- `/tmp` 能容纳固件和备份；
- 设备端 SHA-256 与 Windows 计算结果一致。

如果当前是 ramoverlay，先修复持久存储，不要继续升级，否则可能再次表现为配置全部丢失。

### 3.3 备份配置并下载到电脑

设备上执行：

```sh
BK=/tmp/pre-upgrade-backup.tar.gz
sysupgrade -b "$BK"
sync
ls -l "$BK"
sha256sum "$BK"
tar -tzf "$BK" | grep -E '^etc/config/(network|wireless|system)$'
```

建议额外保存哈希，便于升级后比较：

```sh
sha256sum /etc/config/network /etc/config/wireless /etc/config/system
```

Windows 下载备份：

```powershell
scp root@172.16.0.226:/tmp/pre-upgrade-backup.tar.gz "C:\path\to\226-pre-upgrade-backup.tar.gz"
```

`nand_restore_config` 会把备份文件**移动**到目标 `rootfs_data`，所以本机副本很重要；如果需要重试，应重新上传备份或重新执行 `sysupgrade -b`。

## 4. 通用：确定当前槽、目标槽和 MTD

以下变量在 tar 和 UBI 两种流程中都会用到。每个新的 SSH 会话都要重新执行，不要凭记忆写死 `mtd18` 或 `mtd19`。

```sh
. /lib/functions.sh
include /lib/upgrade

BOARD="$(cat /tmp/sysinfo/board_name)"
CUR="$(sed -n 's/.*ubi\.mtd=\([^ ]*\).*/\1/p' /proc/cmdline)"

case "$CUR" in
rootfs)
    TARGET=rootfs_1
    CURRENT_FLAG=0
    TARGET_FLAG=1
    ;;
rootfs_1)
    TARGET=rootfs
    CURRENT_FLAG=1
    TARGET_FLAG=0
    ;;
*)
    echo "无法识别当前槽：$CUR"
    exit 1
    ;;
esac

MTDNUM="$(find_mtd_index "$TARGET")"
[ -n "$MTDNUM" ] || { echo "找不到目标 MTD"; exit 1; }

echo "board=$BOARD current=$CUR target=$TARGET mtd$MTDNUM"
echo "current_flag=$CURRENT_FLAG target_flag=$TARGET_FLAG"
```

在本设备上通常对应：

| 分区 | MTD | `flag_boot_rootfs` |
|---|---:|---:|
| `rootfs` | `mtd18` | `0` |
| `rootfs_1` | `mtd19` | `1` |

仍须以 `find_mtd_index` 的实际输出为准。

## 5. 方法一：刷入 tar `sysupgrade.bin`

### 5.1 校验 tar 板型和完整性

以 CR8806 为例：

```sh
FW=/tmp/sysupgrade.bin
BK=/tmp/pre-upgrade-backup.tar.gz
EXPECTED_DIR=sysupgrade-redmi_ax3000
[ "$(cat /tmp/sysinfo/board_name)" = "redmi,ax3000" ] || exit 1
```

CR881x 改为：

```sh
FW=/tmp/sysupgrade.bin
BK=/tmp/pre-upgrade-backup.tar.gz
EXPECTED_DIR=sysupgrade-xiaomi_cr881x
[ "$(cat /tmp/sysinfo/board_name)" = "xiaomi,cr881x" ] || exit 1
```

然后执行：

```sh
BOARD_DIR="$(tar tf "$FW" | grep -m 1 '^sysupgrade-.*/$')"
BOARD_DIR="${BOARD_DIR%/}"
echo "image_board_dir=$BOARD_DIR expected=$EXPECTED_DIR"
[ "$BOARD_DIR" = "$EXPECTED_DIR" ] || { echo "固件板型不匹配，停止"; exit 1; }

tar -xOf "$FW" "$BOARD_DIR/CONTROL"
tar -xOf "$FW" > /dev/null || { echo "tar 完整性检查失败"; exit 1; }
ls -l "$FW" "$BK"
```

### 5.2 只写非运行槽

先重新执行第 4 节的槽位识别，再执行：

```sh
CI_UBIPART="$TARGET"
CI_KERNPART=kernel
CI_ROOTPART=rootfs
export BACKUP_FILE=sysupgrade.tgz

nand_do_flash_file "$FW" cat || { echo "写入失败，不切槽、不重启"; exit 1; }
sync
```

该命令会：

1. 读取 tar 中的 kernel 和 root；
2. 在目标 MTD 上附加 UBI；
3. 重建 kernel/rootfs/rootfs_data 卷；
4. 将 kernel 和 squashfs root 写入对应卷。

它不会自动修改启动标志。

### 5.3 读回 kernel、rootfs 和版本

```sh
UBIDEV="$(nand_find_ubi "$TARGET")"
KERNVOL="$(nand_find_volume "$UBIDEV" kernel)"
ROOTVOL="$(nand_find_volume "$UBIDEV" rootfs)"
DATAVOL="$(nand_find_volume "$UBIDEV" rootfs_data)"

[ -n "$UBIDEV" ] && [ -n "$KERNVOL" ] && [ -n "$ROOTVOL" ] && [ -n "$DATAVOL" ] || exit 1
echo "target=$UBIDEV kernel=$KERNVOL rootfs=$ROOTVOL data=$DATAVOL"
ubinfo -a
```

如果已经记录了包内 kernel/root 的字节数和 SHA-256，可做逐字节读回校验：

```sh
head -c <KERNEL_SIZE> "/dev/$KERNVOL" | sha256sum
head -c <ROOT_SIZE> "/dev/$ROOTVOL" | sha256sum
```

`<KERNEL_SIZE>` 和 `<ROOT_SIZE>` 必须替换为十进制字节数，不能保留尖括号执行。

只读挂载目标 squashfs：

```sh
mkdir -p /tmp/target_root
nand_remove_ubiblock "$ROOTVOL"
ubiblock -c "/dev/$ROOTVOL"
BLOCKDEV="/dev/ubiblock${ROOTVOL#ubi}"
mount -t squashfs -o ro "$BLOCKDEV" /tmp/target_root
cat /tmp/target_root/etc/openwrt_release
umount /tmp/target_root
ubiblock -r "/dev/$ROOTVOL"
```

这里必须人工确认版本是预期的新版本，而不是旧槽版本。

### 5.4 把配置备份放入新槽

```sh
nand_restore_config "$BK" || { echo "配置备份写入失败，停止"; exit 1; }

mkdir -p /tmp/target_data
mount -t ubifs "/dev/$DATAVOL" /tmp/target_data
ls -l /tmp/target_data/sysupgrade.tgz
tar -tzf /tmp/target_data/sysupgrade.tgz | grep -E '^etc/config/(network|wireless|system)$'
umount /tmp/target_data
sync
```

新系统首启时会提取 `sysupgrade.tgz` 并恢复配置。若首启后该文件仍在，通常表示新系统没有运行到 preinit 的配置恢复阶段。

### 5.5 detach 后才允许切槽

```sh
mount | grep -E 'target_root|target_data|ubiblock' || true
sync
ubidetach -m "$MTDNUM"
```

若出现 `Resource busy`：

1. 不要切槽；
2. 检查 `/tmp/target_root`、`/tmp/target_data` 是否已 umount；
3. 检查是否残留 `/dev/ubiblock*`；
4. `sync` 后稍等再重试；
5. 不要通过改写其他分区来绕过错误。

## 6. 方法二：在 OpenWrt 中刷入裸 UBI

> 本节只适用于 `factory.ubi` / 确认为裸 UBI 的 `factory.img`，不适用于 tar sysupgrade。

### 6.1 校验文件和当前槽

```sh
FW=/tmp/factory.ubi
BK=/tmp/pre-upgrade-backup.tar.gz
[ "$(head -c 3 "$FW")" = "UBI" ] || { echo "不是裸 UBI，禁止 ubiformat"; exit 1; }
sha256sum "$FW"
```

重新执行第 4 节，得到 `CUR`、`TARGET`、`MTDNUM`、`CURRENT_FLAG` 和 `TARGET_FLAG`。

再次确认目标不是当前运行槽：

```sh
[ "$TARGET" != "$CUR" ] || { echo "拒绝擦除当前运行槽"; exit 1; }
```

### 6.2 用 `ubiformat` 写完整 UBI

如果目标槽已经附加，先只针对非运行槽执行 detach：

```sh
nand_detach_ubi "$TARGET"
```

写入：

```sh
ubiformat "/dev/mtd$MTDNUM" -f "$FW" -y || { echo "ubiformat 失败"; exit 1; }
sync
ubiattach -m "$MTDNUM"
```

也可以使用标准输入方式；此时必须提供准确字节数：

```sh
SIZE="$(wc -c < "$FW")"
cat "$FW" | ubiformat "/dev/mtd$MTDNUM" -S "$SIZE" -y -f -
ubiattach -m "$MTDNUM"
```

二选一即可，不要连续执行两次。

### 6.3 验证 UBI 卷和 rootfs

```sh
UBIDEV="$(nand_find_ubi "$TARGET")"
KERNVOL="$(nand_find_volume "$UBIDEV" kernel)"
ROOTVOL="$(nand_find_volume "$UBIDEV" rootfs)"
[ -n "$KERNVOL" ] && [ -n "$ROOTVOL" ] || { echo "缺少 kernel/rootfs 卷"; exit 1; }
ubinfo -a
```

factory UBI 首启前没有 `rootfs_data` 是正常的，它通常由 OpenWrt preinit 创建。

只读验收 rootfs：

```sh
mkdir -p /tmp/target_root
nand_remove_ubiblock "$ROOTVOL"
ubiblock -c "/dev/$ROOTVOL"
BLOCKDEV="/dev/ubiblock${ROOTVOL#ubi}"
mount -t squashfs -o ro "$BLOCKDEV" /tmp/target_root
cat /tmp/target_root/etc/openwrt_release
umount /tmp/target_root
ubiblock -r "/dev/$ROOTVOL"
```

### 6.4 裸 UBI 升级时保留配置

如果需要保留配置，而目标没有 `rootfs_data`，先利用剩余空间创建：

```sh
DATAVOL="$(nand_find_volume "$UBIDEV" rootfs_data)"
if [ -z "$DATAVOL" ]; then
    ubimkvol "/dev/$UBIDEV" -N rootfs_data -m
    DATAVOL="$(nand_find_volume "$UBIDEV" rootfs_data)"
fi
[ -n "$DATAVOL" ] || exit 1

CI_UBIPART="$TARGET"
export BACKUP_FILE=sysupgrade.tgz
nand_restore_config "$BK"

mkdir -p /tmp/target_data
mount -t ubifs "/dev/$DATAVOL" /tmp/target_data
tar -tzf /tmp/target_data/sysupgrade.tgz | grep -E '^etc/config/(network|wireless|system)$'
umount /tmp/target_data
sync
ubidetach -m "$MTDNUM"
```

如果要完全恢复出厂配置，则不要执行 `nand_restore_config`。

## 7. 切换试启动：CR8806 与 CR881x 通用实测流程

完成目标槽读回验收并成功 detach 后，才执行本节。

以下变量来自第 4 节：

- `CURRENT_FLAG`：当前已知可启动旧槽；
- `TARGET_FLAG`：刚写入并验收的新槽。

```sh
fw_setenv flag_try_sys1_failed 0
fw_setenv flag_try_sys2_failed 0
fw_setenv flag_last_success "$CURRENT_FLAG"
fw_setenv flag_boot_rootfs "$TARGET_FLAG"
fw_setenv flag_ota_reboot 1
fw_setenv flag_boot_success
```

最后一条没有值，含义是**删除 `flag_boot_success`**，不是写成 `0`。

重启前逐项读回：

```sh
fw_printenv | grep -E 'flag_(boot_rootfs|boot_success|last_success|try_sys[12]_failed|ota_reboot)'
fw_printenv -n flag_boot_rootfs
fw_printenv -n flag_last_success
fw_printenv -n flag_ota_reboot
```

确认：

- `flag_boot_rootfs=$TARGET_FLAG`；
- `flag_last_success=$CURRENT_FLAG`；
- `flag_ota_reboot=1`；
- `flag_boot_success` 不存在。

然后：

```sh
sync
reboot
```

此流程保留旧槽作为 `flag_last_success`，由新系统成功启动后的 `uboot_env` 初始化脚本确认并归位标志。不要把某一机型曾经有效的 `boot_success=1` 直接切槽组合未经验证套到另一机型。

## 8. 启动后的验收

### 8.1 版本、槽位和持久 overlay

```sh
cat /etc/openwrt_release
cat /proc/cmdline
uptime
mount | grep -E ' on / | on /overlay '
df -h /overlay
fw_printenv | grep -E 'flag_(boot_rootfs|boot_success|last_success|try_sys[12]_failed|ota_reboot)'
```

应确认：

- 版本是新版本；
- `ubi.mtd=` 是目标槽；
- `overlayfs:/overlay on /`；
- `/overlay` 是 UBIFS，而非 tmpfs/ramoverlay；
- `flag_ota_reboot=0`、`flag_boot_success=1`；
- `flag_boot_rootfs` 和 `flag_last_success` 已指向当前槽。

### 8.2 配置、有线与无线

```sh
ip -4 addr show dev br-lan
sha256sum /etc/config/network /etc/config/wireless /etc/config/system
iw dev
wifi status
ping -c 3 <主路由地址>
```

检查 SSID、加密、国家码、信道、带宽、802.11r/k/v 和实际客户端 `authorized=yes`。仅看到 `ieee80211r=1` 不能证明漫游成功，真实漫游还应检查目标 AP 的 `auth_alg=ft`、授权状态和业务连通性。

### 8.3 再做一次完整重启

第二次重启后重复版本、槽位、overlay 和配置哈希检查，确认不是只在第一次试启动中暂时有效。

## 9. 回退到旧槽

### 9.1 基本原则

回退不是重新刷写。只要旧槽没有被擦除，就可以通过启动标志切回。

在新系统仍能 SSH 登录时，先读取：

```sh
cat /proc/cmdline
fw_printenv | grep -E 'flag_(boot_rootfs|boot_success|last_success|try_sys[12]_failed|ota_reboot)'
```

然后指定旧槽为下一次试启动目标，同时保留当前槽作为回退槽。变量含义仍与第 4 节一致，只是这次 `TARGET` 指向旧系统。

### 9.2 本次 CR8806 已验证的回退示例

本次 `.226` 新系统运行在 `rootfs`（标志 0），旧系统在 `rootfs_1`（标志 1）。从新系统切回旧系统实际执行并验证成功的是：

```sh
fw_setenv flag_try_sys1_failed 0
fw_setenv flag_try_sys2_failed 0
fw_setenv flag_last_success 1
fw_setenv flag_boot_rootfs 1
fw_setenv flag_boot_success 1
fw_setenv flag_ota_reboot 0
sync
reboot
```

这组数字只适用于“从 rootfs=0 回 rootfs_1=1”的这一方向。其他方向应重新根据当前槽计算，不能照抄。

## 10. 常见故障排查

### 10.1 sysupgrade 后仍运行旧版本

```sh
cat /etc/openwrt_release
cat /proc/cmdline
fw_printenv
```

先区分：

- 目标槽根本没有写入；
- 写入了但没有尝试启动；
- 尝试后回退；
- 新系统以另一个管理地址启动。

不要只看到 `sysupgrade` 返回或 SSH 断开，就认定写入成功。

### 10.2 原管理地址消失

本仓库首次出厂配置可能使用 `172.16.3.19`。可从另一台同二层 AP 检查：

```sh
ping -c 3 172.16.0.226
ping -c 3 172.16.3.19
ip neigh show
```

ping 不通仍不能单独证明未启动，还要检查无线 BSSID、ARP、启动标志和目标 `rootfs_data`。

### 10.3 `rootfs_data` 中仍有 `sysupgrade.tgz`

将目标槽附加并只读检查：

```sh
ls -l /tmp/target_data/sysupgrade.tgz
```

如果该备份尚未被消费，说明新系统未运行到 preinit 的配置恢复阶段，不能宣称新固件已启动。

### 10.4 有线 UP 但完全不能通信

同时检查 Linux 收发计数，而不只看 `Link detected: yes`：

```sh
for iface in lan3 eth1 br-lan; do
    echo "=== $iface ==="
    for name in rx_packets tx_packets rx_bytes tx_bytes rx_errors tx_errors; do
        echo -n "$name="
        cat "/sys/class/net/$iface/statistics/$name"
    done
done
```

若 lan3/eth1 的 `rx_packets` 始终为 0，而无线可登录，问题在交换机/DSA/CPU 接收路径，不是 SSH 密码或 IP 配置。

## 11. 本次两个指定固件的真机结论

### 11.1 CR881x `.248`

文件：

```text
immortalwrt-qualcommax-ipq50xx-xiaomi_cr881x-squashfs-sysupgrade.bin
SHA-256: a28e3aa4c27e20a25a26cf79fdb7ed4effe4075fe37afa9c395ff5800577f598
```

结果：

- 已运行 `WyWrt-AP 2026.10.22`；
- tar 写槽、读回哈希、配置恢复、二次重启持久化均通过；
- 5G 双向真实 FT 漫游通过；
- 2.4G 只验证到 FT 失败后的完整 WPA2 回退重连，未据此宣称 2.4G FT 成功。

### 11.2 CR8806 `.226`

文件：

```text
immortalwrt-qualcommax-ipq50xx-redmi_ax3000-squashfs-sysupgrade.bin
SHA-256: 395376dc4ccd095cd91530bbe201c14d7b4d34f5f6cea3a83995e27b4526e9e8
```

本次实测：

- tar 内 kernel/root 写入后的 SHA-256 与包内完全一致；
- 新槽能启动 `2026.10.22`，无线和配置恢复有效；
- 但有线 `lan3` 与 `eth1` 的 `rx_packets/rx_bytes` 持续为 0，主路由和其他 AP 无法通过有线 ARP/ICMP 与它通信；
- 禁用 offload、禁用 x86 专用 netopt 并完整重启后仍然无效；
- 回退旧槽 `2026.10.01` 后，相同网线和配置下有线收发立即恢复。

**结论：上述 SHA-256 的 CR8806 包暂不应部署到生产环境。当前 `.226` 已回退旧槽保障网络，不能将这次尝试写成升级完成。应先修复 CR8806 有线接收回归并重新构建，再按本文流程升级。**

## 12. 最简安全清单

每次刷写至少完成以下事项：

- [ ] 板型与固件目录一致；
- [ ] 识别 tar 或裸 UBI，没有混用命令；
- [ ] 配置备份已下载到电脑；
- [ ] 设备端固件 SHA-256 正确；
- [ ] 只写非运行槽；
- [ ] kernel/root 或目标 release 已读回验收；
- [ ] 配置备份已写入目标 rootfs_data；
- [ ] 目标 UBI 已成功 detach；
- [ ] 旧槽保留为回退槽；
- [ ] 启动后核验实际版本、`/proc/cmdline` 和持久 overlay；
- [ ] 有线、无线和配置均验证；
- [ ] 第二次完整重启后仍正常。
