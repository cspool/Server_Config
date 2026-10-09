#!/usr/bin/env bash
# 修复两个 bug:
#   1) mihomo 的 fake-ip + TUN 吞掉 openvpn3 握手 -> 放行其底层流量
#   2) guard 仍指向 GUI 旧配置, 会把 mihomo 热重载到错误的配置文件 -> 改指 /etc/mihomo
# 须 root:  sudo bash install-policy-fix.sh
set -Eeuo pipefail
SRC="$(cd -- "$(dirname -- "$0")" && pwd)"
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }
G=/usr/local/sbin/claude-vpn-guard.sh
stamp="$(date +%Y%m%d-%H%M%S)"

echo "[1/5] 放行 openvpn3 底层流量(fake-ip-filter + DIRECT 规则)"
python3 "$SRC/fix-policy.py"

echo "[2/5] 让 guard 指向 /etc/mihomo(原先指向 GUI 的 clash-verge.yaml)"
cp -a "$G" "$G.bak.$stamp"
sed -i \
  -e 's|^CLASH_DIR=.*|CLASH_DIR=/etc/mihomo|' \
  -e 's|^CLASH_CFG=.*|CLASH_CFG="$CLASH_DIR/config.yaml"|' \
  -e 's|^SCRIPT_JS=.*|SCRIPT_JS="$CLASH_DIR/Script.js"|' \
  "$G"
bash -n "$G" && echo "  guard 语法 OK"
grep -E "^CLASH_DIR=|^CLASH_CFG=|^SCRIPT_JS=" "$G" | sed 's/^/  /'

echo "[3/5] 安装 CLI 重置命令 /usr/local/sbin/net-reset.sh"
install -m 0755 "$SRC/net-reset.sh" /usr/local/sbin/net-reset.sh

echo "[4/5] 重启 mihomo(走完整启动链)"
systemctl restart mihomo.service
sleep 5

echo "[5/5] 验证"
printf '  openvpn3 会话数 : %s (应为 1)\n' "$(runuser -u descfly -- openvpn3 sessions-list 2>/dev/null | grep -c '^ *Path:')"
printf '  openvpn3 tun    : %s\n' "$(ip -o -4 addr show | awk '$4 ~ /^198\.18\./ {print $2" "$4; exit}')"
printf '  VPN 域名解析    : %s (不应是 28.0.0.x)\n' "$(getent hosts ${VPN_DOMAIN:-your-vpn.example.com} | awk '{print $1}')"
printf '  mihomo          : %s\n' "$(systemctl is-active mihomo)"
printf '  guard.timer     : %s\n' "$(systemctl is-active claude-vpn-guard.timer)"
printf '  Mihomo TUN      : %s\n' "$(ip -br link show Mihomo 2>/dev/null | awk '{print $1" "$2}')"
echo
echo "观察 30 秒 guard 是否还在误判:  journalctl -t claude-vpn-guard -f"
