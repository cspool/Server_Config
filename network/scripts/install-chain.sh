#!/usr/bin/env bash
# 安装启动链: openvpn3 会话 → mihomo → guard
# 须 root 运行:  sudo bash install-chain.sh
set -Eeuo pipefail
SRC="$(cd -- "$(dirname -- "$0")" && pwd)"
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }

echo "[1/6] 部署 ExecStartPre 脚本"
install -m 0755 "$SRC/ensure-openvpn3.sh" /etc/mihomo/ensure-openvpn3.sh

echo "[2/6] 更新 mihomo.service"
cp -a /etc/systemd/system/mihomo.service "/etc/systemd/system/mihomo.service.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
install -m 0644 "$SRC/mihomo.service" /etc/systemd/system/mihomo.service
systemctl daemon-reload

echo "[3/6] 取消 guard 开机自启(改由 mihomo 拉起)"
systemctl disable claude-vpn-guard.timer 2>&1 | tail -1 || true

echo "[4/6] 关闭 Clash Verge GUI 辅助服务(会与 mihomo.service 抢 TUN/7897)"
systemctl disable --now clash-verge-service.service 2>&1 | tail -1 || true
pkill -x verge-mihomo 2>/dev/null || true   # 清掉 GUI 可能残留的内核

echo "[5/6] 重启 mihomo(会依次:确保 openvpn3 → 起 mihomo → 拉起 guard)"
systemctl restart mihomo.service

echo "[6/6] 状态"
sleep 3
printf '  openvpn3 tun : %s\n' "$(ip -o -4 addr show | awk '$4 ~ /^198\.18\./ {print $2" "$4; exit}')"
printf '  mihomo       : %s\n' "$(systemctl is-active mihomo)"
printf '  guard.timer  : %s (开机自启: %s)\n' "$(systemctl is-active claude-vpn-guard.timer)" "$(systemctl is-enabled claude-vpn-guard.timer 2>&1)"
printf '  clash-verge  : %s (应为 disabled)\n' "$(systemctl is-enabled clash-verge-service 2>&1)"
printf '  Mihomo TUN   : %s\n' "$(ip -br link show Mihomo 2>/dev/null | awk '{print $1" "$2}' || echo 未出现)"
echo
echo "ExecStartPre 日志: journalctl -u mihomo -n 30 --no-pager | grep ensure-openvpn3"
