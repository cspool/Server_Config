#!/usr/bin/env bash
# 让 Beyond(edge)的底层流量从指定网卡直出,完全绕开 mihomo TUN。
#
# 机制(与网卡无关,这是关键):
#   mihomo 的规则 9002 (lookup 2022 suppress_prefixlength 0) 会跳过表 2022 的
#   default dev Mihomo;9003 (lookup main suppress_prefixlength 0) 接着查【主表的
#   明细路由】。所以在主表给 Beyond 节点装 /32,9003 命中它 → 流量根本不进 TUN。
#
# 已证伪的两种做法(勿再尝试,见 deprecated/README.md):
#   · mihomo 规则指向 type:direct + interface-name  → 仍先进 TUN,源变 28.0.0.1
#   · 只用 tun.route-exclude-address                → 排除后走主表默认路由
#
# 参数化:所有可变项读 /etc/mihomo/beyond.conf,只有 BEYOND_IFACE 是必填,
# 网关 / 源地址 / 是否需要 onlink 都自动推导。切换网卡只改一行。
set -uo pipefail

CONF=${BEYOND_CONF:-/etc/mihomo/beyond.conf}
[ -r "$CONF" ] && . "$CONF"

IFACE=${BEYOND_IFACE:-eno1}
DNS=${BEYOND_DNS:-223.5.5.5}
DOMAINS=${BEYOND_DOMAINS:-api1.beyondnetwork.cn}
STATIC=${BEYOND_STATIC:-}
MARK=${BEYOND_MARK:-/run/beyond-underlay.routes}
COMPAT_MARK=/run/beyond-eno2.routes      # 旧版 watchdog 仍读这个路径

log() { printf '[ensure-beyond-underlay] %s\n' "$*"; }

ip link show "$IFACE" >/dev/null 2>&1 || { log "网卡 $IFACE 不存在,跳过"; exit 0; }

# ── 自动推导源地址 ──
SRCIP=${BEYOND_SRCIP:-}
if [ -z "$SRCIP" ]; then
    SRCIP=$(ip -4 -brief addr show "$IFACE" 2>/dev/null | awk '{print $3}' | cut -d/ -f1 | head -1)
fi
[ -n "$SRCIP" ] || { log "✗ 无法确定 $IFACE 的 IPv4 地址,放弃"; exit 0; }

# ── 自动推导网关:先找该网卡在任意路由表里的 default ──
GW=${BEYOND_GW:-}
if [ -z "$GW" ]; then
    GW=$(ip route show table all 2>/dev/null \
         | awk -v d="dev $IFACE" '/^default via/ && index($0,d){print $3; exit}')
fi
[ -n "$GW" ] || { log "✗ 无法确定 $IFACE 的网关,放弃"; exit 0; }

# ── 自动判断是否需要 onlink ──
# 该网卡的直连网段若不在主表(例如被 NetworkManager 放进独立表),主表会判定
# 网关不可达,ip route replace 会整条失败,必须显式 onlink。
ONLINK=""
if ! ip route show table main 2>/dev/null | grep -q "dev $IFACE .*scope link"; then
    ONLINK="onlink"
fi
log "网卡=$IFACE 源=$SRCIP 网关=$GW ${ONLINK:+(需 onlink)}"

# ── 1. 收集目标 IP ──
# 绑定本网卡源地址查询,绕开 mihomo 的 dns-hijack(否则拿到 fake-ip 28.0.0.x)
ips="$STATIC"
for d in $DOMAINS; do
    r=$(timeout 5 dig +short +time=2 -b "$SRCIP" "@$DNS" "$d" A 2>/dev/null \
        | grep -E '^[0-9.]+$' | grep -vE '^28\.' || true)
    if [ -n "$r" ]; then
        ips="$ips $r"
    else
        log "警告: $d 解析失败(可能上游劫持或 DNS 不可达)"
    fi
done
ips=$(printf '%s\n' $ips | grep -E '^[0-9.]+$' | grep -vE '^28\.' | sort -u)
[ -n "$ips" ] || { log "✗ 没有可用目标 IP,保留现有路由不动"; exit 0; }
log "目标节点: $(echo $ips | tr '\n' ' ')"

# ── 2. 清掉上次装的(节点会变) ──
for m in "$MARK" "$COMPAT_MARK"; do
    [ -r "$m" ] || continue
    while read -r old; do [ -n "$old" ] && ip route del "$old" 2>/dev/null; done < "$m"
done
: > "$MARK"

# ── 3. 装 /32 明细路由 ──
n=0
for ip in $ips; do
    if ip route replace "$ip/32" via "$GW" dev "$IFACE" $ONLINK 2>/dev/null; then
        echo "$ip/32" >> "$MARK"; n=$((n+1))
    else
        log "警告: 无法为 $ip 装路由"
    fi
done
cp -f "$MARK" "$COMPAT_MARK" 2>/dev/null || true
log "已装 $n 条 /32 路由 → $IFACE"

# ── 4. 验证:必须走本网卡,而不是 dev Mihomo ──
bad=0
for ip in $ips; do
    out=$(ip route get "$ip" 2>/dev/null | head -1)
    case "$out" in
        *"dev $IFACE"*) log "✓ $ip → $IFACE" ;;
        *Mihomo*)       log "✗ $ip 仍被 TUN 捕获: $out"; bad=$((bad+1)) ;;
        *)              log "? $ip → $out" ;;
    esac
done
[ "$bad" -gt 0 ] && log "⚠ 有 $bad 个目标仍进 TUN,NAT 打洞会失败"
exit 0
