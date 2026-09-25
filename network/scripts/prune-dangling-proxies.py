#!/usr/bin/env python3
"""剔除 proxy-groups 中指向不存在节点的悬空引用。

订阅更新后节点可能改名或下线,而 proxy-groups 按名字引用 ——
悬空引用会让 mihomo 整份配置解析失败。本脚本只删引用,不动其他内容。

  prune-dangling-proxies.py <输入配置> [输出配置]     省略输出则原地修改
退出码: 0=有改动或无需改动, 2=读取/解析失败
"""
import sys, os, yaml
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mihomo_groups import rebuild

BUILTIN = {"DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE", "GLOBAL"}

def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "/etc/mihomo/config.yaml"
    dst = sys.argv[2] if len(sys.argv) > 2 else src
    try:
        cfg = yaml.safe_load(open(src))
    except Exception as e:
        print(f"[prune] 读取失败: {e}", file=sys.stderr); return 2

    names  = {p["name"] for p in (cfg.get("proxies") or [])}
    groups = cfg.get("proxy-groups") or []
    valid  = names | {g["name"] for g in groups} | BUILTIN

    removed, emptied = [], []
    for g in groups:
        ps = g.get("proxies")
        if not ps:
            continue
        keep = [p for p in ps if p in valid]
        drop = [p for p in ps if p not in valid]
        if drop:
            removed += [(g["name"], d) for d in drop]
            # 组不能为空,否则同样解析失败
            g["proxies"] = keep if keep else ["DIRECT"]
            if not keep:
                emptied.append(g["name"])

    # rules 也可能直接引用节点名,订阅换节点后同样悬空
    rules, kept = cfg.get("rules") or [], []
    for r in rules:
        parts = [x.strip() for x in str(r).split(",")]
        t = parts[-1] if parts else ""
        if t in ("no-resolve", "src") and len(parts) > 2:
            t = parts[-2]
        if parts and t and t not in valid and parts[0] != "MATCH":
            removed.append(("<rules>", f"{t} :: {str(r)[:50]}"))
            continue
        kept.append(r)
    if len(kept) != len(rules):
        cfg["rules"] = kept

    # 剔除只做减法,组会退化成只剩 DIRECT。这里补一次按地区正则的重建,
    # 把仍然存在的节点填回聚合型组(不依赖固定节点名)。
    rebuilt = rebuild(cfg, log=lambda m: print("[prune]" + m))
    if rebuilt:
        print(f"[prune] 重建分组 {rebuilt} 个")

    if not removed and not rebuilt:
        print("[prune] 无悬空引用,分组也无需重建"); return 0

    for gn, d in removed:
        print(f"[prune] 移除 [{gn}] ← {d}")
    if emptied:
        print(f"[prune] 这些组被清空,已填 DIRECT 占位: {emptied}")
    with open(dst, "w") as f:
        yaml.safe_dump(cfg, f, allow_unicode=True, sort_keys=False)
    print(f"[prune] 已写出 {dst}({len(removed)} 处引用)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
