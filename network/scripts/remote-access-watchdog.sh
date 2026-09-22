#!/usr/bin/env bash
# 运行期守护:盯住 Beyond 隧道与 RDP,分级自愈,最后一级才重启主机。
#
# 判据的选择(重要):
#   用「edge 到 Beyond 节点的底层 UDP ESTAB 会话」判断隧道是否建立,
#   而不是 utun0 的收发计数 —— 后者在【对端不在线】时本来就不动,
#   拿它当判据会导致 Mac 一关机主机就每 20 分钟自己重启,打断 tmux 里的实验。
#
# 分级升压(每轮 5 分钟,由 timer 的 OnUnitActiveSec 决定):
#   L1  容器不在 running                → docker start
#   L2  utun0 缺失 / 无 overlay 路由     → docker restart edge
#   L3  无底层会话,连续 1 轮(5 分钟) → 重启 edge 容器
#   L4  无底层会话,连续 5 轮(首次发现后持续 20 分钟自愈无效) → reboot
#   RDP 独立检查:GRD 不活 / 3390 不监听 → 重启 gnome-remote-desktop
set -uo pipefail

EDGE=beyondnetwork_edge
GUI_USER=descfly
NODES_FILE=/run/beyond-eno2.routes          # ensure-beyond-eno2.sh 写的节点清单
STATE=/run/remote-access-watchdog.state     # 本次开机的连续失败计数
COOLDOWN=/var/lib/remote-access-watchdog.reboot   # 跨重启的冷却标记

L3_ROUNDS=1          # 1 轮 × 5 分钟 = 5 分钟:重启容器
L4_ROUNDS=5          # 第5轮触发:首次发现后已连续尝试 4×5=20 分钟
MIN_UPTIME=900       # 开机不足 15 分钟不重启,防引导循环
COOLDOWN_SEC=7200    # 两次自动重启至少间隔 2 小时

log() { printf '[remote-access-watchdog] %s\n' "$*"; }

# 隧道是否已建立:edge 进程与任一 Beyond 节点有 UDP ESTAB
tunnel_up() {
    local nodes
    nodes="$(sed 's|/32||' "$NODES_FILE" 2>/dev/null | paste -sd'|' -)"
    [ -n "$nodes" ] || nodes='8\.156\.|47\.94\.|139\.196\.|42\.240\.'
    docker exec "$EDGE" sh -c 'ss -unap 2>/dev/null' 2>/dev/null \
        | grep -E 'ESTAB' | grep -E "$nodes" | grep -q 'edge'
}

restart_edge() {
    log "重启隧道容器($1)"
    docker restart "$EDGE" >/dev/null 2>&1 || { log "✗ docker restart 失败"; return 1; }
    for _ in $(seq 20); do
        ip link show utun0 >/dev/null 2>&1 && [ -n "$(ip route show dev utun0 2>/dev/null)" ] && break
        sleep 1
    done
    log "utun0 路由: $(ip route show dev utun0 2>/dev/null | tr '\n' ' ')"
}

do_reboot() {
    local up now last
    up="$(cut -d. -f1 /proc/uptime)"
    if [ "$up" -lt "$MIN_UPTIME" ]; then
        log "已达重启阈值,但开机仅 ${up}s(<${MIN_UPTIME}s)→ 跳过,防引导循环"; return
    fi
    now="$(date +%s)"; last="$(cat "$COOLDOWN" 2>/dev/null || echo 0)"
    if [ $((now - last)) -lt "$COOLDOWN_SEC" ]; then
        log "已达重启阈值,但距上次自动重启仅 $(((now-last)/60)) 分钟(<$((COOLDOWN_SEC/60)))→ 跳过"; return
    fi
    mkdir -p "$(dirname "$COOLDOWN")"; echo "$now" > "$COOLDOWN"
    log "⚠ 隧道已断 $(((L4_ROUNDS-1)*5)) 分钟且容器重启无效 → 自动重启主机"
    log "⚠ 注意:tmux 会话与 RestartPolicy=no 的容器会丢失"
    logger -t remote-access-watchdog "自动重启:Beyond 隧道断连超过 $(((L4_ROUNDS-1)*5)) 分钟"
    sync; sleep 2
    systemctl reboot
}

# ───── 隧道 ─────
st="$(docker inspect -f '{{.State.Status}}' "$EDGE" 2>/dev/null || echo missing)"
if [ "$st" = missing ]; then
    log "✗ 容器 $EDGE 不存在,需人工重装(quick-install)"
elif [ "$st" != running ]; then
    log "容器状态 $st → 启动"; docker start "$EDGE" >/dev/null 2>&1; : > "$STATE"
else
    if ! ip link show utun0 >/dev/null 2>&1; then
        restart_edge "utun0 接口缺失"; : > "$STATE"
    elif [ -z "$(ip route show dev utun0 2>/dev/null)" ]; then
        restart_edge "utun0 无 overlay 路由"; : > "$STATE"
    else
        cnt="$(cat "$STATE" 2>/dev/null || echo 0)"; [ -z "$cnt" ] && cnt=0
        if tunnel_up; then
            [ "$cnt" -gt 0 ] && log "✓ 隧道已恢复(此前连续失败 ${cnt} 轮)"
            echo 0 > "$STATE"
        else
            cnt=$((cnt + 1)); echo "$cnt" > "$STATE"
            if   [ "$cnt" -ge "$L4_ROUNDS" ]; then
                do_reboot
            elif [ $((cnt % L3_ROUNDS)) -eq 0 ]; then
                restart_edge "无底层会话已连续 ${cnt} 轮(约 $(((cnt-1)*5)) 分钟)"
            fi
        fi
    fi
fi

# ───── RDP(独立于隧道) ─────
uid="$(id -u "$GUI_USER" 2>/dev/null)" || exit 0
if [ -d "/run/user/$uid" ] && loginctl list-sessions --no-legend 2>/dev/null \
   | awk -v u="$GUI_USER" '$3==u || $4==u {f=1} END{exit !f}'; then
    act="$(runuser -u "$GUI_USER" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
           systemctl --user is-active gnome-remote-desktop 2>/dev/null)"
    port="$(ss -ltn | grep -c ':3390 ')"
    if [ "$act" != active ] || [ "$port" -eq 0 ]; then
        log "RDP 异常(服务 $act,3390 监听 $port)→ 重启"
        runuser -u "$GUI_USER" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
            systemctl --user restart gnome-remote-desktop >/dev/null 2>&1
        sleep 2; log "重启后 3390 监听数: $(ss -ltn | grep -c ':3390 ')"
    fi
fi
exit 0
