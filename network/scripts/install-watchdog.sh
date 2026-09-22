#!/usr/bin/env bash
# 安装:运行期隧道/RDP 守护 + 开启日志持久化
set -Eeuo pipefail
SRC="$(cd -- "$(dirname -- "$0")" && pwd)"
# unit 文件在仓库里位于 ../systemd,在扁平目录里与脚本同级
UNITS="$SRC"; [ -f "$UNITS/remote-access-watchdog.timer" ] || UNITS="$SRC/../systemd"
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }

echo "[1/5] 开启 systemd 日志持久化(否则重启后现场全丢)"
if [ ! -d /var/log/journal ]; then
  mkdir -p /var/log/journal && systemd-tmpfiles --create --prefix /var/log/journal
  echo "  已创建 /var/log/journal"
else
  echo "  已存在"
fi
sed -i 's|^#\?Storage=.*|Storage=persistent|' /etc/systemd/journald.conf
grep -q '^SystemMaxUse=' /etc/systemd/journald.conf || sed -i '/^\[Journal\]/a SystemMaxUse=500M' /etc/systemd/journald.conf
systemctl restart systemd-journald
echo "  Storage=$(grep -E '^Storage=' /etc/systemd/journald.conf)  上限=$(grep -E '^SystemMaxUse=' /etc/systemd/journald.conf)"

echo "[2/5] 部署 watchdog"
install -m 0755 "$SRC/remote-access-watchdog.sh" /etc/mihomo/remote-access-watchdog.sh
install -m 0644 "$UNITS/remote-access-watchdog.service" /etc/systemd/system/
install -m 0644 "$UNITS/remote-access-watchdog.timer"   /etc/systemd/system/

echo "[3/5] 设为开机自启的独立系统服务(不依赖 mihomo)"
systemctl daemon-reload
systemctl enable remote-access-watchdog.timer 2>&1 | tail -1
printf "  → WantedBy=timers.target;开机 %s 后首次运行,此后每 %s 一次\n" \
  "$(sed -n "s/^OnBootSec=//p" /etc/systemd/system/remote-access-watchdog.timer)" \
  "$(sed -n "s/^OnUnitActiveSec=//p" /etc/systemd/system/remote-access-watchdog.timer)"
echo "  → IgnoreOnIsolate=true,cli/gui 切换不会踩掉"

echo "[4/5] 立即启动并跑一次"
systemctl restart remote-access-watchdog.timer   # restart 而非 start:timer 已 active 时 start 是空操作,新间隔不会生效
systemctl start remote-access-watchdog.service
sleep 2

echo "[5/5] 状态"
echo "  开机自启单元:"; systemctl list-unit-files --state=enabled --no-legend 2>/dev/null | grep -E "mihomo|watchdog|obsidian" | awk '{printf "    %-34s %s\n", $1, $2}'
printf '  watchdog.timer: %s / 自启 %s  下次 %s\n' "$(systemctl is-active remote-access-watchdog.timer)" "$(systemctl is-enabled remote-access-watchdog.timer)" "$(systemctl list-timers remote-access-watchdog.timer --no-pager 2>/dev/null | sed -n 2p | awk '{print $1,$2,$3}')"
journalctl -u remote-access-watchdog --since "-2min" --no-pager 2>/dev/null | tail -4 | cut -c1-130 | sed 's/^/  /'
