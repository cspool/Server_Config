#!/usr/bin/env bash
# 安装通用 mihomo 启动链,不包含 Claude 专属 OpenVPN/guard 路由。
# 须 root 运行: sudo bash install-chain.sh
set -Eeuo pipefail

SRC="$(cd -- "$(dirname -- "$0")" && pwd)"
UNITS="$SRC"
[ -f "$UNITS/mihomo.service" ] || UNITS="$SRC/../systemd"
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }

echo "[1/4] 更新 mihomo.service"
cp -a /etc/systemd/system/mihomo.service \
  "/etc/systemd/system/mihomo.service.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
install -m 0644 "$UNITS/mihomo.service" /etc/systemd/system/mihomo.service

echo "[2/4] 确保旧 Claude 路由守护保持停用"
systemctl disable --now claude-vpn-guard.timer 2>/dev/null || true
systemctl stop claude-vpn-guard.service 2>/dev/null || true
systemctl daemon-reload

echo "[3/4] 重启 mihomo"
systemctl restart mihomo.service

echo "[4/4] 状态"
sleep 3
printf '  mihomo      : %s\n' "$(systemctl is-active mihomo)"
printf '  Mihomo TUN  : %s\n' "$(ip -br link show Mihomo 2>/dev/null | awk '{print $1" "$2}' || echo 未出现)"
printf '  Claude 路由 : %s\n' "$(grep -Eic 'OpenVPN-tun0|PROCESS-PATH-REGEX,.*claude' /etc/mihomo/config.yaml || true) 条(应为 0)"
