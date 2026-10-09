#!/usr/bin/env bash
# 让 Beyond overlay 段绕开 mihomo TUN(2026-10-09)
#
# 要解决的故障:内网其他设备都能被穿透访问,偏偏本机不通。
#
# 原因:mihomo 的 auto-route 在 table 2022 里装了 64.0.0.0/2 dev Mihomo,
# 而 Beyond 的 overlay 100.64.0.0/16(CGNAT 段)正好落在里面,优先级高于
# 主表的 100.64.0.0/16 dev utun0。实测:
#     ip route get 100.64.0.1  →  dev Mihomo table 2022 src 28.0.0.1
# 于是远端能到达本机,但【回包的目的地 100.64.x 被 mihomo 吃掉】,
# mihomo 拿着一个 CGNAT 地址去找代理,必然失败 —— 单向可达,等于不通。
# 其他内网设备没跑 mihomo,所以它们正常。
#
# 三道一起上(任一单独都不够):
#   ① ip rule priority 8998  "to 100.64.0.0/16 lookup main"  —— 运行期立刻生效
#   ② tun.route-exclude-address += 100.64.0.0/16              —— mihomo 不再接管
#   ③ 前置规则 IP-CIDR,100.64.0.0/16,DIRECT,no-resolve        —— 万一进了 TUN 也直连
# ① 由 ensure-beyond-underlay.sh 在每次启动链里重装;②③ 由每日 refresh 重放。
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "需要 root: sudo bash $0"; exit 1; }

SRC="$(cd "$(dirname "$0")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()  { printf '  OK  %s\n' "$*"; }
no()  { printf '  !!  %s\n' "$*"; }

inst() {
  local s="$1" d="$2"
  case "$s" in
    *.sh) bash -n "$s" || { no "语法失败 $s"; exit 1; } ;;
    *.py) python3 -c 'import ast,sys;ast.parse(open(sys.argv[1]).read())' "$s" || { no "语法失败 $s"; exit 1; } ;;
  esac
  [ -e "$d" ] && cp -a "$d" "${d}.bak.overlay-${TS}"
  install -m 0755 "$s" "$d"; ok "$d"
}

say "[1/5] 安装脚本"
inst "$SRC/ensure-beyond-underlay.sh"   /etc/mihomo/ensure-beyond-underlay.sh
inst "$SRC/mihomo_groups.py"            /etc/mihomo/mihomo_groups.py
inst "$SRC/refresh.py"                  /etc/mihomo/refresh.py
inst "$SRC/remote-access-watchdog.sh"   /etc/mihomo/remote-access-watchdog.sh
inst "$SRC/ensure-config.sh"            /etc/mihomo/ensure-config.sh
rm -rf /etc/mihomo/__pycache__; ok "已清 __pycache__"

say "[2/5] 立刻装运行期 ip rule(不等重启)"
while ip rule del priority 8998 2>/dev/null; do :; done
if ip rule add to 100.64.0.0/16 lookup main priority 8998 2>/dev/null; then
  ok "ip rule 8998 已装"
else
  no "ip rule 安装失败"
fi
printf '  ip route get 100.64.0.1 → %s\n' "$(ip route get 100.64.0.1 2>/dev/null | head -1)"

say "[3/5] 改配置:tun 排除 + 前置直连规则,校验后热重载"
python3 - <<'PYEOF'
import sys, shutil, datetime, subprocess, yaml
sys.path.insert(0, '/etc/mihomo')
import mihomo_groups as m

CFG = '/etc/mihomo/config.yaml'
cfg = yaml.safe_load(open(CFG))
n = m.ensure_overlay_bypass(cfg, log=lambda s: print(" ", s))
if n == 0:
    print("  OK  配置本就包含 overlay 绕过,无需改动")
    sys.exit(0)

tmp = CFG + '.overlay.tmp'
yaml.safe_dump(cfg, open(tmp, 'w'), allow_unicode=True, sort_keys=False)
r = subprocess.run(['/usr/bin/verge-mihomo', '-d', '/etc/mihomo', '-f', tmp, '-t'],
                   capture_output=True, text=True)
