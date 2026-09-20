#!/usr/bin/env python3
"""切换 Beyond 隧道底层出口:eno2 绑定 ↔ 默认路由(eno1)。

  toggle-beyond-eno2.py off   移除绑定规则 → edge 回到默认路由(eno1)
  toggle-beyond-eno2.py on    恢复绑定规则 → edge 强制走 eno2
"""
import sys, yaml, subprocess

CFG = "/etc/mihomo/config.yaml"
PROXY = "Direct-eno2"
RULES = [f"PROCESS-NAME,edge,{PROXY}",
         f"DOMAIN-SUFFIX,beyondnetwork.cn,{PROXY}",
         f"DOMAIN-SUFFIX,beyondtunnel.com,{PROXY}"]

mode = sys.argv[1] if len(sys.argv) > 1 else "status"
cfg = yaml.safe_load(open(CFG))
rules = cfg.get("rules") or []
present = [r for r in RULES if r in rules]

if mode == "status":
    print(f"  绑定规则: {len(present)}/3 条 → edge 走 {'eno2' if present else '默认路由(eno1)'}")
    sys.exit(0)

if mode == "off":
    cfg["rules"] = [r for r in rules if r not in RULES]
    print(f"  移除 {len(present)} 条绑定规则 → edge 回到默认路由(eno1)")
elif mode == "on":
    add = [r for r in RULES if r not in rules]
    cfg["rules"] = add + rules
    if not any(p.get("name") == PROXY for p in cfg.get("proxies", [])):
        cfg.setdefault("proxies", []).insert(0, {"name": PROXY, "type": "direct", "interface-name": "eno2"})
    print(f"  加回 {len(add)} 条绑定规则 → edge 强制走 eno2")
else:
    print("用法: toggle-beyond-eno2.py on|off|status"); sys.exit(2)

tmp = CFG + ".toggle"
yaml.safe_dump(cfg, open(tmp, "w"), allow_unicode=True, sort_keys=False)
r = subprocess.run(["/usr/bin/verge-mihomo", "-d", "/etc/mihomo", "-f", tmp, "-t"],
                   capture_output=True, text=True)
if r.returncode != 0:
    print("  ✗ 校验失败,未改动"); subprocess.run(["rm", "-f", tmp]); sys.exit(1)
subprocess.run(["install", "-m", "0644", tmp, CFG], check=True)
subprocess.run(["rm", "-f", tmp])
subprocess.run(["install", "-m", "0644", CFG, "/etc/mihomo/config.good.yaml"])
print("  ✓ 已应用并校验通过")
subprocess.run(["curl", "-s", "-o", "/dev/null", "-X", "PUT",
                "-H", "Content-Type: application/json",
                "-d", '{"path":"/etc/mihomo/config.yaml","force":true}',
                "http://127.0.0.1:9097/configs"])
print("  ✓ 已热重载")
