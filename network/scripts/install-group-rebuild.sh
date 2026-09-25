#!/usr/bin/env bash
# 安装:proxy-group 按地区正则自动重建 + known-good 快照健康门禁
#
# 修的是什么:prune 只做减法。机场改名后旧引用被剔除、组被填成 ["DIRECT"]
# 占位,而没有任何环节把新节点填回去 → 组永久退化成只剩 DIRECT,所有走该组
# 的规则静默直连(2026-09-25 github.com 不通);更糟的是 ensure-config.sh
# 只要配置"能解析"就存 known-good 快照,把坏状态固化,连回滚都救不回来。
set -Eeuo pipefail
SRC="$(cd -- "$(dirname -- "$0")" && pwd)"
R=/home/descfly/server_config/network/scripts
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }
ts="$(date +%Y%m%d-%H%M%S)"

echo "[1/4] 备份现有脚本"
for f in refresh.py prune-dangling-proxies.py ensure-config.sh; do
  [ -f "/etc/mihomo/$f" ] && cp -a "/etc/mihomo/$f" "/etc/mihomo/$f.bak.$ts" && echo "  → $f.bak.$ts"
done

echo "[2/4] 部署"
install -m 0644 "$R/mihomo_groups.py"            /etc/mihomo/mihomo_groups.py
install -m 0644 "$R/refresh.py"                  /etc/mihomo/refresh.py
install -m 0644 "$R/prune-dangling-proxies.py"   /etc/mihomo/prune-dangling-proxies.py
install -m 0755 "$R/ensure-config.sh"            /etc/mihomo/ensure-config.sh
rm -rf /etc/mihomo/__pycache__
echo "  mihomo_groups.py / refresh.py / prune-dangling-proxies.py / ensure-config.sh"

echo "[3/4] 自检"
python3 -c "import sys; sys.path.insert(0,'/etc/mihomo'); import mihomo_groups; print('  模块可导入,地区规则 %d 条' % len(mihomo_groups.REGION_PAT))"
bash -n /etc/mihomo/ensure-config.sh && echo "  ensure-config.sh 语法 OK"
python3 - <<'PYEOF'
import sys, yaml
sys.path.insert(0, '/etc/mihomo')
from mihomo_groups import group_health
for f in ('/etc/mihomo/config.yaml', '/etc/mihomo/config.good.yaml'):
    try:
        bad = group_health(yaml.safe_load(open(f)))
        print("  %-24s 退化组: %s" % (f.split('/')[-1], bad if bad else '无 ✓'))
    except Exception as e:
        print("  %-24s 检查失败: %s" % (f.split('/')[-1], e))
PYEOF

echo "[4/4] 干跑 ensure-config.sh(不会改动健康的配置)"
/etc/mihomo/ensure-config.sh 2>&1 | sed 's/^/  /'

echo
echo "── 完成。下次 04:30 刷新会自动重建分组;重启时 ensure-config 也会拦住坏快照。──"
echo "验证刷新逻辑(可选,会真的刷新一次):"
echo "  sudo systemctl start mihomo-refresh.service && journalctl -u mihomo-refresh -n 20 --no-pager"
