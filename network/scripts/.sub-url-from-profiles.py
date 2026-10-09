#!/usr/bin/env python3
"""从 Clash Verge 的 profiles.yaml 里按订阅名取 url。只打印 url 本身。"""
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1]))
except Exception as e:
    sys.exit("读 profiles.yaml 失败: %s" % e)
for it in (d.get("items") or []):
    if it.get("name") == sys.argv[2] and it.get("url"):
        print(it["url"])
        break
else:
    sys.exit("profiles.yaml 里找不到 name=%s 且带 url 的条目" % sys.argv[2])
