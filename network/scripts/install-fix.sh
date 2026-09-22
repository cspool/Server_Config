#!/usr/bin/env bash
# 安装:订阅刷新 bug 修复 + 启动配置自愈 + 隧道/RDP 末步重启 + 整链控制命令
set -Eeuo pipefail
SRC="$(cd -- "$(dirname -- "$0")" && pwd)"
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }
ts="$(date +%Y%m%d-%H%M%S)"
U=/etc/systemd/system/mihomo.service

echo "[1/7] 部署脚本到 /etc/mihomo"
install -m 0755 "$SRC/prune-dangling-proxies.py" /etc/mihomo/prune-dangling-proxies.py
install -m 0755 "$SRC/ensure-config.sh"          /etc/mihomo/ensure-config.sh
install -m 0755 "$SRC/ensure-remote-access.sh"   /etc/mihomo/ensure-remote-access.sh

echo "[2/7] 替换 refresh.py(剔除悬空引用 + 校验 + 回滚)"
cp -a /etc/mihomo/refresh.py "/etc/mihomo/refresh.py.bak.$ts" 2>/dev/null || true
install -m 0755 "$SRC/refresh.py" /etc/mihomo/refresh.py

echo "[3/7] 建立 known-good 快照"
if /usr/bin/verge-mihomo -d /etc/mihomo -f /etc/mihomo/config.yaml -t >/dev/null 2>&1; then
  install -m 0644 /etc/mihomo/config.yaml /etc/mihomo/config.good.yaml; echo "  已建立"
else
  echo "  ⚠ 当前配置校验失败,跳过"
fi

echo "[4/7] 改造 mihomo.service"
cp -a "$U" "$U.bak.$ts"
grep -q "ensure-config.sh" "$U" || sed -i \
  '\|^ExecStartPre=/etc/mihomo/ensure-openvpn3.sh|a ExecStartPre=/etc/mihomo/ensure-config.sh' "$U"
grep -q "ensure-remote-access.sh" "$U" || sed -i \
  '\|^ExecStartPost=.*claude-vpn-guard.timer|a ExecStartPost=/etc/mihomo/ensure-remote-access.sh' "$U"
# 末步含最长 45s 等待,放宽启动超时
sed -i 's|^TimeoutStartSec=.*|TimeoutStartSec=240|' "$U"
grep -q "^TimeoutStartSec=" "$U" || sed -i '\|^Restart=|i TimeoutStartSec=240' "$U"
systemctl daemon-reload
echo "  已更新并 daemon-reload"

echo "[5/7] 安装整链控制命令 netstack"
install -m 0755 "$SRC/netstack" /usr/local/sbin/netstack

echo "[6/7] 配置校验"
/usr/bin/verge-mihomo -d /etc/mihomo -f /etc/mihomo/config.yaml -t 2>&1 | tail -1 | sed 's/^/  /'

echo "[7/7] 单元最终形态"
grep -E "^(ExecStartPre|ExecStart=|ExecStartPost|ExecStopPost|TimeoutStartSec|Restart)" "$U" | sed 's/^/  /'
echo
echo "完成。建议立刻整链重启验证一次:"
echo "  sudo netstack restart"
echo "  netstack status"
