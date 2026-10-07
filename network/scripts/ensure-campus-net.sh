#!/usr/bin/env bash
# mihomo.service 的第一个 ExecStartPre —— 在起代理之前先确认链路能联网。
#
# 2026-10-07 的问题:重启后 mihomo 自动起来了,但校园网还没认证。此时顺序是颠倒的:
#   代理先接管全局路由 → 认证页被 fake-ip / 规则引向代理 → 而代理此刻连不上
#   (没认证就没有外网)→ 认证页打不开 → 死锁,人在外地完全没法恢复。
# 正确顺序:先能联网 → 认证 → 才轮到代理。
#
# 本脚本【不阻断】mihomo 启动(那样会彻底断网,更糟),只做三件事:
#   ① 探测链路状态,把结论写进日志与 /run 标记,让后续排查一眼看到
#   ② 未认证时把认证页的直连通道准备好(campus-portal-direct.py 的三层加固)
#   ③ 未认证时跳过 openvpn3 的连接尝试 —— 反正连不上,白等 45 秒
#
# 判据:向无劫持的 204 端点发请求。
#   HTTP 204 且响应体为空  → 已联网
#   HTTP 200/302 且含跳转  → 被劫持,需认证
#   连不上                 → 物理链路问题(网线、上游设备)
set -uo pipefail

PROBE_URL="${CAMPUS_PROBE_URL:-http://connectivitycheck.gstatic.com/generate_204}"
PROBE_ALT="${CAMPUS_PROBE_ALT:-http://www.msftconnecttest.com/connecttest.txt}"
PORTAL_HINT="${CAMPUS_PORTAL_HINT:-gw.buaa.edu.cn}"
MARK=/run/campus-net-state          # 供 watchdog 与人工排查读取
PORTAL_FIX=/etc/mihomo/campus-portal-direct.py

log() { printf '[ensure-campus-net] %s\n' "$*"; }

probe() {
    # 回显 "HTTP码 体长度";curl 失败回 "000 0"
    local out
    out="$(curl -s --noproxy '*' -m 8 -o /tmp/.campus-probe.$$ \
           -w '%{http_code}' "$1" 2>/dev/null)" || out=000
    printf '%s %s' "${out:-000}" "$(wc -c < /tmp/.campus-probe.$$ 2>/dev/null || echo 0)"
    rm -f /tmp/.campus-probe.$$
}

hijacked() { grep -qiE 'location\.href|portal|authenticat|'"$PORTAL_HINT" "$1" 2>/dev/null; }

# ── 探测 ──
body=/tmp/.campus-body.$$
code="$(curl -s --noproxy '*' -m 8 -o "$body" -w '%{http_code}' "$PROBE_URL" 2>/dev/null)" || code=000
state=unknown
case "$code" in
    204) state=online ;;
    200|30[1237])
        if hijacked "$body"; then state=captive; else state=online; fi ;;
    000)
        # 换一个端点再确认,避免单点误判
        c2="$(curl -s --noproxy '*' -m 8 -o "$body" -w '%{http_code}' "$PROBE_ALT" 2>/dev/null)" || c2=000
        if [ "$c2" = 200 ] && ! hijacked "$body"; then state=online
        elif [ "$c2" = 000 ]; then state=offline
        else state=captive; fi ;;
    *) state=captive ;;
esac
rm -f "$body"

echo "$state" > "$MARK" 2>/dev/null || true

case "$state" in
    online)
        log "链路已联网(探测 $code)→ 正常启动"
        exit 0 ;;
    captive)
        log "⚠ 链路被劫持,需要认证(探测 $code)"
        log "  这不会阻断 mihomo 启动,但【代理此刻一定不可用】——"
        log "  先打开认证页完成认证:https://$PORTAL_HINT/"
        # 把认证页的直连通道准备好:fake-ip-filter + rules 最前 + TUN 排除内网
        if [ -r "$PORTAL_FIX" ]; then
            log "  应用认证页直连加固:"
            python3 "$PORTAL_FIX" 2>&1 | sed 's/^/    /' || log "  (加固脚本返回非零,继续启动)"
        else
            log "  缺少 $PORTAL_FIX,跳过加固"
        fi
        log "  跳过 openvpn3 连接尝试(未联网时必然失败,白等 45 秒)"
        # 让后续的 ensure-openvpn3.sh 知道可以跳过
        touch /run/campus-skip-openvpn3 2>/dev/null || true
        exit 0 ;;
    offline)
        log "✗ 链路不通(两个探测端点都连不上)—— 很可能是物理问题"
        log "  查:ip -brief link show / ip route show default"
        log "  重启【不会】解决物理链路问题(watchdog 的 MAX_REBOOTS 上限正是为此)"
        exit 0 ;;
    *)
        log "链路状态无法判定(探测 $code),按已联网处理"
        exit 0 ;;
esac
