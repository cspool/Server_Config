#!/usr/bin/env bash
# 收尾:① 恢复 mihomo 开机自启  ② 安装增强版 net-reset.sh(含 DNS 缓存清理与规则撤销)
set -Eeuo pipefail
SRC="$(cd -- "$(dirname -- "$0")" && pwd)"
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }

echo "[1/3] 恢复 mihomo 开机自启"
systemctl enable mihomo.service 2>&1 | tail -1

echo "[2/3] 安装增强版 net-reset.sh"
cp -a /usr/local/sbin/net-reset.sh "/usr/local/sbin/net-reset.sh.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
install -m 0755 "$SRC/net-reset.sh" /usr/local/sbin/net-reset.sh
echo "  已更新: 新增 A4-A9(删 Mihomo 网卡/清 9000-9010 与 50 规则/清空 table 2022 与 100/刷 DNS 缓存)"
echo "         并新增阶段 B 裸机验证(DNS 必须返回真实 IP 才继续)"

echo "[3/3] 最终状态"
printf '  mihomo.service        : %s / %s\n' "$(systemctl is-active mihomo)"  "$(systemctl is-enabled mihomo)"
printf '  mihomo-refresh.timer  : %s / %s\n' "$(systemctl is-active mihomo-refresh.timer)" "$(systemctl is-enabled mihomo-refresh.timer)"
printf '  claude-vpn-guard.timer: %s / %s (自启应为 disabled)\n' "$(systemctl is-active claude-vpn-guard.timer)" "$(systemctl is-enabled claude-vpn-guard.timer 2>&1)"
printf '  clash-verge-service   : %s (应 disabled)\n' "$(systemctl is-enabled clash-verge-service 2>&1)"
printf '  openvpn3 tun          : %s\n' "$(ip -o -4 addr show | awk '$4 ~ /^198\.18\./ {print $2" "$4; exit}')"
printf '  VPN 域名解析          : %s\n' "$(getent hosts ${VPN_DOMAIN:-your-vpn.example.com} 2>/dev/null | awk '{print $1}' | head -1)"
printf '  配置接口名            : %s (应与实际 tun 一致)\n' "$(grep -A3 'name: OpenVPN-tun0' /etc/mihomo/config.yaml | grep -oE 'tun[0-9]+')"
