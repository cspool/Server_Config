#!/usr/bin/env bash
# 让 Beyond(edge)的底层流量从 eno2 直出,完全绕开 eno1 上的 mihomo TUN。
#
# 为什么不能用 mihomo 的 Direct-eno2 规则:那只是"进 TUN 后出站绑 eno2",
# 源地址仍是 28.0.0.1,mihomo 会终结并重发 UDP → NAT 映射不稳定 → 打洞进不来。
# 这里改在路由层解决:给 Beyond 节点加 /32 明细路由指向 eno2。
# mihomo 的规则 9002(lookup 2022 suppress_prefixlength 0)会跳过 TUN 默认路由,
# 9003(lookup main suppress_prefixlength 0)命中这些 /32 → 直接走 eno2,不进 TUN。
set -uo pipefail

IFACE=eno2
GW=192.168.10.1
DNS=223.5.5.5                      # 公共 DNS
SRCIP=192.168.10.86                # 绑此源地址查询,绕开 mihomo 的 dns-hijack
DOMAINS="api1.beyondnetwork.cn"
# 从 mihomo 日志观测到的控制面/数据面节点
STATIC="47.94.106.154 8.156.75.62 139.196.45.11 42.240.157.83"
MARK=/run/beyond-eno2.routes       # 记录本次装的路由,便于清理

log() { printf '[ensure-beyond-eno2] %s\n' "$*"; }

ip link show "$IFACE" >/dev/null 2>&1 || { log "网卡 $IFACE 不存在,跳过"; exit 0; }
ip route get "$GW" >/dev/null 2>&1 || true

# 1. 收集目标 IP:静态列表 + 域名实时解析(用公共 DNS,避开 fake-ip)
ips="$STATIC"
for d in $DOMAINS; do
    # 必须绑定 eno2 源地址查询,否则会被 mihomo 的 dns-hijack 截走拿到 fake-ip
    r=$(timeout 5 dig +short +time=2 -b "$SRCIP" "@$DNS" "$d" A 2>/dev/null \
        | grep -E '^[0-9.]+$' | grep -vE '^28\.' || true)
    [ -n "$r" ] && ips="$ips $r"
done
ips=$(printf '%s\n' $ips | grep -vE '^28\.' | sort -u)   # 再兜一层,绝不装 fake-ip
log "目标节点: $(echo $ips | tr '\n' ' ')"

# 2. 清掉上次装的(节点会变)
if [ -r "$MARK" ]; then
    while read -r old; do [ -n "$old" ] && ip route del "$old" 2>/dev/null; done < "$MARK"
fi
: > "$MARK"

# 3. 装 /32 明细路由 → eno2
n=0
for ip in $ips; do
    # onlink:eno2 的直连路由在表 200,主表里 $GW 被判不可达,需显式声明同链路
    if ip route replace "$ip/32" via "$GW" dev "$IFACE" onlink 2>/dev/null; then
        echo "$ip/32" >> "$MARK"; n=$((n+1))
    else
        log "警告: 无法为 $ip 装路由"
    fi
done
log "已装 $n 条 /32 路由 → $IFACE"

# 4. 验证:这些目标应直接走 eno2,而非 dev Mihomo
for ip in $ips; do
    out=$(ip route get "$ip" 2>/dev/null | head -1)
    case "$out" in
        *"dev $IFACE"*) log "✓ $ip → $IFACE" ;;
        *Mihomo*)       log "✗ $ip 仍被 TUN 捕获: $out" ;;
        *)              log "? $ip → $out" ;;
    esac
done
exit 0
