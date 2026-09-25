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
#   L3  隧道判据失败,连续 1 轮(5 分钟) → 重启 edge 容器
#   L4  【任何形式的未确认健康】连续 5 轮(约 20 分钟自愈无效) → reboot
#       用独立计数器 ANYFAIL,只在隧道确认健康时清零 —— 这样反复抖动
#       (每轮走不同分支)也能升级,不会被各分支的清零互相抵消
#       (带 sysrq 强制兜底,防优雅重启被卡住的单元拖住)
#   RDP 独立检查:GRD 不活 / 3390 不监听 → 重启 gnome-remote-desktop
set -uo pipefail

EDGE=beyondnetwork_edge
GUI_USER=descfly
# 节点清单由 ensure-beyond-underlay.sh 写入。新路径优先,旧路径兼容
# (2026-09-25 底层出口由 eno2 迁到 eno1 时改名,文件名不再绑定网卡)。
NODES_FILE=/run/beyond-underlay.routes
[ -r "$NODES_FILE" ] || NODES_FILE=/run/beyond-eno2.routes
STATE=/run/remote-access-watchdog.state     # 本次开机的连续失败计数
COOLDOWN=/var/lib/remote-access-watchdog.reboot   # 跨重启的冷却标记
RDP_CLI_MARK=/run/remote-access-watchdog.cli-mode  # CLI 模式已记录过一行的标记

L3_ROUNDS=1          # 1 轮 × 5 分钟 = 5 分钟:重启容器
L4_ROUNDS=5          # 第5轮触发:首次发现后已连续尝试 4×5=20 分钟
MIN_UPTIME=900       # 开机不足 15 分钟不重启,防引导循环
COOLDOWN_SEC=7200    # 两次自动重启至少间隔 2 小时

log() { printf '[remote-access-watchdog] %s\n' "$*"; }

# ───── 隧道健康判据(2026-09-25 重做)─────
#
# 旧判据只看「edge 与任一节点有 UDP :3005 ESTAB」。它在 2026-09-25 的事故里
# 被完整骗过 34 小时:校园网认证劫持导致 edge 拿不到节点配置、隧道从未建立,
# 但那条 UDP 保活会话一直 ESTAB,判据始终满足 → 一次都没报警、更没升级到重启。
#
# 现在用三个独立信号,**都不依赖远端对端是否在线**(这是旧设计正确的那一半:
# 不能用 utun0 的 rx/tx 增长,对端一关机它本来就不动,会导致每 20 分钟自重启)。
#
#   ① 控制通道:edge 与节点的 TCP :30004 至少一条 ESTAB
#      健康期 4 条;劫持期全部 SYN-SENT(0 条 ESTAB)—— 正是旧判据的盲区
#   ② edge 自身无新报错:/var/log/edge.log 的 [E] 行数不再增长
#      劫持期每 10 秒一条 `invalid character '<'`
#   ③ utun0 存在且有 overlay 路由(原有的 L2 检查,保留)
#
# 判定:① 与 ② 都通过才算隧道健康。任一失败即计数。

ERRCNT=/run/remote-access-watchdog.errcount   # 上次看到的 edge [E] 行数
# 两个计数器,职责不同:
#   STATE   —— 连续"判据失败"轮数,驱动 L3 的容器重启。L1/L2 分支会清零它,
#              因为那两级已经做了动作,应当给它重新观察的机会。
#   ANYFAIL —— 连续"未确认健康"轮数,**只在 tunnel_up 成功时清零**。
#              它驱动 L4。没有它的话:edge 若反复崩到 utun0 消失,每轮都走 L2、
#              每轮清零 STATE,L4 永远不会触发 —— 与"无法恢复时必须重启"冲突。
ANYFAIL=/run/remote-access-watchdog.anyfail

# ① 控制通道
control_plane_up() {
    local nodes n
    nodes="$(sed 's|/32||' "$NODES_FILE" 2>/dev/null | paste -sd'|' -)"
    [ -n "$nodes" ] || nodes='8\.156\.|47\.94\.|139\.196\.|42\.240\.'
    n=$(docker exec "$EDGE" sh -c 'ss -tnap 2>/dev/null' 2>/dev/null \
        | grep -E 'ESTAB' | grep -E ':30004' | grep -cE "$nodes")
    [ "${n:-0}" -ge 1 ]
}

# ② edge 是否在持续报错(用行数增量,避免解析时间戳与时区)
edge_erroring() {
    local cur prev
    cur=$(docker exec "$EDGE" sh -c "grep -c '\\[E\\]' /var/log/edge.log 2>/dev/null" 2>/dev/null | tr -d '\r')
    case "$cur" in ''|*[!0-9]*) return 1 ;; esac      # 读不到就不判错
    prev=$(cat "$ERRCNT" 2>/dev/null); case "$prev" in ''|*[!0-9]*) prev=$cur ;; esac
    echo "$cur" > "$ERRCNT"
    [ "$cur" -gt "$prev" ]
}

