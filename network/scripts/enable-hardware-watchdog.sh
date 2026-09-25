#!/usr/bin/env bash
# 启用硬件看门狗 —— 覆盖软件手段完全救不了的那一类故障:内核卡死。
#
# 为什么需要它:remote-access-watchdog 是个 systemd 定时任务。内核一旦卡死,
# 它根本不会被调度,systemctl reboot 也发不出去。此时只有芯片组里的硬件
# 计数器能强制复位 —— systemd 定期给 /dev/watchdog 喂狗,系统卡死喂不上
# → 硬件自动重启。
#
# 本机是 Supermicro X12DAi-N6(Intel 芯片组),对应驱动 iTCO_wdt。
#
# 风险与取舍(必须知道):
#   · 系统只是"很慢"(极重 IO、内存压力)而没真卡死时,仍可能被硬件复位。
#     RuntimeWatchdogSec 取保守值(60s)可降低误触发,但无法完全排除。
#   · 硬件复位是断电级的,不做 sync —— 未落盘数据会丢。这是它作为最后手段的
#     代价;前面还有 systemctl reboot 与 sysrq 两级更温和的手段。
#   · 跑长实验的机器要权衡:一次误复位会打断实验。若不接受,不要启用本项。
set -Eeuo pipefail
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }
ts="$(date +%Y%m%d-%H%M%S)"

MOD="${WDT_MODULE:-iTCO_wdt}"
RUNTIME="${WDT_RUNTIME:-60}"        # 系统卡住超过这么久就复位
REBOOTWD="${WDT_REBOOT:-10min}"     # 关机流程卡住超过这么久就复位

echo "[1/4] 加载看门狗驱动 $MOD"
if [ -e /dev/watchdog ]; then
  echo "  /dev/watchdog 已存在,跳过加载"
else
  modprobe "$MOD" 2>&1 | sed 's/^/  /' || { echo "  x $MOD 加载失败,放弃"; exit 1; }
  sleep 1
  [ -e /dev/watchdog ] || { echo "  x 加载后仍无 /dev/watchdog,放弃"; exit 1; }
fi
for d in /sys/class/watchdog/*/; do
  [ -d "$d" ] || continue
  printf '  %s: identity=%s timeout=%s\n' "$(basename "$d")" \
    "$(cat "$d/identity" 2>/dev/null)" "$(cat "$d/timeout" 2>/dev/null)"
done

echo "[2/4] 开机自动加载"
echo "$MOD" > /etc/modules-load.d/watchdog.conf
echo "  /etc/modules-load.d/watchdog.conf -> $MOD"

echo "[3/4] 让 systemd 接管喂狗"
cp -a /etc/systemd/system.conf "/etc/systemd/system.conf.bak.wdt-$ts"
sed -i "s|^#\\?RuntimeWatchdogSec=.*|RuntimeWatchdogSec=${RUNTIME}|" /etc/systemd/system.conf
sed -i "s|^#\\?RebootWatchdogSec=.*|RebootWatchdogSec=${REBOOTWD}|"   /etc/systemd/system.conf
grep -E '^(RuntimeWatchdogSec|RebootWatchdogSec)=' /etc/systemd/system.conf | sed 's/^/  /'
systemctl daemon-reexec
echo "  已 daemon-reexec(不影响运行中的服务)"

echo "[4/4] 自检"
printf '  /dev/watchdog: %s\n' "$([ -e /dev/watchdog ] && echo 有 || echo 无)"
systemctl show -p RuntimeWatchdogUSec -p RebootWatchdogUSec 2>/dev/null | sed 's/^/  /'

echo
echo "-- 验证(不建议刻意做)--"
echo "  硬件看门狗无法安全测试:唯一验证方式是制造一次真卡死"
echo "  (echo c > /proc/sysrq-trigger 触发 panic),代价是一次非正常重启。"
echo "  它的价值在下一次真死机时自动恢复,不在于现在能演示。"
echo
echo "-- 关闭 --"
echo "  sudo sed -i 's|^RuntimeWatchdogSec=.*|#RuntimeWatchdogSec=off|' /etc/systemd/system.conf"
echo "  sudo rm -f /etc/modules-load.d/watchdog.conf && sudo systemctl daemon-reexec"
