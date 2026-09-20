#!/usr/bin/env python3
"""让 Beyond 的流量在路由层绕开 mihomo TUN(而非进 TUN 后再 DIRECT)。

为什么:NAT 穿透需要稳定的源端口映射。进 TUN 后 mihomo 会终结并重新发起 UDP,
出站能通(注册/保活)但入站打洞打不进来 —— 表现为 utun0 只有保活、rx/tx 近乎为 0。
tun.route-exclude-address 让这些目标地址不被 TUN 捕获,edge 直接用系统路由出去。
"""
import sys, yaml, subprocess

CFG = "/etc/mihomo/config.yaml"
# Beyond 控制面与数据面节点(从 mihomo 日志中观测到的)
EXCLUDE = [
    "47.94.106.154/32", "8.156.75.62/32",
    "139.196.45.11/32", "42.240.157.83/32",
]

cfg = yaml.safe_load(open(CFG))
tun = cfg.setdefault("tun", {})
cur = tun.get("route-exclude-address") or []
add = [a for a in EXCLUDE if a not in cur]
tun["route-exclude-address"] = cur + add
for a in add: print(f"  排除出 TUN: {a}")
print(f"  route-exclude-address 共 {len(tun['route-exclude-address'])} 条")

tmp = CFG + ".excl"
yaml.safe_dump(cfg, open(tmp, "w"), allow_unicode=True, sort_keys=False)
r = subprocess.run(["/usr/bin/verge-mihomo", "-d", "/etc/mihomo", "-f", tmp, "-t"],
                   capture_output=True, text=True)
print("  校验:", (r.stdout + r.stderr).strip().splitlines()[-1])
if r.returncode != 0:
    subprocess.run(["rm", "-f", tmp]); sys.exit(1)
subprocess.run(["install", "-m", "0644", tmp, CFG], check=True)
subprocess.run(["rm", "-f", tmp])
subprocess.run(["install", "-m", "0644", CFG, "/etc/mihomo/config.good.yaml"])
print("  ✓ 已应用")
