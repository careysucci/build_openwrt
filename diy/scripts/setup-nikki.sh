#!/bin/sh
# =============================================================
# /root/setup-nikki.sh — Nikki (mihomo) 一键首次配置脚本
#
# 用法：
#   ./setup-nikki.sh <Clash格式订阅URL>
# 或直接运行（无参数时交互输入）：
#   ./setup-nikki.sh
#
# 完成的工作：
#   1. 停止 OpenClash（两者共享端口，不能同时运行）
#   2. 下载订阅节点写入 proxy-provider 缓存（立即生效）
#   3. 将真实订阅 URL 写入 YAML（mihomo 每 24h 自动更新）
#   4. 禁用 OpenClash 开机自启，启用并启动 Nikki
#
# 说明：
#   - Nikki 与 OpenClash 使用相同端口，同一时刻只能运行一个
#   - 运行本脚本后 Nikki 接管流量，OpenClash 保持停止
#   - 如需切换回 OpenClash：/root/setup-openclash.sh <url>
#   - 自动更新由 mihomo 内核处理，无需 Nikki UI 订阅管理
# =============================================================

YAML_CFG="/etc/nikki/profiles/nikki-config.yaml"
PROVIDER_PATH="/etc/nikki/run/providers/cc-auto.yaml"
PLACEHOLDER_URL="http://127.0.0.1:11111/subscription"

# ─── 输出辅助（busybox ash 兼容）────────────────────────────
_ok()   { echo "  [✓] $*"; }
_err()  { echo "  [✗] ERROR: $*" >&2; }
_info() { echo "  [·] $*"; }
_step() { echo ""; echo "── 步骤 $* ──────────────────────────────────────────"; }

echo ""
echo "================================================"
echo "  Nikki (mihomo) 首次配置脚本"
echo "================================================"

# ─── 获取订阅 URL ─────────────────────────────────────────
SUB_URL="${1:-}"
if [ -z "$SUB_URL" ]; then
    echo ""
    echo "请输入你的 Clash 格式订阅 URL:"
    echo "（提示：URL 应返回含 'proxies:' 列表的 YAML，"
    echo "       如需 Clash 格式可在 URL 末尾加 ?client_type=clash 或 &flag=clash）"
    echo ""
    printf "订阅 URL > "
    read -r SUB_URL
fi

if [ -z "$SUB_URL" ]; then
    _err "订阅 URL 不能为空"
    exit 1
fi

_info "订阅 URL: $SUB_URL"

# ─── 步骤 1：停止 OpenClash（与 Nikki 互斥）─────────────
_step "1: 停止 OpenClash（端口互斥）"

if [ -f /etc/init.d/openclash ]; then
    _info "停止 OpenClash..."
    /etc/init.d/openclash stop 2>/dev/null || true
    /etc/init.d/openclash disable 2>/dev/null || true
    # 写入 UCI 防止下次启动时 OpenClash 自动接管
    uci set openclash.config.enable=0 2>/dev/null || true
    uci commit openclash 2>/dev/null || true
    _ok "OpenClash 已停止并禁用开机自启"
else
    _info "OpenClash 未安装，跳过"
fi

# ─── 步骤 2：下载订阅节点到 proxy-provider 缓存 ──────────
_step "2: 下载订阅节点"

mkdir -p "$(dirname "$PROVIDER_PATH")"
TMP_FILE="/tmp/nk_setup_$$.yaml"

_info "正在下载..."
if ! curl -fsSL --connect-timeout 30 --max-time 120 "$SUB_URL" -o "$TMP_FILE" 2>&1; then
    rm -f "$TMP_FILE"
    _err "下载失败，请检查："
    echo "        1. 路由器当前能否上网（Nikki/OpenClash 均未启动时应可直接上网）"
    echo "        2. 订阅 URL 是否正确"
    echo "        3. 手动测试：curl -v '$SUB_URL'"
    exit 1
fi

# 说明：不强制校验内容格式，下载到什么就写入什么。
#       （建议使用 Clash 格式订阅，否则 mihomo 可能无法解析节点）
PROXY_COUNT=$(grep -c "^  - " "$TMP_FILE" 2>/dev/null || echo 0)
cp "$TMP_FILE" "$PROVIDER_PATH"
rm -f "$TMP_FILE"
_ok "节点缓存已写入：$PROVIDER_PATH（共 $PROXY_COUNT 条节点）"

# ─── 步骤 3：将真实 URL 写入 YAML（启用 mihomo 24h 自动更新）
_step "3: 更新 YAML proxy-provider URL（启用自动更新）"

if [ ! -f "$YAML_CFG" ]; then
    _err "找不到配置文件：$YAML_CFG"
    echo "        可能固件未正确打包，跳过此步骤"
else
    # ── 安全说明 ──────────────────────────────────────────────────
    # 精确匹配出厂占位字符串，避免误改 rule-providers 等区段的 url 字段。
    # 占位 URL 在整个 YAML 中唯一出现一次（proxy-providers.cc-auto.url）。
    # ─────────────────────────────────────────────────────────────

    # 转义 URL 中对 sed 替换部分有特殊含义的字符：\ 和 &
    URL_ESC=$(printf '%s' "$SUB_URL" | sed 's/[\\&]/\\&/g')

    if grep -q "127\.0\.0\.1:11111/subscription" "$YAML_CFG"; then
        # ── 首次运行：出厂占位 URL 仍在，直接替换 ────────────────
        sed -i "s|url: \"http://127.0.0.1:11111/subscription\"|url: \"${URL_ESC}\"|" "$YAML_CFG"
        if grep -q "$SUB_URL" "$YAML_CFG" 2>/dev/null; then
            _ok "YAML proxy-provider URL 已写入（首次配置）"
            _info "mihomo 将每 86400 秒（24h）自动拉取最新节点"
        else
            _err "YAML 写入失败，请手动编辑："
            echo "      文件  : $YAML_CFG"
            echo "      字段  : proxy-providers.cc-auto.url"
            echo "      改为  : url: \"$SUB_URL\""
        fi
    else
        # ── 非首次运行：占位 URL 已不存在 ─────────────────────────
        _info "占位 URL 已被替换（非首次运行），节点缓存已在步骤 2 更新"
        _info "如需更换订阅地址，手动编辑："
        _info "  $YAML_CFG → proxy-providers.cc-auto.url"
    fi
fi

# ─── 步骤 4：启用并启动 Nikki ────────────────────────────
_step "4: 启用并启动 Nikki"

_info "写入 UCI 配置..."
uci set nikki.config.enabled=1
uci commit nikki

_info "设置 Nikki 开机自启..."
/etc/init.d/nikki enable 2>/dev/null || true

_info "启动 Nikki（mihomo 内核加载中，约需 5-15 秒）..."
/etc/init.d/nikki start
_ok "Nikki 启动命令已执行"

# ─── 完成 ────────────────────────────────────────────────
ROUTER_IP=$(uci get network.lan.ipaddr 2>/dev/null || echo '172.16.3.18')

echo ""
echo "================================================"
echo "  配置完成！"
echo "================================================"
echo "  节点数量   : $PROXY_COUNT"
echo "  自动更新   : 每 24 小时（mihomo 内核原生）"
echo "  控制面板   : http://${ROUTER_IP}:9091/ui/"
echo ""
echo "  等待 10-15 秒后在控制面板查看节点是否已加载。"
echo "  如节点未出现，运行：/etc/init.d/nikki status"
echo ""
echo "  切换回 OpenClash：/root/setup-openclash.sh"
echo "================================================"
echo ""

