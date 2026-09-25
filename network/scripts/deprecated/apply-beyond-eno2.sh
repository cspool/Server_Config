#!/usr/bin/env bash
# 把 Beyond 隧道底层流量绑到 eno2(与 openvpn3/clash 的 eno1 出口隔离)
set -Eeuo pipefail
SRC="$(cd -- "$(dirname -- "$0")" && pwd)"
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }
CFG=/etc/mihomo/config.yaml
BIN=/usr/bin/verge-mihomo
ts="$(date +%Y%m%d-%H%M%S)"

echo "[1/6] 备份当前配置"
cp -a "$CFG" "$CFG.bak.$ts"

echo "[2/6] 注入 Direct-eno2 出口与前置规则"
python3 "$SRC/bind-beyond-eno2.py" "$CFG" "$CFG.new"

echo "[3/6] 校验"
if ! "$BIN" -d /etc/mihomo -f "$CFG.new" -t 2>&1 | tail -1; then
  echo "  ✗ 校验失败,放弃"; rm -f "$CFG.new"; exit 1
fi
install -m 0644 "$CFG.new" "$CFG"; rm -f "$CFG.new"
install -m 0644 "$CFG" /etc/mihomo/config.good.yaml
echo "  已应用并更新 known-good 快照"

echo "[4/6] 热重载 mihomo"
curl -s -o /dev/null -w '  HTTP %{http_code}\n' -X PUT \
  -H 'Content-Type: application/json' -d "{\"path\":\"$CFG\",\"force\":true}" \
  http://127.0.0.1:9097/configs
sleep 3

echo "[5/6] 重启 Beyond 隧道(让底层会话按新出口重建)"
docker restart beyondnetwork_edge >/dev/null 2>&1 && echo "  已重启" || echo "  ⚠ 重启失败"
for i in $(seq 20); do ip link show utun0 >/dev/null 2>&1 && break; sleep 1; done

echo "[6/6] 验证出口"
sleep 6
echo "  近期 edge 流量走向:"
journalctl -u mihomo --since "-1min" --no-pager 2>/dev/null \
  | grep -iE "\(edge\)" | tail -5 | sed -E 's/.*msg="//; s/"$//' | cut -c1-140 | sed 's/^/    /' \
  || echo "    (暂无,稍后再看)"
echo
printf '  eno2 出向包数(5s): '
t0=$(cat /sys/class/net/eno2/statistics/tx_packets); sleep 5
echo "$(( $(cat /sys/class/net/eno2/statistics/tx_packets) - t0 ))"
printf '  utun0: %s\n' "$(ip -br link show utun0 2>/dev/null | awk '{print $1" "$2}')"
echo
echo "重启后是否仍生效:"
echo "  · Direct-eno2 是 type=direct,refresh.py 的本地节点保留逻辑会留着它 ✓"
echo "  · 三条规则在 rules 里,refresh 只替换 proxies 段,不动 rules ✓"
echo "  · 配置落盘在 /etc/mihomo/config.yaml,开机由 mihomo.service 加载 ✓"