tunnel_up() {
    control_plane_up || { log "  判据①失败:无 TCP :30004 ESTAB(控制通道不通)"; return 1; }
    if edge_erroring; then
        log "  判据②失败:edge 正在持续报错(查 docker exec $EDGE tail /var/log/edge.log)"
        return 1
    fi
    return 0
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

    # 重启保证:优雅重启可能被卡住的单元拖住(NFS、容器、未响应的 umount)。
    # 用一个【脱离本 cgroup】的瞬态定时器兜底 —— 本服务是 oneshot,直接后台
    # 子进程会随服务退出被 systemd 杀掉,必须用 systemd-run 才能活到那时。
    # 若优雅重启成功,机器早已下电,这个定时器永不触发。
    if [ -w /proc/sysrq-trigger ] && command -v systemd-run >/dev/null 2>&1; then
        systemd-run --collect --on-active=180s \
            --unit=remote-access-force-reboot \
            /bin/sh -c 'logger -t remote-access-watchdog "优雅重启 180s 未完成 → sysrq 强制重启"; sync; echo b > /proc/sysrq-trigger' \
            >/dev/null 2>&1 && log "已布置 180s 强制重启兜底(sysrq)"
    else
        log "⚠ 无法布置强制兜底(sysrq 不可写或缺 systemd-run),仅依赖优雅重启"
    fi
    systemctl reboot
}

# ───── 隧道 ─────
# 累加"未确认健康"计数并在达到 L4 时重启。任何失败分支都要调它 ——
# 这样反复抖动(每轮走不同分支)也能升级,而不是被各自的清零互相抵消。
bump_anyfail() {
    local a
    a="$(cat "$ANYFAIL" 2>/dev/null || echo 0)"; case "$a" in ''|*[!0-9]*) a=0 ;; esac
    a=$((a + 1)); echo "$a" > "$ANYFAIL"
    log "  未确认健康累计 ${a}/${L4_ROUNDS} 轮(约 $(((a-1)*5)) 分钟)"
    [ "$a" -ge "$L4_ROUNDS" ] && do_reboot
}

st="$(docker inspect -f '{{.State.Status}}' "$EDGE" 2>/dev/null || echo missing)"
if [ "$st" = missing ]; then
    log "✗ 容器 $EDGE 不存在,需人工重装(quick-install)"
    # 容器都没了,重启主机也变不出来 —— 不累加,避免无意义的反复重启
elif [ "$st" != running ]; then
    log "容器状态 $st → 启动"; docker start "$EDGE" >/dev/null 2>&1; : > "$STATE"
    bump_anyfail
else
    if ! ip link show utun0 >/dev/null 2>&1; then
        restart_edge "utun0 接口缺失"; : > "$STATE"; bump_anyfail
    elif [ -z "$(ip route show dev utun0 2>/dev/null)" ]; then
        restart_edge "utun0 无 overlay 路由"; : > "$STATE"; bump_anyfail
    else
        cnt="$(cat "$STATE" 2>/dev/null || echo 0)"; [ -z "$cnt" ] && cnt=0
        if tunnel_up; then
            [ "$cnt" -gt 0 ] && log "✓ 隧道已恢复(此前连续判据失败 ${cnt} 轮)"
            a="$(cat "$ANYFAIL" 2>/dev/null || echo 0)"
            [ "${a:-0}" != 0 ] && log "✓ 未确认健康计数归零(此前 ${a} 轮)"
            echo 0 > "$STATE"; echo 0 > "$ANYFAIL"
        else
            cnt=$((cnt + 1)); echo "$cnt" > "$STATE"
            if [ $((cnt % L3_ROUNDS)) -eq 0 ]; then
                restart_edge "隧道判据失败已连续 ${cnt} 轮(约 $(((cnt-1)*5)) 分钟)"
            fi
            bump_anyfail       # L4 的判定统一交给它
        fi
    fi
fi

# ───── RDP(独立于隧道) ─────
# 前置门禁:3390 是否监听由 graphical-session.target 是否存在决定,与钥匙环无关。
#   CLI 模式(systemctl isolate multi-user.target)下 GNOME 会话被拆除,
#   gnome-remote-desktop 打印 "RDP server stopped",3390 必然不监听 —— 这是
#   设计行为,不是故障。
# 2026-09-23 23:44 到 2026-09-25 09:34 的教训:旧版只检查"用户有登录会话",
#   而 CLI 模式下 pts 会话仍在,门禁形同虚设,于是连续误判 1952 次、
#   徒劳重启 gnome-remote-desktop 1952 次、写了 3906 行日志,持续 34 小时。
uid="$(id -u "$GUI_USER" 2>/dev/null)" || exit 0
[ -d "/run/user/$uid" ] || exit 0

gui_session_active() {
    runuser -u "$GUI_USER" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
        systemctl --user -q is-active graphical-session.target 2>/dev/null
}

if ! gui_session_active; then
    # CLI 模式:什么都不做。首次进入时记一行,之后保持静默,避免刷日志。
    if [ ! -f "$RDP_CLI_MARK" ]; then
        : > "$RDP_CLI_MARK"
        log "当前为 CLI 模式(无 graphical-session)→ 3390 不监听属正常,跳过 RDP 检查"
    fi
    exit 0
fi
# 回到 GUI 模式:清掉标记,以便下次进入 CLI 时仍会记录一行。
[ -f "$RDP_CLI_MARK" ] && rm -f "$RDP_CLI_MARK"

act="$(runuser -u "$GUI_USER" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
       systemctl --user is-active gnome-remote-desktop 2>/dev/null)"
port="$(ss -ltn | grep -c ':3390 ')"
if [ "$act" != active ] || [ "$port" -eq 0 ]; then
    log "RDP 异常(GUI 会话在,服务 $act,3390 监听 $port)→ 重启"
    runuser -u "$GUI_USER" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
        systemctl --user restart gnome-remote-desktop >/dev/null 2>&1
    sleep 2; log "重启后 3390 监听数: $(ss -ltn | grep -c ':3390 ')"
fi
exit 0
