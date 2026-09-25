#!/usr/bin/env bash
# 安装:Beyond 底层出口参数化(网卡可配),并把系统里所有 eno2 硬编码切到配置驱动。
#
# 2026-09-25 的迁移:eno2(192.168.10.x,校园网)认证过期后上游透明劫持 HTTPS,
# edge 拿到 gw.buaa.edu.cn 的认证跳转 HTML 而非 JSON → confagent.go:87
# invalid character '<' → 永远拿不到节点列表 → 隧道建不起来。改走 eno1。
set -Eeuo pipefail
SRC="$(cd -- "$(dirname -- "$0")" && pwd)"
UNITS="$SRC"; [ -f "$UNITS/mihomo.service" ] || UNITS="$SRC/../systemd"
CONFD="$SRC"; [ -f "$CONFD/beyond.conf" ] || CONFD="$SRC/../config"
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }
ts="$(date +%Y%m%d-%H%M%S)"

echo "[1/6] 备份将被改动的文件"
for f in /etc/mihomo/remote-access-watchdog.sh /etc/mihomo/config.yaml \
         /etc/systemd/system/mihomo.service; do
  [ -f "$f" ] && cp -a "$f" "$f.bak.underlay-$ts" && echo "  → $(basename "$f").bak.underlay-$ts"
done

echo "[2/6] 部署参数化脚本与配置"
install -m 0755 "$SRC/ensure-beyond-underlay.sh" /etc/mihomo/ensure-beyond-underlay.sh
if [ -f /etc/mihomo/beyond.conf ]; then
  echo "  /etc/mihomo/beyond.conf 已存在,保留现有设置(BEYOND_IFACE=$(sed -n 's/^BEYOND_IFACE=//p' /etc/mihomo/beyond.conf))"
else
  install -m 0644 "$CONFD/beyond.conf" /etc/mihomo/beyond.conf
  echo "  已写入 /etc/mihomo/beyond.conf"
fi
install -m 0755 "$SRC/remote-access-watchdog.sh" /etc/mihomo/remote-access-watchdog.sh
echo "  watchdog 的节点清单路径已参数化(新路径优先,旧路径兼容)"

echo "[3/6] 更新 mihomo.service 的 ExecStartPost"
if grep -q 'ensure-beyond-eno2.sh' /etc/systemd/system/mihomo.service; then
  sed -i 's|/etc/mihomo/ensure-beyond-eno2.sh|/etc/mihomo/ensure-beyond-underlay.sh|' \
    /etc/systemd/system/mihomo.service
  echo "  ensure-beyond-eno2.sh → ensure-beyond-underlay.sh"
else
  echo "  已是新脚本,无需改动"
fi
grep -n 'ExecStartPost' /etc/systemd/system/mihomo.service | sed 's/^/    /'

echo "[4/6] config.yaml:Direct-eno2 伪出口改为 Direct-eno1"
python3 - <<'PYEOF'
import yaml, shutil, subprocess, os
CFG='/etc/mihomo/config.yaml'
cfg=yaml.safe_load(open(CFG))
changed=False
for p in cfg.get('proxies') or []:
    if p.get('name')=='Direct-eno2':
        p['name']='Direct-eno1'; p['interface-name']='eno1'; changed=True
for g in cfg.get('proxy-groups') or []:
    ps=g.get('proxies') or []
    if 'Direct-eno2' in ps:
        g['proxies']=['Direct-eno1' if x=='Direct-eno2' else x for x in ps]; changed=True
rules=[str(r) for r in (cfg.get('rules') or [])]
if any('Direct-eno2' in r for r in rules):
    cfg['rules']=[r.replace('Direct-eno2','Direct-eno1') if isinstance(r,str) else r
                  for r in cfg['rules']]; changed=True
if not changed:
    print("  无 Direct-eno2,跳过"); raise SystemExit(0)
tmp=CFG+'.tmp.underlay'
yaml.safe_dump(cfg, open(tmp,'w'), allow_unicode=True, sort_keys=False)
r=subprocess.run(['/usr/bin/verge-mihomo','-d','/etc/mihomo','-f',tmp,'-t'],
                 capture_output=True, text=True)
if r.returncode!=0:
    os.unlink(tmp); print("  ✗ 改后校验失败,已放弃:", (r.stdout+r.stderr).strip()[-160:]); raise SystemExit(1)
os.chmod(tmp,0o644); os.replace(tmp,CFG)
shutil.copy2(CFG,'/etc/mihomo/config.good.yaml')
print("  ✓ Direct-eno2 → Direct-eno1(interface-name: eno1),校验通过并更新快照")
PYEOF

echo "[5/6] 重载并立即应用"
systemctl daemon-reload
/etc/mihomo/ensure-beyond-underlay.sh 2>&1 | sed 's/^/  /'
curl -s -o /dev/null -m 10 -X PUT "http://127.0.0.1:9097/configs?force=true" \
  -H 'Content-Type: application/json' -d '{"path":"/etc/mihomo/config.yaml"}' \
  && echo "  mihomo 配置已热重载"

echo "[6/6] 自检"
IF="$(sed -n 's/^BEYOND_IFACE=//p' /etc/mihomo/beyond.conf | tr -d '\"')"
echo "  当前底层出口网卡: ${IF:-未设置}"
echo "  /32 路由:"
[ -r /run/beyond-underlay.routes ] && while read -r r; do
  printf '    %s\n' "$(ip route show "$r" 2>/dev/null)"
done < /run/beyond-underlay.routes
printf '  utun0 rx/tx: %s / %s\n' \
  "$(cat /sys/class/net/utun0/statistics/rx_packets 2>/dev/null || echo -)" \
  "$(cat /sys/class/net/utun0/statistics/tx_packets 2>/dev/null || echo -)"
printf '  edge 控制面日志尾部: %s\n' "$(docker exec beyondnetwork_edge sh -c 'tail -1 /var/log/edge.log' 2>/dev/null || echo 读取失败)"
echo
echo "── 完成。切换网卡只需改 /etc/mihomo/beyond.conf 的 BEYOND_IFACE,然后 ──"
echo "   sudo systemctl restart mihomo    或    sudo /etc/mihomo/ensure-beyond-underlay.sh"
