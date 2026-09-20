#!/usr/bin/env python3
"""把 Beyond 的域名排除出 fake-ip,让 edge 拿到真实 IP。

否则 edge 解析 api1.beyondnetwork.cn 得到 28.0.0.x 假 IP,拿着假 IP 去连
→ 进 TUN,ensure-beyond-eno2.sh 装的 /32 路由匹配不上,控制面仍被 mihomo 中转。
与当初修 openvpn3 握手(+.<VPN域名>)是同一手法。
"""
import sys, yaml, subprocess

CFG = "/etc/mihomo/config.yaml"
DOMAINS = ["+.beyondnetwork.cn", "+.beyondtunnel.com", "+.ipw.cn"]

cfg = yaml.safe_load(open(CFG))
filt = cfg.setdefault("dns", {}).get("fake-ip-filter") or []
add = [d for d in DOMAINS if d not in filt]
cfg["dns"]["fake-ip-filter"] = add + filt
for d in add: print(f"  加入 fake-ip-filter: {d}")
print(f"  fake-ip-filter 共 {len(cfg['dns']['fake-ip-filter'])} 条")
if not add:
    print("  无需改动"); sys.exit(0)

tmp = CFG + ".fip"
yaml.safe_dump(cfg, open(tmp, "w"), allow_unicode=True, sort_keys=False)
r = subprocess.run(["/usr/bin/verge-mihomo", "-d", "/etc/mihomo", "-f", tmp, "-t"],
                   capture_output=True, text=True)
print("  校验:", (r.stdout + r.stderr).strip().splitlines()[-1])
if r.returncode != 0:
    subprocess.run(["rm", "-f", tmp]); sys.exit(1)
subprocess.run(["install", "-m", "0644", tmp, CFG], check=True)
subprocess.run(["rm", "-f", tmp])
subprocess.run(["install", "-m", "0644", CFG, "/etc/mihomo/config.good.yaml"])
subprocess.run(["curl", "-s", "-o", "/dev/null", "-X", "PUT",
                "-H", "Content-Type: application/json",
                "-d", '{"path":"/etc/mihomo/config.yaml","force":true}',
                "http://127.0.0.1:9097/configs"])
print("  ✓ 已应用并热重载")
