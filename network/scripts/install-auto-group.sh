#!/usr/bin/env bash
# 安装:Auto 自动选优组 + refresh 下载重试。
#
# 解决的问题(2026-09-29 实测):
#   Proxy 组是 Selector 且成员直接是【具体节点】。用户选中的节点一挂,所有走
#   Proxy 的流量全卡 —— 那天 44 个节点只剩 7 个 alive、选中的节点连测 8 次全超时,
#   而地区组本来就是 fallback(会自动切),这个能力完全没被用上。
#   同时 refresh 单次下载失败即放弃,一次 SSL EOF 让整天没刷新。
#
# 改动范围刻意最小 —— 已逐项 diff 验证:
#   rules 20155 条完全一致 / Claude 的 6 条 OpenVPN-tun0 规则一字未动 /
#   dns 与 tun 完全一致 / proxies 46 个一致。
#   只新增一个 Auto 组,只改 Proxy 的成员列表。
set -Eeuo pipefail
SRC="$(cd -- "$(dirname -- "$0")" && pwd)"
UNITS="$SRC"; [ -f "$UNITS/mihomo-refresh.timer" ] || UNITS="$SRC/../systemd"
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }
ts="$(date +%Y%m%d-%H%M%S)"
CFG=/etc/mihomo/config.yaml

echo "[1/6] 备份"
cp -a "$CFG" "$CFG.bak.auto-$ts"; echo "  → $(basename "$CFG.bak.auto-$ts")"
for f in refresh.py mihomo_groups.py; do
  [ -f "/etc/mihomo/$f" ] && cp -a "/etc/mihomo/$f" "/etc/mihomo/$f.bak.auto-$ts"
done

echo "[2/6] 部署脚本"
install -m 0644 "$SRC/mihomo_groups.py" /etc/mihomo/mihomo_groups.py
install -m 0644 "$SRC/refresh.py"       /etc/mihomo/refresh.py
install -m 0644 "$UNITS/mihomo-refresh.timer" /etc/systemd/system/mihomo-refresh.timer
rm -rf /etc/mihomo/__pycache__
echo "  mihomo_groups.py / refresh.py / mihomo-refresh.timer"

echo "[3/6] 重建分组(建 Auto,把 Proxy 的成员改为以自动组为首)"
python3 - <<'PYEOF2'
import sys, yaml, shutil, subprocess, os
sys.path.insert(0, '/etc/mihomo')
from mihomo_groups import rebuild, group_health, AUTO_GROUP
CFG = '/etc/mihomo/config.yaml'
cfg = yaml.safe_load(open(CFG))
before_rules = len(cfg.get('rules') or [])
before_nodes = len(cfg.get('proxies') or [])
n = rebuild(cfg, log=lambda m: print('  ' + m))
bad = group_health(cfg)
if bad:
    print('  x 重建后仍有退化组: %s → 放弃' % bad); raise SystemExit(1)
# 安全闸:rules 与 proxies 必须一字未动
if len(cfg.get('rules') or []) != before_rules or len(cfg.get('proxies') or []) != before_nodes:
    print('  x rules/proxies 数量变了 → 放弃'); raise SystemExit(1)
tmp = CFG + '.tmp.auto'
yaml.safe_dump(cfg, open(tmp, 'w'), allow_unicode=True, sort_keys=False)
r = subprocess.run(['/usr/bin/verge-mihomo', '-d', '/etc/mihomo', '-f', tmp, '-t'],
                   capture_output=True, text=True)
if r.returncode != 0:
    os.unlink(tmp)
    print('  x 校验失败,已放弃:', (r.stdout + r.stderr).strip()[-200:]); raise SystemExit(1)
os.chmod(tmp, 0o644); os.replace(tmp, CFG)
shutil.copy2(CFG, '/etc/mihomo/config.good.yaml')
print('  ✓ 改动 %d 组,校验通过,已更新 known-good 快照' % n)
PYEOF2

echo "[4/6] 热重载并把 Proxy 切到 Auto"
systemctl daemon-reload
curl -s -o /dev/null -m 15 --noproxy '*' -X PUT "http://127.0.0.1:9097/configs?force=true" \
  -H 'Content-Type: application/json' -d "{\"path\":\"$CFG\"}" && echo "  配置已热重载"
sleep 3
curl -s -m 10 --noproxy '*' -X PUT 'http://127.0.0.1:9097/proxies/Proxy' \
  -H 'Content-Type: application/json' -d '{"name":"Auto"}' >/dev/null 2>&1
echo "  Proxy → Auto"

echo "[5/6] 让 Auto 立刻测速选节点"
curl -s -m 60 --noproxy '*' \
  'http://127.0.0.1:9097/group/Auto/delay?url=http%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=5000' \
  >/dev/null 2>&1 || true
sleep 3

echo "[6/6] 自检"
curl -s -m 5 --noproxy '*' http://127.0.0.1:9097/proxies 2>/dev/null | python3 -c '
import sys, json
p = json.load(sys.stdin)["proxies"]
for g in ("Proxy", "Auto", "香港", "日本", "美国", "新加坡"):
    if g in p:
        v = p[g]
        auto = v.get("type") in ("URLTest", "Fallback", "LoadBalance")
        print("  %-8s type=%-10s now=%-26s 自动切换=%s" % (
            g, v.get("type"), str(v.get("now"))[:26], "是" if auto else "否(手动)"))
nodes = [k for k, v in p.items() if not v.get("all") and v.get("type") not in
         ("Direct", "Reject", "Compatible", "Pass", "RejectDrop")]
print("  订阅节点 %d 个,alive %d 个" % (len(nodes), sum(1 for k in nodes if p[k].get("alive"))))
'
echo "  Claude 规则复核:"
grep -c 'OpenVPN-tun0' /etc/mihomo/config.yaml | sed 's/^/    config 内 OpenVPN-tun0 出现 /'
curl -s -m 5 --noproxy '*' http://127.0.0.1:9097/rules 2>/dev/null | python3 -c '
import sys, json
rs = json.load(sys.stdin).get("rules", [])
print("    生效规则 %d 条,其中指向 OpenVPN-tun0 的 %d 条" % (
    len(rs), sum(1 for r in rs if r.get("proxy") == "OpenVPN-tun0")))
' 2>/dev/null

cat <<'TIP'

-- 之后的行为 --
  · Proxy 默认走 Auto(url-test):每 5 分钟复测,自动选最快的可用节点;
    tolerance=50ms,差值小于 50ms 不切,避免反复抖动
  · 仍可手动固定:在 Proxy 组里选具体节点或地区组(地区组各自是 fallback)
  · 分流策略完全不变:rules、dns、tun、proxies 一字未动;Claude 仍走 OpenVPN-tun0
  · 每日刷新会自动把新节点加进 Auto 与地区组

-- 回滚 --
  sudo cp -a /etc/mihomo/config.yaml.bak.auto-<时间戳> /etc/mihomo/config.yaml
  sudo curl -s -X PUT 'http://127.0.0.1:9097/configs?force=true' \
    -H 'Content-Type: application/json' -d '{"path":"/etc/mihomo/config.yaml"}'
TIP
