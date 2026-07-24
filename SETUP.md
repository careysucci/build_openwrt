# 本地编译系统设置

## 快速验证

在开始编译前，运行设置验证脚本：

```bash
bash scripts/setup.sh
```

此脚本将检查：
- 目录和文件结构
- 脚本权限
- 系统要求
- 必需的命令
- ShellCheck代码质量

## 系统要求检查清单

### 操作系统
- [ ] Ubuntu 20.04 LTS 或更新版本
- [ ] Debian 11 或更新版本
- [ ] Linux Mint 20 或更新版本
- [ ] Pop!_OS 20.04 或更新版本

### 硬件要求
- [ ] 处理器：4核或更多
- [ ] 内存：最少 2GB (推荐 4GB)
- [ ] 磁盘：最少 30GB 可用空间

### 网络要求
- [ ] 可靠的互联网连接
- [ ] 能访问 GitHub 和其他源代码仓库

## 初始化步骤

### 1. Clone 仓库

```bash
git clone https://github.com/careysucci/build_openwrt.git
cd build_openwrt
```

### 2. 验证设置

```bash
bash scripts/setup.sh
```

### 3. 查看配置

```bash
# 查看LEDE编译配置
cat diy/x86/lean_auto.config

# 查看官方OpenWrt编译配置
cat diy/x86/official_auto.config
```

### 4. (可选) 安装ShellCheck用于代码质量检查

```bash
sudo apt-get install shellcheck
```

## 开始编译

### LEDE 版本

```bash
# 使用默认 Go 版本 (1.26)
bash build.sh lede

# 指定 Go 版本
bash build.sh lede 1.25
bash build.sh lede 1.24
```

### 官方 OpenWrt 版本

```bash
# 使用默认 Go 版本 (1.26)
bash build.sh official

# 指定 Go 版本
bash build.sh official 1.25
bash build.sh official 1.24
```

## 编译进度监控

在新的终端窗口查看实时日志：

```bash
# 查看主编译日志
tail -f output/logs/08_compile.log

# 查看所有日志
ls -lh output/logs/

# 查看固件输出
ls -lh output/firmware/
```

## 故障排除

### 依赖自动安装失败

手动安装编译依赖：

```bash
sudo apt-get update
sudo apt-get install build-essential clang flex bison g++ gawk \
  gcc-multilib g++-multilib gettext git libncurses5-dev libssl-dev \
  python3-setuptools rsync swig unzip zlib1g-dev file wget \
  llvm python3-pyelftools libpython3-dev aria2 jq qemu-utils ccache \
  rename libelf-dev device-tree-compiler libgmp3-dev libmpc-dev \
  libfuse-dev dwarves pkg-config cmake ninja-build libffi-dev
```

### 磁盘空间不足

清理现有编译:

```bash
rm -rf lede/ official/ output/
```

### 网络连接问题

脚本会自动重试，但如果持续失败，尝试：

1. 检查网络连接
2. 使用VPN或代理
3. 手动克隆源代码：

```bash
# LEDE
git clone https://github.com/coolsnowwolf/lede.git lede

# Official OpenWrt
git clone https://github.com/openwrt/openwrt.git official
cd official
git checkout openwrt-25.12
cd ..
```

然后重新运行 `bash build.sh`

## 编译输出

编译完成后，输出位置：

```
output/
├── firmware/              # 固件文件
├── logs/                  # 编译日志
├── .config.backup         # 编译配置备份
├── build.info             # 编译信息
├── manifest.txt           # 编译清单
└── sha256sum.txt          # SHA256校验和
```

获取固件文件：

```bash
ls -lh output/firmware/
```

## 高级配置

### 自定义编译参数

编辑配置文件：

```bash
# LEDE 配置
nano diy/x86/lean_auto.config

# 或官方 OpenWrt 配置  
nano diy/x86/official_auto.config
```

然后重新编译：

```bash
bash build.sh lede 1.26
```

### 断点续编

编译中断后可继续：

```bash
# 继续编译（不重新clone和下载）
bash build.sh lede 1.26
```

脚本会自动检测已有的源代码、下载缓存和编译产物。

### 完全清理

```bash
# 删除所有编译产物（保留日志）
rm -rf lede/ official/

# 删除所有包括日志
rm -rf lede/ official/ output/

# 只删除编译中间文件
rm -rf lede/build_dir/ official/build_dir/
```

## GitHub Actions 和本地编译

两者使用完全相同的：
- DIY脚本 (diy-part1.sh, diy-part2.sh)
- 配置文件 (diy/x86/*.config)
- 编译步骤和顺序
- 输出组织方式

### 同步更新

如果GitHub Actions workflow有更新，本地编译脚本结构也会相应更新，无需手动修改。

## 常见问题

**Q: 编译需要多长时间？**
A: 取决于硬件配置。通常需要30分钟到2小时。

**Q: 能否同时编译LEDE和官方版本？**
A: 可以，使用不同的终端窗口运行即可。

**Q: 如何加速编译？**
A: 
- 确保有足够的物理内存（4GB+）
- 关闭其他应用
- 使用SSD而不是HDD
- ccache会自动缓存编译结果

**Q: 编译失败如何调试？**
A: 查看 output/logs/08_compile.log 获取详细错误信息。

## 获取帮助

- 查看 README_LOCAL_BUILD.md 了解详细文档
- 查看 output/logs/ 中的日志文件
- 提交Issue到GitHub项目

## 许可证

MIT License
