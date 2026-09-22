#!/usr/bin/env bash
# 安装:Beyond 底层流量从 eno2 直出,绕开 mihomo TUN
set -Eeuo pipefail
SRC="$(cd -- "$(dirname -- "$0")" && pwd)"
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }
U=/etc/systemd/system/mihomo.service
ts="$(date +%Y%m%d-%H%M%S)"

echo "[1/5] 移除之前那套无效的 Direct-eno2 规则(机制不对:仍经 TUN 中转)"
python3 "$SRC/toggle-beyond-eno2.py" off 2>/dev/null || echo "  (已是 off)"

echo "[2/5] 部署 ensure-beyond-eno2.sh"
install -m 0755 "$SRC/ensure-beyond-eno2.sh" /etc/mihomo/ensure-beyond-eno2.sh

echo "[3/5] 接入启动链(排在 ensure-remote-access 之前)"
cp -a "$U" "$U.bak.$ts"
grep -q "ensure-beyond-eno2.sh" "$U" || sed -i \
  '\|^ExecStartPost=/etc/mihomo/ensure-remote-access.sh|i ExecStartPost=/etc/mihomo/ensure-beyond-eno2.sh' "$U"
systemctl daemon-reload
echo "  已插入"

echo "[4/5] 立即执行一次"
/etc/mihomo/ensure-beyond-eno2.sh

echo "[5/5] 重启 edge,让底层会话按新路径重建"
docker restart beyondnetwork_edge >/dev/null 2>&1 && echo "  已重启"
for i in $(seq 20); do ip link show utun0 >/dev/null 2>&1 && break; sleep 1; done
sleep 10
echo
echo "════ 验证 ════"
echo "  edge 流量(应不再出现 28.0.0.1 源地址,即不进 TUN):"
journalctl -u mihomo --since "-1min" --no-pager 2>/dev/null | grep -iE "\(edge\)" | tail -4 \
  | sed -E 's/.*msg="//; s/"$//' | cut -c1-130 | sed 's/^/    /' || echo "    无记录 ← 正是期望(流量不再经 mihomo)"
echo
printf '  utun0: rx=%s tx=%s\n' "$(cat /sys/class/net/utun0/statistics/rx_packets)" "$(cat /sys/class/net/utun0/statistics/tx_packets)"
e2=$(cat /sys/class/net/eno2/statistics/tx_packets); sleep 6
printf '  eno2 出向(6s): +%s 包\n' "$(( $(cat /sys/class/net/eno2/statistics/tx_packets)-e2 ))"
echo
grep -E "^ExecStartPre|^ExecStart=|^ExecStartPost" "$U" | sed 's/^/  /'
