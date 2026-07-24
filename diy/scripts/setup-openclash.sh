#!/bin/sh
# =============================================================
# /root/setup-openclash.sh — OpenClash 一键首次配置脚本
#
# 用法：
#   ./setup-openclash.sh <Clash格式订阅URL>
# 或直接运行（无参数时交互输入）：
#   ./setup-openclash.sh
#
# 完成的工作：
#   1. 下载订阅节点写入 proxy-provider 缓存（立即生效）
#   2. 将真实订阅 URL 写入 YAML（mihomo 每 24h 自动更新）
#   3. 启用并启动 OpenClash
#
# 说明：
#   - OpenClash 出厂默认禁用，首次刷机后直接上网不受影响
#   - 运行本脚本后 OpenClash 接管流量，所有外网经代理走
#   - 自动更新由 mihomo 内核处理，无需 OpenClash UI 订阅管理
# =============================================================

YAML_CFG="/etc/openclash/config/clash-all-noicon-clash.yaml"
PROVIDER_PATH="/etc/openclash/config/providers/cc-auto.yaml"
PLACEHOLDER_URL="http://127.0.0.1:11111/subscription"

# ─── 颜色输出（busybox ash 兼容）────────────────────────────
_ok()   { echo "  [✓] $*"; }
_err()  { echo "  [✗] ERROR: $*" >&2; }
_info() { echo "  [·] $*"; }
_step() { echo ""; echo "── 步骤 $* ──────────────────────────────────────────"; }

echo ""
echo "================================================"
echo "  OpenClash 首次配置脚本"
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

# ─── 步骤 0：停止 Nikki（与 OpenClash 互斥）─────────────
# 二者共享同一组端口（tproxy/mixed/http/socks），不能同时运行。
if [ -f /etc/init.d/nikki ]; then
    _NIKKI_RUNNING=0
    /etc/init.d/nikki status 2>/dev/null | grep -q "running" && _NIKKI_RUNNING=1
    if [ "$_NIKKI_RUNNING" -eq 1 ] || \
       [ "$(uci -q get nikki.config.enabled 2>/dev/null)" = "1" ]; then
        _info "检测到 Nikki 运行中，停止并禁用..."
        /etc/init.d/nikki stop 2>/dev/null || true
        /etc/init.d/nikki disable 2>/dev/null || true
        uci set nikki.config.enabled=0 2>/dev/null || true
        uci commit nikki 2>/dev/null || true
        _ok "Nikki 已停止并禁用开机自启"
    fi
fi
# ─── 步骤 1：下载订阅节点到 proxy-provider 缓存 ──────────
_step "1: 下载订阅节点"

mkdir -p "$(dirname "$PROVIDER_PATH")"
TMP_FILE="/tmp/oc_setup_$$.yaml"

_info "正在下载..."
if ! curl -fsSL --connect-timeout 30 --max-time 120 "$SUB_URL" -o "$TMP_FILE" 2>&1; then
    rm -f "$TMP_FILE"
    _err "下载失败，请检查："
    echo "        1. 路由器当前能否上网（OpenClash 未启动时应可直接上网）"
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

# ─── 步骤 2：将真实 URL 写入 YAML（启用 mihomo 24h 自动更新）
_step "2: 更新 YAML proxy-provider URL（启用自动更新）"

if [ ! -f "$YAML_CFG" ]; then
    _err "找不到配置文件：$YAML_CFG"
    echo "        可能固件未正确打包，跳过此步骤"
else
    # ── 安全说明（为什么不能用范围表达式）──────────────────────
    # 错误做法：sed "/^  cc-auto:/,/^  [a-zA-Z]/{s|url:.*|...|}"
    #   该范围在 YAML 文件中永远不会关闭（cc-auto: 之后没有同级
    #   两空格开头的 key），会一路延伸到 rule-providers 区段，把
    #   数十条 rule-provider 的 url 字段全部替换为订阅 URL，彻底
    #   损坏 YAML，导致 mihomo 无法启动。
    #
    # 正确做法：精确匹配出厂占位字符串。
    #   占位 URL "http://127.0.0.1:11111/subscription" 在整个 YAML
    #   中唯一出现一次（proxy-providers.cc-auto.url），精确替换
    #   绝对安全，不会误伤其他字段。
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
        _info "占位 URL 已被替换（非首次运行），节点缓存已在步骤 1 更新"
        _info "如需更换订阅地址，手动编辑："
        _info "  $YAML_CFG → proxy-providers.cc-auto.url"
    fi
fi

# ─── 步骤 3：启用并启动 OpenClash ────────────────────────
_step "3: 启用并启动 OpenClash"

_info "写入 UCI 配置..."
uci set openclash.config.enable=1
uci commit openclash

_info "设置 OpenClash 开机自启..."
/etc/init.d/openclash enable 2>/dev/null || true

_info "启动 OpenClash（mihomo 内核加载中，约需 5-15 秒）..."
/etc/init.d/openclash start
_ok "OpenClash 启动命令已执行"

# ─── 完成 ────────────────────────────────────────────────
ROUTER_IP=$(uci get network.lan.ipaddr 2>/dev/null || echo '172.16.3.18')

echo ""
echo "================================================"
echo "  配置完成！"
echo "================================================"
echo "  节点数量   : $PROXY_COUNT"
echo "  自动更新   : 每 24 小时（mihomo 内核原生）"
echo "  控制面板   : http://${ROUTER_IP}:9090/ui/"
echo ""
echo "  等待 10-15 秒后在控制面板查看节点是否已加载。"
echo "  如节点未出现，运行：/etc/init.d/openclash status"
echo ""
echo "  切换到 Nikki：/root/setup-nikki.sh"
echo "================================================"
echo ""


