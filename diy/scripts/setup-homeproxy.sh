#!/bin/sh
# 首次接入 HomeProxy：只传入订阅 URL，成功后自动更新并启动。
set -eu

SUB_URL="${1:-}"
case "$SUB_URL" in
    http://*|https://*) ;;
    *)
        echo "用法：$0 'https://你的订阅地址'" >&2
        exit 2
        ;;
esac

# 预检不修改配置或服务状态。
command -v uci >/dev/null 2>&1 && command -v ucode >/dev/null 2>&1 || {
    echo "错误：缺少 uci 或 ucode。" >&2
    exit 1
}
for executable in \
    /etc/init.d/homeproxy \
    /etc/homeproxy/scripts/update_subscriptions.sh \
    /usr/libexec/homeproxy-runtime-init \
    /usr/bin/sing-box
do
    [ -x "$executable" ] || {
        echo "错误：缺少可执行文件 $executable。" >&2
        exit 1
    }
done
for script in cleanup_urltest.uc generate_client.uc; do
    [ -f "/etc/homeproxy/scripts/$script" ] || {
        echo "错误：缺少 HomeProxy 脚本 $script。" >&2
        exit 1
    }
done
uci -q get homeproxy.config >/dev/null 2>&1 && \
    uci -q get homeproxy.subscription >/dev/null 2>&1 || {
    echo "错误：HomeProxy UCI 尚未初始化。" >&2
    exit 1
}
[ -f /etc/config/homeproxy ] || {
    echo "错误：缺少 /etc/config/homeproxy。" >&2
    exit 1
}

STATE_DIR=$(mktemp -d /tmp/setup-homeproxy.XXXXXX)
TRANSACTION_STARTED=0
SUCCESS=0

save_service_state() {
    local service="$1" init_script="/etc/init.d/$1"
    [ -x "$init_script" ] || return 0
    if "$init_script" enabled >/dev/null 2>&1; then
        echo 1 > "$STATE_DIR/$service.enabled"
    else
        echo 0 > "$STATE_DIR/$service.enabled"
    fi
    if "$init_script" running >/dev/null 2>&1; then
        echo 1 > "$STATE_DIR/$service.running"
    else
        echo 0 > "$STATE_DIR/$service.running"
    fi
}

restore_service() {
    local service="$1" init_script="/etc/init.d/$1"
    [ -x "$init_script" ] || return 0
    if [ "$(cat "$STATE_DIR/$service.enabled")" = '1' ]; then
        "$init_script" enable >/dev/null 2>&1 || return 1
    else
        "$init_script" disable >/dev/null 2>&1 || return 1
    fi
    if [ "$(cat "$STATE_DIR/$service.running")" = '1' ]; then
        "$init_script" restart >/dev/null 2>&1 || return 1
    else
        "$init_script" stop >/dev/null 2>&1 || return 1
    fi
}

on_exit() {
    local rc="$?" rollback_failed=0 config_restored=0 service
    trap - EXIT HUP INT TERM
    if [ "$SUCCESS" -eq 1 ] || [ "$TRANSACTION_STARTED" -eq 0 ]; then
        rm -rf "$STATE_DIR"
        exit "$rc"
    fi

    echo "正在回滚 HomeProxy 配置及原代理服务状态……" >&2
    set +e
    /etc/init.d/homeproxy stop >/dev/null 2>&1
    uci -q revert homeproxy >/dev/null 2>&1
    if cp -f "$STATE_DIR/homeproxy.config" /etc/config/homeproxy; then
        config_restored=1
    else
        rollback_failed=1
    fi

    if [ "$config_restored" -eq 1 ]; then
        restore_service homeproxy || rollback_failed=1
    else
        /etc/init.d/homeproxy disable >/dev/null 2>&1
    fi
    for service in openclash nikki dae; do
        restore_service "$service" || rollback_failed=1
    done

    if [ "$rollback_failed" -eq 0 ]; then
        rm -rf "$STATE_DIR"
        echo "回滚完成。" >&2
    else
        echo "警告：回滚未完全成功，原配置和状态保留在 $STATE_DIR。" >&2
    fi
    exit "$rc"
}
trap on_exit EXIT
trap 'exit 1' HUP INT TERM

cp -f /etc/config/homeproxy "$STATE_DIR/homeproxy.config"
chmod 600 "$STATE_DIR/homeproxy.config"
for service in homeproxy openclash nikki dae; do
    save_service_state "$service"
done
TRANSACTION_STARTED=1

