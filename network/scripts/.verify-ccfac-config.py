#!/usr/bin/env python3
"""迁移后的硬性核对:Claude 组有节点、规则在前列、分组不退化。任一不满足即非零退出。"""
import sys, yaml
sys.path.insert(0, "/etc/mihomo")
import mihomo_groups as m

c = yaml.safe_load(open("/etc/mihomo/config.yaml"))
px = [p for p in (c.get("proxies") or []) if p.get("server")]
print("  节点 %d 个" % len(px))

gs = {g["name"]: g for g in (c.get("proxy-groups") or [])}
for n in ("Claude", "Auto", "Proxy"):
    g = gs.get(n)
    print("  %-7s %s" % (n, ("type=%s, %d 个成员" % (g.get("type"), len(g.get("proxies") or [])))
                         if g else "!! 缺失"))
cl = gs.get("Claude", {}).get("proxies") or []
print("  Claude 组成员: %s" % cl)
for n in cl:
    print("    关键词全中=%s 倍率=%sx" % (m.is_claude_node(n), m.node_rate(n)))

bad = m.group_health(c)
print("  健康门禁: %s" % (("!! 退化组 " + str(bad)) if bad else "无退化"))

rules = [str(r) for r in (c.get("rules") or [])]
cr = [r for r in rules[:24] if r.endswith(",Claude")]
print("  前 24 条规则里的 Claude 规则 %d 条:" % len(cr))
for r in cr:
    print("    ", r)

fip = (c.get("dns") or {}).get("fake-ip-filter") or []
doms = m.node_server_domains(c)
miss = [d for d in doms if ("+." + d) not in fip and ("*." + d) not in fip]
print("  节点域名已入 fake-ip-filter: %s" % ("是" if not miss else "缺 %s" % miss))

sys.exit(1 if (bad or not cl or not cr or miss) else 0)
