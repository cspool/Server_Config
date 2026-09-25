#!/usr/bin/env bash
# 禁用 eno2,让全机只依赖 eno1。
#
# 为什么禁用:eno2 接的是校园网(192.168.10.x)。认证过期后上游用自签证书
# 透明劫持 HTTPS —— 任何经它出去的请求都拿到 gw.buaa.edu.cn 的认证跳转页。
# 2026-09-25 的事故正是如此:Beyond edge 拿到 HTML 而非 JSON,报
# confagent.go:87 invalid character '<',隧道建不起来、远程全断,
# 而所有网络层检查都显示"正常",极难定位。
# 该账号当前处于「免费区域」(user_balance 0 / remain_bytes 0),
# 即便重新认证也没有外网额度,故不适合承载任何出网流量。
#
# 做法刻意保守:只设 autoconnect=no 并 down 掉连接,**保留连接配置本身**
# (含 ipv4.route-table 200 与 199/200 策略规则),以便一条命令回切。
set -Eeuo pipefail
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }

CONN="${ENO2_CONN:-}"
if [ -z "$CONN" ]; then
  CONN="$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | awk -F: '$2=="eno2"{print $1; exit}')"
fi
[ -n "$CONN" ] || { echo "未找到 eno2 的 NetworkManager 连接,跳过"; exit 0; }
echo "eno2 的连接名: $CONN"

echo "[1/4] 记录当前状态(便于回切)"
nmcli -t -f connection.id,ipv4.route-table,ipv4.routing-rules connection show "$CONN" 2>/dev/null | sed 's/^/  /'
ip route show dev eno2 2>/dev/null | sed 's/^/  路由: /' || true

echo "[2/4] 关闭开机自动连接"
nmcli connection modify "$CONN" connection.autoconnect no
echo "  autoconnect = $(nmcli -t -f connection.autoconnect connection show "$CONN" | cut -d: -f2)"

echo "[3/4] 断开连接"
nmcli connection down "$CONN" >/dev/null 2>&1 || true
sleep 2

echo "[4/4] 自检"
printf '  eno2 状态        : %s\n' "$(nmcli -t -f DEVICE,STATE device status 2>/dev/null | awk -F: '$1=="eno2"{print $2}')"
printf '  eno2 上的路由    : %s 条\n' "$(ip route show dev eno2 2>/dev/null | wc -l)"
printf '  199/200 策略规则 : %s 条(连接 down 后自动移除)\n' "$(ip rule show 2>/dev/null | grep -cE '^(199|200):' || true)"
printf '  表 200 内容      : %s 条\n' "$(ip route show table 200 2>/dev/null | wc -l)"
printf '  主表默认路由     : %s\n' "$(ip route show default 2>/dev/null | head -1)"
printf '  SSH 监听         : %s\n' "$(ss -ltn 2>/dev/null | grep -c ':22 ') 个"
printf '  utun0 rx/tx      : %s / %s\n' \
  "$(cat /sys/class/net/utun0/statistics/rx_packets 2>/dev/null || echo -)" \
  "$(cat /sys/class/net/utun0/statistics/tx_packets 2>/dev/null || echo -)"
echo "  Beyond /32 路由(应全部 dev eno1):"
[ -r /run/beyond-underlay.routes ] && while read -r r; do
  printf '    %s\n' "$(ip route show "$r" 2>/dev/null)"
done < /run/beyond-underlay.routes

cat <<'TIP'

── 回切 eno2(需要时)──
  sudo nmcli connection modify "<连接名>" connection.autoconnect yes
  sudo nmcli connection up "<连接名>"
  # 若要用校园网,先认证:给门户装一条路由,然后浏览器打开 https://gw.buaa.edu.cn/
  GW=$(dig +short -b 192.168.10.86 @192.168.10.1 gw.buaa.edu.cn A | head -1)
  sudo ip route replace "$GW/32" via 192.168.10.1 dev eno2 onlink
  # mihomo 会把 gw.buaa.edu.cn 判给 Domestic → DIRECT,命中该路由走 eno2
TIP
