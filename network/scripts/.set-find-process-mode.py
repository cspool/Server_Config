#!/usr/bin/env python3
"""确保 find-process-mode=always —— PROCESS-PATH-REGEX 规则靠它生效。"""
import yaml
p = "/etc/mihomo/config.yaml"
c = yaml.safe_load(open(p))
if c.get("find-process-mode") != "always":
    c["find-process-mode"] = "always"
    yaml.safe_dump(c, open(p, "w"), allow_unicode=True, sort_keys=False)
    print("  OK  已设为 always")
else:
    print("  OK  已经是 always")
