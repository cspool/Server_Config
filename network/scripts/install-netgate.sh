#!/usr/bin/env bash
# 安装"基础联网门禁"改动(2026-10-07)
#
# 修的三个真实故障:
#  ① ANYFAIL 在链路断开期间照常累加 → 断链 5 小时后计数 59/5,链路一恢复
#     的那一轮立刻重启主机(实测 18:08:26)。改为非 online 时归零,
#     让认证/链路恢复后重新获得完整 L4_ROUNDS 轮自愈窗口。
#  ② restart_edge 在断链期间每 5 分钟徒劳重启一次 edge 容器(实测 60+ 次)。
#  ③ mihomo 被 PUT 成 Clash Verge GUI 的旧配置(51 个失效节点、无 Auto 组),
#     境外断 4 小时而隧道判据全绿。新增节点集合对账,不一致就重载回磁盘配置。
# 注:claude-vpn-guard 已于 2026-10-08 整体撤销(openvpn3 分流取消),
#     本脚本【不再】安装它 —— 仓库保留代码仅作历史参考。
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "需要 root: sudo bash $0"; exit 1; }

SRC="$(cd "$(dirname "$0")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"

install_one() {
    local src="$1" dst="$2"
    [ -r "$src" ] || { echo "✗ 源文件缺失: $src"; exit 1; }
    bash -n "$src" || { echo "✗ 语法检查失败: $src"; exit 1; }
    [ -e "$dst" ] && cp -a "$dst" "${dst}.bak.netgate-${TS}"
    install -m 0755 "$src" "$dst"
    echo "  ✓ $dst  (备份 ${dst}.bak.netgate-${TS})"
}

echo "[1/4] 安装脚本"
install_one "$SRC/remote-access-watchdog.sh" /etc/mihomo/remote-access-watchdog.sh
install_one "$SRC/ensure-campus-net.sh"      /etc/mihomo/ensure-campus-net.sh

echo "[2/4] 清零计数器(上一次的 59 轮是断链造成的,不该带入新逻辑)"
echo 0 > /run/remote-access-watchdog.anyfail
echo 0 > /run/remote-access-watchdog.state
rm -f /run/remote-access-watchdog.reboot-requested
echo 0 > /var/lib/remote-access-watchdog.rebootcount
echo "  ✓ anyfail / state / rebootcount 归零,reboot-requested 标记已清"

echo "[3/4] 重启定时器(用 restart:对已 active 的 timer,start 是空操作)"
systemctl restart remote-access-watchdog.timer
echo "  ✓ 已重启"

echo "[4/4] 立刻跑一轮验证"
systemctl start remote-access-watchdog.service || true
sleep 3
echo "  --- 本轮日志 ---"
journalctl -u remote-access-watchdog.service --since '-40s' --no-pager -o cat | sed 's/^/    /'
echo "  --- /run/campus-net-state ---"
printf '    %s (mtime %s)\n' "$(cat /run/campus-net-state 2>/dev/null)" \
    "$(stat -c %y /run/campus-net-state 2>/dev/null | cut -d. -f1)"
echo
echo "完成。核对:"
echo "  journalctl -t remote-access-watchdog -f"
