#!/usr/bin/env bash
# mihomo.service 的 ExecStartPre。
#
# 为什么需要它:mihomo 的 TUN(auto-route)会接管全局路由,并按规则把 Claude
# 流量分发进 openvpn3 隧道(198.18.0.0/18)。如果 mihomo 起来时隧道还不存在,
# 分流规则就会指向一个不存在的接口。所以先保证 openvpn3 有一个有效会话。
#
# 失败时只告警、不阻断 mihomo 启动 —— 否则一旦 VPN 连不上就会彻底断网。
set -uo pipefail

VPN_USER=descfly
VPN_PROFILE=/home/descfly/Desktop/waimaot-liuzhixiang.ovpn
WAIT_SECS=45

log() { printf '[ensure-openvpn3] %s\n' "$*"; }
ovpn() { runuser -u "$VPN_USER" -- openvpn3 "$@" 2>/dev/null; }
tun_name() { ip -o -4 addr show 2>/dev/null | awk '$4 ~ /^198\.18\./ {print $2; exit}'; }

# 1. 已有有效隧道 → 直接放行
t="$(tun_name)"
if [ -n "$t" ]; then
    log "隧道已就绪: $t"
    exit 0
fi

if [ ! -r "$VPN_PROFILE" ]; then
    log "警告: 找不到配置 $VPN_PROFILE, 跳过(mihomo 仍会启动)"
    exit 0
fi

# 2. 没有可用隧道 → 清掉全部残留会话。
#    openvpn3 每次重连都会销毁并重建设备, 并取当时最小的空闲编号;
#    并存多个会话是 tun 编号乱跳、guard 反复误判的根因, 所以这里强制只留一个。
for p in $(ovpn sessions-list | awk '/^ *Path:/{print $2}'); do
    log "清理残留会话 $p"
    ovpn session-manage --session-path "$p" --disconnect >/dev/null
done
sleep 2

# 3. 启动新会话(.ovpn 内嵌 auth-user-pass, 可非交互)
log "启动 openvpn3 会话: $VPN_PROFILE"
if ! ovpn session-start --config "$VPN_PROFILE" >/dev/null; then
    log "警告: session-start 失败, mihomo 仍会启动; 可手动排查 openvpn3 sessions-list"
    exit 0
fi

# 4. 等待 tun 出现
for i in $(seq "$WAIT_SECS"); do
    t="$(tun_name)"
    if [ -n "$t" ]; then
        log "隧道就绪: $t (耗时 ${i}s)"
        exit 0
    fi
    sleep 1
done

log "警告: ${WAIT_SECS}s 内隧道未就绪, 继续启动 mihomo(guard 会在兜底态保证不断网)"
exit 0
