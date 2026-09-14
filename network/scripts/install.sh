#!/usr/bin/env bash
# 安装 headless mihomo 常驻服务 + 每日订阅刷新。须 root 运行: sudo bash install.sh
set -Eeuo pipefail
SRC="$(cd -- "$(dirname -- "$0")" && pwd)"
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }

echo "[1/6] 退出 GUI 拉起的 mihomo 内核(避免抢 TUN/端口)"
pkill -x verge-mihomo 2>/dev/null || true
systemctl stop clash-verge-service 2>/dev/null || true
sleep 1

echo "[2/6] 部署到 /etc/mihomo"
install -d -m 0755 /etc/mihomo /etc/mihomo/providers
install -m 0644 "$SRC/config.yaml"  /etc/mihomo/config.yaml
install -m 0600 "$SRC/sub.url"      /etc/mihomo/sub.url
install -m 0755 "$SRC/refresh.py"   /etc/mihomo/refresh.py
for f in Country.mmdb geoip.dat geosite.dat geoip.metadb; do
  [ -f "$SRC/$f" ] && install -m 0644 "$SRC/$f" "/etc/mihomo/$f"
done

echo "[3/6] 安装 systemd units"
install -m 0644 "$SRC/mihomo.service"          /etc/systemd/system/mihomo.service
install -m 0644 "$SRC/mihomo-refresh.service"  /etc/systemd/system/mihomo-refresh.service
install -m 0644 "$SRC/mihomo-refresh.timer"    /etc/systemd/system/mihomo-refresh.timer
systemctl daemon-reload

echo "[4/6] 启用并启动 mihomo 常驻服务"
systemctl enable --now mihomo.service
sleep 3

echo "[5/6] 启用每日刷新 timer(04:30)"
systemctl enable --now mihomo-refresh.timer

echo "[6/6] 状态"
systemctl --no-pager --lines=3 status mihomo.service | sed -n '1,6p' || true
ip -br link show Mihomo 2>/dev/null || echo "warn: Mihomo TUN 未出现"
ss -ltn | grep -E ':7897|:9097' || echo "warn: 7897/9097 未监听"
echo
echo "完成。请到 Clash Verge GUI 里关闭「开机自启」与「开机启动内核」, 以后不要让 GUI 再拉内核(会与本服务抢 TUN/端口)。"
echo "验证刷新: sudo systemctl start mihomo-refresh.service && journalctl -u mihomo-refresh -n 20 --no-pager"
