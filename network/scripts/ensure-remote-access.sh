#!/usr/bin/env bash
# mihomo.service 的最后一步 ExecStartPost(排在 guard 之后,但不依赖 guard)。
#
# 为什么需要:分流路由一变,Beyond 隧道的底层 UDP 会话会僵死、RDP 的既有连接会断。
# 主机重启或分流栈重启后,远程往往连不上 —— 不是服务没起,是隧道底层路径变了。
# 所以在路由就位后主动重启这两项。
#
# 健康门槛:只有 mihomo 真的起来了(API 可达 + Mihomo TUN 存在)才动作。
# 否则在 crash loop 里会每 3 秒重启一次隧道容器,造成更大破坏。
set -uo pipefail

GUI_USER=descfly
EDGE=beyondnetwork_edge
EC=127.0.0.1:9097
WAIT=25

log() { printf '[ensure-remote-access] %s\n' "$*"; }

# ── 健康门槛 ──
ready=0
for i in $(seq "$WAIT"); do
    if curl -s -m 2 -o /dev/null "http://$EC/version" 2>/dev/null \
       && ip link show Mihomo >/dev/null 2>&1; then
        ready=1; log "mihomo 就位(API + TUN,${i}s)"; break
    fi
    sleep 1
done
if [ "$ready" != 1 ]; then
    log "mihomo 未就位(${WAIT}s 超时)→ 跳过隧道与 RDP 重启,避免 crash loop 中反复动作"
    exit 0
fi

# ── ① 重启内网穿透隧道 ──
if docker inspect "$EDGE" >/dev/null 2>&1; then
    if docker restart "$EDGE" >/dev/null 2>&1; then
        log "已重启隧道容器 $EDGE"
        for i in $(seq 20); do ip link show utun0 >/dev/null 2>&1 && break; sleep 1; done
        if ip link show utun0 >/dev/null 2>&1; then
            log "utun0 就位:$(ip route show dev utun0 2>/dev/null | tr '\n' ' ')"
        else
            log "警告:utun0 未出现"
        fi
    else
        log "警告:重启 $EDGE 失败"
    fi
else
    log "未找到容器 $EDGE,跳过"
fi

# ── ② 重启远程桌面(用户级服务) ──
uid="$(id -u "$GUI_USER" 2>/dev/null)" || { log "用户 $GUI_USER 不存在"; exit 0; }
if [ -d "/run/user/$uid" ] && loginctl list-sessions --no-legend 2>/dev/null \
   | awk -v u="$GUI_USER" '$3==u || $4==u {f=1} END{exit !f}'; then
    if runuser -u "$GUI_USER" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
         systemctl --user restart gnome-remote-desktop >/dev/null 2>&1; then
        sleep 2
        p="$(ss -ltn | grep -c ':3390 ')"
        log "已重启 RDP(gnome-remote-desktop),3390 监听数 $p"
    else
        log "警告:重启 RDP 失败"
    fi
else
    log "无图形会话 → 跳过 RDP(登录后随会话自启)"
fi
exit 0