if r.returncode != 0:
    print("  !!  新配置校验失败,保留原配置:")
    print((r.stdout + r.stderr).strip()[-400:])
    sys.exit(1)
print("  OK  新配置校验通过")
shutil.copy2(CFG, CFG + '.bak.overlay-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
shutil.move(tmp, CFG)
subprocess.run(['chmod', '0644', CFG])
shutil.copy2(CFG, '/etc/mihomo/config.good.yaml')
print("  OK  已落地并更新 known-good 快照")
PYEOF
[ $? -eq 0 ] || { no "配置步骤失败,停止"; exit 1; }

curl -s -o /dev/null -m 15 --noproxy '*' -X PUT -H 'Content-Type: application/json' \
  -d '{"path":"/etc/mihomo/config.yaml","force":true}' \
  'http://127.0.0.1:9097/configs?force=true' && ok "mihomo 已热重载" || no "热重载失败"
sleep 3

say "[4/5] 让启动链把 8998 规则固化(重跑一次 underlay 脚本)"
/etc/mihomo/ensure-beyond-underlay.sh 2>&1 | sed 's/^/  /'

say "[5/5] 重启 watchdog 定时器(edge 日志轮转判据已修)"
systemctl restart remote-access-watchdog.timer && ok "已重启"

say "=============== 自检 ==============="
printf '  ip rule 8998        : %s\n' "$(ip rule show | grep -c 'priority 8998\|^8998:')"
printf '  route get 100.64.0.1: %s\n' "$(ip route get 100.64.0.1 2>/dev/null | head -1)"
printf '  route get 100.64.5.5: %s\n' "$(ip route get 100.64.5.5 2>/dev/null | head -1)"
printf '  tun 排除段          : %s\n' "$(python3 -c "import yaml;print((yaml.safe_load(open('/etc/mihomo/config.yaml')).get('tun') or {}).get('route-exclude-address'))")"
printf '  overlay 直连规则    : %s\n' "$(grep -c 'IP-CIDR,100.64.0.0/16,DIRECT' /etc/mihomo/config.yaml)"
echo "  --- 三层持久化核对 ---"
printf '  (1) underlay 调用在第 %s 行,第一个 exit 在第 %s 行(前者必须更小)\n' \
  "$(grep -n '^install_overlay_bypass$' /etc/mihomo/ensure-beyond-underlay.sh | cut -d: -f1)" \
  "$(grep -nE '^[[:space:]]*exit ' /etc/mihomo/ensure-beyond-underlay.sh | head -1 | cut -d: -f1)"
printf '  (2) watchdog 每轮巡检    : %s 处调用\n' "$(grep -c '^ensure_overlay_bypass_rule$' /etc/mihomo/remote-access-watchdog.sh)"
printf '  (3) ensure-config 补写   : %s 处引用\n' "$(grep -c 'ensure_overlay_bypass' /etc/mihomo/ensure-config.sh)"
printf '  edge UDP 3005       : %s 条\n' "$(docker exec beyondnetwork_edge sh -c 'ss -unap 2>/dev/null' 2>/dev/null | grep -c ':3005')"
printf '  edge TCP 30004      : %s 条\n' "$(docker exec beyondnetwork_edge sh -c 'ss -tnap 2>/dev/null' 2>/dev/null | grep -c 'ESTAB.*:30004')"
printf '  utun0 rx/tx         : %s / %s 包\n' "$(cat /sys/class/net/utun0/statistics/rx_packets)" "$(cat /sys/class/net/utun0/statistics/tx_packets)"
echo
echo "现在从远端(装了 Beyond 客户端的机器)试 SSH 到本机的 overlay 地址。"
echo "overlay 地址本机读不出来(edge 只开了 pprof),请在 Beyond 控制台/客户端查看这台设备的地址。"
echo
echo "回滚:/etc/mihomo/*.bak.overlay-${TS}、config.yaml.bak.overlay-*;"
echo "     临时去掉运行期规则:sudo ip rule del priority 8998"
