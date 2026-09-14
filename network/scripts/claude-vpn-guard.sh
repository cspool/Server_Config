#!/bin/bash
# claude-vpn-guard —— openvpn3(Claude专用隧道) 与 clash 的路由守护
#
# 正常态（clash 存活 且 clash 绑定的接口名 == 实际 tun）：
#   收窄隧道——清掉 openvpn3 推送的大批路由，只保留 table 100 + `oif <tun>` 规则，
#   于是只有被 clash 显式绑定过来的 Claude 流量进隧道；pip/conda/HF/docker 等全部留给 clash。
#
# 兜底态（clash 退出 或 接口名失配）：
#   把 0.0.0.0/1 + 128.0.0.0/1 指向隧道，全部流量经 openvpn3 出去，保证不断网。
#   （VPN 服务器用 /32 固定走 eno1，避免环路。）
#   接口名失配时还会自愈：改 clash 配置并热重载 mihomo，下一轮自动回到收窄态。
#
# 日志：只在状态发生变化时写一条，内含「解决办法」。查看： journalctl -t claude-vpn-guard

set -u

TABLE=100
RULE_PREF=50
TUN_GW=198.18.0.1
CLASH_IF=Mihomo
CLASH_DIR=/etc/mihomo
CLASH_CFG="$CLASH_DIR/config.yaml"
SCRIPT_JS="$CLASH_DIR/Script.js"
VPN_USER=descfly
VPN_PROFILE=waimaot-liuzhixiang.ovpn
CACHE_DIR=/var/lib/claude-vpn-guard
CACHE_SRV="$CACHE_DIR/server_ip"
STATE_FILE="$CACHE_DIR/state"

mkdir -p "$CACHE_DIR"
PREV_STATE=$(cat "$STATE_FILE" 2>/dev/null || echo "")

log() { logger -t claude-vpn-guard "$*"; }

# 往用户的图形桌面发通知（脚本以 root 运行，需借用户的 DISPLAY / D-Bus）
notify_user() {
    local urgency="$1" title="$2" body="$3" uid
    uid=$(id -u "$VPN_USER" 2>/dev/null) || return 0
    [ -S "/run/user/$uid/bus" ] || return 0
    runuser -u "$VPN_USER" -- env DISPLAY=:0 \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
        notify-send -a "claude-vpn-guard" -u "$urgency" "$title" "$body" >/dev/null 2>&1 || true
}

# 仅当状态与上次不同才「写日志 + 弹窗」，避免每 20 秒刷屏
# 用法: emit <状态标识> <urgency:low|normal|critical> <弹窗标题> <弹窗正文> <日志全文>
emit() {
    local state="$1" urgency="$2" title="$3" body="$4" logmsg="$5"
    if [ "$PREV_STATE" != "$state" ]; then
        log "$logmsg"
        notify_user "$urgency" "$title" "$body"
    fi
    echo "$state" > "$STATE_FILE"
}

# ---------- 探测 openvpn3 的 tun 接口（地址在 198.18.0.0/18 的那个） ----------
TUN=$(ip -o -4 addr show 2>/dev/null | awk '$4 ~ /^198\.18\./ {print $2; exit}')
if [ -z "${TUN:-}" ]; then
    emit "no-tunnel" critical "⚠ Claude 隧道断开" \
"openvpn3 的 tun 接口不见了，Claude 走不了隧道。
① 先等 1-2 分钟看它是否自己重连
② 仍不行：openvpn3 session-manage --config $VPN_PROFILE --restart" \
"【隧道断开】找不到 openvpn3 的 tun 接口(198.18.x)，Claude 无法走隧道。\
 本脚本无法自动修复隧道本身。\
 解决办法：① 先等 1-2 分钟，openvpn3 通常会自己重连；\
 ② 仍不行则执行  openvpn3 session-manage --config $VPN_PROFILE --restart ；\
 ③ 想以后自动恢复可开启  openvpn3 config-manage --config $VPN_PROFILE --automatic-restart on-failure"
    exit 0
fi

