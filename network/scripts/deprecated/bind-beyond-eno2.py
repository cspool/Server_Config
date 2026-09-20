#!/usr/bin/env python3
"""把 Beyond 隧道的底层流量绑到 eno2,与 openvpn3/clash 的 eno1 出口隔离。

做法与既有的 OpenVPN-tun0 一致:建一个 type=direct + interface-name 的伪出口,
再用最前置的规则把 edge 进程与 beyondnetwork 域名指过去。

  bind-beyond-eno2.py <输入配置> [输出配置]
"""
import sys, yaml

IFACE   = "eno2"
PROXY   = "Direct-eno2"
RULES = [
    f"PROCESS-NAME,edge,{PROXY}",
    f"DOMAIN-SUFFIX,beyondnetwork.cn,{PROXY}",
    f"DOMAIN-SUFFIX,beyondtunnel.com,{PROXY}",
]

def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "/etc/mihomo/config.yaml"
    dst = sys.argv[2] if len(sys.argv) > 2 else src
    cfg = yaml.safe_load(open(src))

    # 1. 伪出口:直连但绑定 eno2
    proxies = cfg.setdefault("proxies", [])
    if not any(p.get("name") == PROXY for p in proxies):
        proxies.insert(0, {"name": PROXY, "type": "direct", "interface-name": IFACE})
        print(f"  新增出口 {PROXY} (type=direct, interface-name={IFACE})")
    else:
        print(f"  出口 {PROXY} 已存在")

    # 2. 最前置规则
    rules = cfg.setdefault("rules", [])
    add = [r for r in RULES if r not in rules]
    if add:
        cfg["rules"] = add + rules
        for r in add: print(f"  新增规则 {r}")
    else:
        print("  规则已存在")

    yaml.safe_dump(cfg, open(dst, "w"), allow_unicode=True, sort_keys=False)
    print(f"  已写出 {dst}")

if __name__ == "__main__":
    main()
