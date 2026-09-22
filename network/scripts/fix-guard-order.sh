#!/usr/bin/env bash
# ① 把 guard 调整为启动链的最后一步(避免启动窗口误判装兜底路由)
# ② 给 timer 加 IgnoreOnIsolate,使 cli/gui 的 systemctl isolate 不再把它摘掉
set -Eeuo pipefail
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }
U=/etc/systemd/system/mihomo.service
T=/etc/systemd/system/claude-vpn-guard.timer
ts="$(date +%Y%m%d-%H%M%S)"

echo "[1/4] 调整启动顺序:guard 移到最后"
cp -a "$U" "$U.bak.$ts"
# 先删掉原来的 guard 启动行,再追加到最后一条 ExecStartPost 之后
sed -i '\|^ExecStartPost=/usr/bin/systemctl --no-block start claude-vpn-guard.timer|d' "$U"
sed -i '\|^ExecStartPost=/etc/mihomo/ensure-remote-access.sh|a ExecStartPost=/usr/bin/systemctl --no-block start claude-vpn-guard.timer' "$U"

echo "[2/4] 给 timer 加 IgnoreOnIsolate(cli/gui 切换不再踩掉它)"
cp -a "$T" "$T.bak.$ts"
grep -q "^IgnoreOnIsolate=" "$T" || sed -i '/^\[Unit\]/a IgnoreOnIsolate=true' "$T"

echo "[3/4] daemon-reload"
systemctl daemon-reload

echo "[4/4] 结果"
echo "  --- mihomo.service"
grep -E "^(ExecStartPre|ExecStart=|ExecStartPost|ExecStopPost)" "$U" | sed 's/^/    /'
echo "  --- claude-vpn-guard.timer"
grep -E "^(IgnoreOnIsolate|OnBootSec|OnUnitActiveSec|WantedBy)" "$T" | sed 's/^/    /'
echo
echo "  guard 当前状态: $(systemctl is-active claude-vpn-guard.timer) / 自启 $(systemctl is-enabled claude-vpn-guard.timer 2>&1)"
echo
echo "建议随后整链重启验证一次: sudo netstack restart"
