#!/usr/bin/env bash
# 安装:联网优先的启动顺序 + 重启次数上限。
#
# 解决两个缺陷(2026-10-07 用户指出):
# ① 顺序颠倒:重启后 mihomo 自动起来接管全局路由,但校园网还没认证。
#    认证页被 fake-ip 接管、又没有专属规则(落到 MATCH,Others → Proxy),
#    而代理此刻连不上(没认证就没外网)→ 认证页打不开 → 死锁。
#    正确顺序:先能联网 → 认证 → 才轮到代理。
# ② 重启无上限:只有"两次至少隔 2 小时"的冷却,没有"最多 N 次"。
#    物理链路不通时会每 2 小时重启一次、无限循环,还掩盖真因。
set -Eeuo pipefail
SRC="$(cd -- "$(dirname -- "$0")" && pwd)"
UNITS="$SRC"; [ -f "$UNITS/mihomo.service" ] || UNITS="$SRC/../systemd"
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }
ts="$(date +%Y%m%d-%H%M%S)"

echo "[1/5] 备份"
for f in /etc/mihomo/remote-access-watchdog.sh \
         /etc/mihomo/config.yaml /etc/systemd/system/mihomo.service; do
  [ -f "$f" ] && cp -a "$f" "$f.bak.campus-$ts" && echo "  → $(basename "$f").bak.campus-$ts"
done

echo "[2/5] 部署脚本"
install -m 0755 "$SRC/ensure-campus-net.sh"       /etc/mihomo/ensure-campus-net.sh
install -m 0644 "$SRC/campus-portal-direct.py"    /etc/mihomo/campus-portal-direct.py
install -m 0755 "$SRC/ensure-openvpn3.sh"         /etc/mihomo/ensure-openvpn3.sh
install -m 0755 "$SRC/remote-access-watchdog.sh"  /etc/mihomo/remote-access-watchdog.sh
install -m 0644 "$UNITS/mihomo.service"           /etc/systemd/system/mihomo.service
echo "  ensure-campus-net.sh / campus-portal-direct.py"
echo "  remote-access-watchdog.sh / mihomo.service"

echo "[3/5] 应用认证页直连加固(三层)"
python3 /etc/mihomo/campus-portal-direct.py 2>&1 | sed 's/^/  /'

echo "[4/5] 重载"
systemctl daemon-reload
echo "  启动链顺序:"
grep -E '^ExecStartPre|^ExecStart=|^ExecStartPost' /etc/systemd/system/mihomo.service \
  | nl -ba | sed 's/^/    /'

echo "[5/5] 自检"
echo "  ── 链路状态探测 ──"
/etc/mihomo/ensure-campus-net.sh 2>&1 | sed 's/^/    /'
echo "  ── 认证页加固是否到位 ──"
python3 - <<'PYEOF2'
import yaml
cfg = yaml.safe_load(open('/etc/mihomo/config.yaml'))
rules = [str(r) for r in (cfg.get('rules') or [])]
print("    rules 前 3 条:")
for r in rules[:3]:
    print("      " + r)
f = (cfg.get('dns') or {}).get('fake-ip-filter') or []
print("    fake-ip-filter 含 buaa:", any('buaa' in str(x) for x in f))
ex = (cfg.get('tun') or {}).get('route-exclude-address') or []
print("    tun.route-exclude-address:", ex)
PYEOF2
echo "  ── 重启上限 ──"
grep -E '^MAX_REBOOTS|^COOLDOWN_SEC|^MIN_UPTIME' /etc/mihomo/remote-access-watchdog.sh | sed 's/^/    /'
printf '    当前连续重启计数: %s\n' "$(cat /var/lib/remote-access-watchdog.rebootcount 2>/dev/null || echo 0)"

cat <<'TIP'

-- 之后的行为 --
  开机时(mihomo 的第一个 ExecStartPre):
    链路 online  → 正常走完启动链
    链路 captive → 日志明确提示去认证;应用认证页三层直连加固;
                   不阻断 mihomo 启动
    链路 offline → 日志指出是物理问题,并说明重启无效
  状态写在 /run/campus-net-state,可随时 cat 查看

  watchdog 的 L4 重启现在有四道闸,全过才重启:
    ① 开机不足 15 分钟不重启(防引导循环)
    ② 两次至少隔 2 小时
    ③ 链路必须 online —— captive/offline 时重启无用,直接停手
    ④ 连续 3 次仍不恢复就停手等人工(MAX_REBOOTS)
  隧道恢复健康时,重启计数自动归零

-- 人工介入 --
  认证:浏览器打开 https://gw.buaa.edu.cn/ (三层加固已保证它能打开)
  认证后:sudo systemctl restart mihomo
  清零重启计数:sudo rm -f /var/lib/remote-access-watchdog.rebootcount

-- 回滚 --
  sudo cp -a /etc/mihomo/config.yaml.bak.campus-<时间戳> /etc/mihomo/config.yaml
  sudo cp -a /etc/systemd/system/mihomo.service.bak.campus-<时间戳> /etc/systemd/system/mihomo.service
  sudo systemctl daemon-reload
TIP