# 防止更新器在旧 HomeProxy 仍运行时直接重启并应用未校验配置。
/etc/init.d/homeproxy stop >/dev/null 2>&1 || {
    echo "错误：无法暂停旧 HomeProxy。" >&2
    exit 1
}

# 不在日志或终端回显订阅 URL，避免泄露其中的令牌。
uci set homeproxy.config.main_node='urltest'
uci set homeproxy.config.routing_mode='bypass_mainland_china'
uci -q delete homeproxy.config.routing_port
uci set homeproxy.subscription.auto_urltest='1'
uci set homeproxy.subscription.auto_update='1'
uci set homeproxy.subscription.update_via_proxy='0'
uci set homeproxy.subscription.allow_insecure='0'
uci -q delete homeproxy.subscription.subscription_url
uci add_list homeproxy.subscription.subscription_url="$SUB_URL"
uci commit homeproxy

echo "[1/4] 正在更新订阅并收敛 URLTest 节点……"
if ! /etc/homeproxy/scripts/update_subscriptions.sh; then
    echo "错误：订阅更新失败，请检查 URL、格式和 /var/run/homeproxy/homeproxy.log。" >&2
    exit 1
fi

NODE_COUNT=$(uci -q show homeproxy 2>/dev/null | grep -c '=node$' || true)
URLTEST_NODES=$(uci -q get homeproxy.config.main_urltest_nodes 2>/dev/null || true)
if [ "${NODE_COUNT:-0}" -eq 0 ] || [ -z "$URLTEST_NODES" ]; then
    echo "错误：节点或自动 URLTest 为空；构建补丁可能未生效。" >&2
    exit 1
fi

# 与上游 start_service 使用相同的生成器和 sing-box 校验，在停用其他
# 代理之前发现配置错误。init 启动时还会再完整校验一次。
echo "[2/4] 正在生成并校验 ${NODE_COUNT} 个节点的运行配置……"
/usr/libexec/homeproxy-runtime-init
ucode -S /etc/homeproxy/scripts/cleanup_urltest.uc >>/var/run/homeproxy/homeproxy.log 2>&1
rm -f /var/run/homeproxy/sing-box-c.json.new
if ! ucode -S /etc/homeproxy/scripts/generate_client.uc >>/var/run/homeproxy/homeproxy.log 2>&1 || \
   [ ! -s /var/run/homeproxy/sing-box-c.json.new ]; then
    echo "错误：HomeProxy 运行配置生成失败。" >&2
    exit 1
fi
if ! /usr/bin/sing-box check --config /var/run/homeproxy/sing-box-c.json.new \
    >>/var/run/homeproxy/homeproxy.log 2>&1; then
    echo "错误：sing-box 配置校验失败。" >&2
    exit 1
fi

echo "[3/4] 预校验通过，正在切换透明代理……"
for service in openclash nikki dae; do
    if [ -x "/etc/init.d/$service" ]; then
        "/etc/init.d/$service" stop >/dev/null 2>&1 || {
            echo "错误：无法停止 $service。" >&2
            exit 1
        }
    fi
done
if ! /etc/init.d/homeproxy restart; then
    echo "错误：HomeProxy 启动失败，请查看 /var/run/homeproxy/homeproxy.log。" >&2
    exit 1
fi
if ! /etc/init.d/homeproxy running >/dev/null 2>&1 || \
   [ ! -s /var/run/homeproxy/sing-box-c.json ]; then
    echo "错误：HomeProxy 客户端未进入运行状态。" >&2
    exit 1
fi
sleep 3
if ! /etc/init.d/homeproxy running >/dev/null 2>&1; then
    echo "错误：HomeProxy 启动后异常退出。" >&2
    exit 1
fi

# 只有稳定运行后才修改开机启用状态；失败时由 trap 恢复。
echo "[4/4] 正在固化启用状态……"
/etc/init.d/homeproxy enable
for service in openclash nikki dae; do
    if [ -x "/etc/init.d/$service" ]; then
        "/etc/init.d/$service" disable >/dev/null 2>&1 || {
            echo "错误：无法禁用 $service 的开机启动。" >&2
            exit 1
        }
    fi
done

SUCCESS=1
echo "HomeProxy 已启动：全端口规则、境外 DoH 经代理、URLTest 自动选择。"
echo "配置或启动失败时会自动恢复原 UCI 及原代理运行状态。"
echo "注意：国内直连是明确分流；WebRTC 本机地址需在浏览器侧禁用或限制。"
echo "普通 TLS 的 SNI 仍需节点提供 REALITY/ECH 才能隐藏，uTLS 只降低 ClientHello 指纹。"