# ---------- VPN 服务器 IP（带缓存；systemd 以 root 运行，需切到用户查会话） ----------
SRV=$(runuser -u "$VPN_USER" -- openvpn3 sessions-list 2>/dev/null \
      | grep -oE 'Connected to: [a-z]+:([0-9]{1,3}\.){3}[0-9]{1,3}' \
      | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
if [ -n "${SRV:-}" ]; then
    echo "$SRV" > "$CACHE_SRV"
elif [ -f "$CACHE_SRV" ]; then
    SRV=$(cat "$CACHE_SRV")
fi

# ---------- 固定 VPN 服务器走物理网卡 eno1（任何时候都应如此，防兜底时环路） ----------
GW1=$(ip route show | awk '/^default .*dev eno1/{print $3; exit}')
if [ -n "${SRV:-}" ] && [ -n "${GW1:-}" ]; then
    ip route replace "$SRV" via "$GW1" dev eno1 2>/dev/null
fi

# ---------- table 100 + oif 规则：clash 绑定到 tun 的 socket 靠它找到出口 ----------
ip route replace default via "$TUN_GW" dev "$TUN" table "$TABLE" 2>/dev/null
ip rule list 2>/dev/null | grep -q "oif $TUN lookup $TABLE" \
    || ip rule add oif "$TUN" lookup "$TABLE" pref "$RULE_PREF" 2>/dev/null

# ---------- clash 健康状况 & 绑定的接口名 ----------
clash_alive=0
if ip link show "$CLASH_IF" >/dev/null 2>&1 && pgrep -x verge-mihomo >/dev/null 2>&1; then
    clash_alive=1
fi
cfg_if=$(grep -A2 'name: OpenVPN-tun0' "$CLASH_CFG" 2>/dev/null \
         | awk -F': *' '/interface-name/{gsub(/[" \r]/,"",$2); print $2; exit}')

# 删除主表上该 tun 的所有非内核路由（推送路由 / 兜底 /1 路由）
prune_tun_routes() {
    local p
    for p in $(ip route show 2>/dev/null | awk -v d="dev $TUN" '$0 ~ d && $0 !~ /proto kernel/ {print $1}'); do
        ip route del "$p" dev "$TUN" 2>/dev/null
    done
}

install_fallback_routes() {
    ip route replace 0.0.0.0/1   via "$TUN_GW" dev "$TUN" 2>/dev/null
    ip route replace 128.0.0.0/1 via "$TUN_GW" dev "$TUN" 2>/dev/null
}

# 自愈：tun 名字变了就改掉 clash 的绑定并热重载 mihomo
selfheal_interface_name() {
    local ec secret code
    [ -f "$SCRIPT_JS" ]  && sed -i "s/\"interface-name\": *\"tun[0-9]*\"/\"interface-name\": \"$TUN\"/" "$SCRIPT_JS"
    [ -f "$CLASH_CFG" ]  && sed -i "/name: OpenVPN-tun0/,+3 s/interface-name: *tun[0-9]*/interface-name: $TUN/" "$CLASH_CFG"
    ec=$(grep -E '^external-controller:' "$CLASH_CFG" 2>/dev/null | head -1 \
         | sed "s/^external-controller: *//; s/[\"']//g; s/[[:space:]]*$//")
    secret=$(grep -E '^secret:' "$CLASH_CFG" 2>/dev/null | head -1 \
         | sed "s/^secret: *//; s/[\"']//g; s/[[:space:]]*$//")
    code=""
    if [ -n "${ec:-}" ]; then
        code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
            -H "Authorization: Bearer ${secret:-}" -H 'Content-Type: application/json' \
            -d "{\"path\":\"$CLASH_CFG\",\"force\":true}" \
            "http://$ec/configs" 2>/dev/null)
    fi
    echo "${code:-none}"
}

# ---------- 决策 ----------
if [ "$clash_alive" = "1" ] && [ "$cfg_if" = "$TUN" ]; then
    prune_tun_routes
    emit "normal" low "✓ 路由已恢复正常" \
"clash 正常、接口名一致($TUN)。隧道现在仅承载 Claude，其余走 clash。无需任何操作。" \
"【已恢复正常】clash 正常、接口名一致($TUN)，已清理兜底路由。\
 隧道现在仅承载 Claude，pip/conda/HF/docker 等走 clash。无需任何操作。"

elif [ "$clash_alive" != "1" ]; then
    install_fallback_routes
    emit "fallback-clash-down" critical "⚠ clash 已退出（已兜底，未断网）" \
"全部流量已临时切到 openvpn3($TUN)，能上网但较慢。
解决办法：手动重新打开 Clash Verge。
恢复后 20 秒内会自动切回，无需其他操作。" \
"【兜底生效】clash 未运行 → 已把全部流量切到 openvpn3($TUN)，不会断网，但所有流量都在走 Claude 专用隧道(较慢)。\
 本脚本不会自动重启 clash。\
 解决办法：手动重新打开 Clash Verge(或 systemctl restart clash-verge-service)；\
 clash 恢复后本脚本 20 秒内会自动清掉兜底路由、回到只走 Claude 的收窄态，无需其他操作。"

else
    # clash 活着但接口名失配 → 先兜底保通，再自愈
    install_fallback_routes
    code=$(selfheal_interface_name)
    if [ "$code" = "200" ] || [ "$code" = "204" ]; then
        emit "selfheal-ok-$TUN" normal "✓ 隧道改名已自愈" \
"隧道从 $cfg_if 变成了 $TUN，已自动改好配置并重载 clash。
期间已兜底未断网，20 秒内自动恢复收窄。无需人工干预。" \
"【接口改名·已自愈】clash 绑的是 $cfg_if，实际隧道是 $TUN。\
 已自动改好 Script.js 与运行配置，并热重载 mihomo 成功(HTTP $code)，期间已用兜底路由保证不断网。\
 解决办法：无需人工干预，下一轮(20 秒内)会自动回到收窄态。"
    else
        emit "selfheal-fail-$TUN" critical "⚠ 隧道改名·需手动应用配置" \
"隧道变成 $TUN，配置已改但 clash 重载失败(HTTP $code)。当前已兜底未断网。
解决办法：Clash Verge → 配置页 → 点一下当前配置卡片重新应用。" \
"【接口改名·自愈未完成】clash 绑的是 $cfg_if，实际隧道是 $TUN，配置已改但 mihomo 热重载失败(HTTP $code)。\
 当前已用兜底路由保证不断网。\
 解决办法：打开 Clash Verge → 配置页 → 点一下当前配置卡片重新应用一次；之后 20 秒内自动回到收窄态。"
    fi
fi
