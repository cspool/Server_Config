#!/usr/bin/env python3
"""按地区正则重建 mihomo 的聚合型 proxy-group 成员。

为什么需要它:剔除悬空引用(prune)只做减法。机场改名后旧引用被剔除、
组被填成 ["DIRECT"] 占位,而没有任何环节把新节点填回去 —— 组会永久退化成
只剩 DIRECT,所有走该组的规则实际在直连。2026-09-25 的 github.com 不通
(而 api.github.com 因走 OpenAI 组反而正常)就是这样来的,且这个状态
从 2026-09-14 起就存在。

设计约束:**不依赖任何固定节点名**。机场随时会改名
(香港 01 - 1倍率 → HK-Premium-01 → 🇭🇰 香港01 都要能命中),
所以只认地名与常见缩写,不认编号、倍率、"Premium" 等易变部分。

refresh.py(每日刷新)与 prune-dangling-proxies.py(启动自愈)共用本模块,
避免两处实现漂移。
"""
import re

REGION_PAT = {
    "香港":   r"香港|HK|Hong\s*Kong|🇭🇰",
    "日本":   r"日本|JP|Japan|Tokyo|Osaka|🇯🇵",
    "美国":   r"美国|US|USA|United\s*States|America|🇺🇸",
    "新加坡": r"新加坡|SG|Singapore|狮城|🇸🇬",
    "台湾":   r"台湾|台灣|TW|Taiwan|🇹🇼",
    "英国":   r"英国|UK|GB|United\s*Kingdom|Britain|🇬🇧",
    "韩国":   r"韩国|韓國|KR|Korea|Seoul|🇰🇷",
    "德国":   r"德国|DE|German|Frankfurt|🇩🇪",
    "法国":   r"法国|FR|France|Paris|🇫🇷",
    "荷兰":   r"荷兰|NL|Netherlands|Amsterdam|🇳🇱",
}

# 这些组即使成员里没有别的组名,也不该被塞进节点。
SKIP_GROUPS = {"AdBlock"}


def rebuild(cfg, log=print):
    """重建聚合型组的成员。返回改动的组数。

    规则:
      - 引用了其它组的组(如 OpenAI: [Proxy, 香港, ...])一律不动 ——
        它们靠被引用的组自动获得节点。
      - 组名能匹配 REGION_PAT → 填该地区节点 + DIRECT 兜底。
      - 名为 Proxy 的总出口组 → 填全部订阅节点 + DIRECT + 本地 direct 节点。
      - SKIP_GROUPS 里的组跳过。
    """
    proxies = cfg.get("proxies") or []
    sub   = [p["name"] for p in proxies if p.get("type") != "direct"]
    local = [p["name"] for p in proxies if p.get("type") == "direct"]
    groups = cfg.get("proxy-groups") or []
    gnames = {g.get("name") for g in groups}
    if not sub:
        log("  订阅节点为 0,不重建分组")
        return 0

    changed = 0
    matched = set()
    for g in groups:
        name = g.get("name", "")
        if name in SKIP_GROUPS:
            continue
        cur = list(g.get("proxies") or [])
        # 引用了其它组 → 选择型组,不动
        if any(x in gnames for x in cur):
            continue

        want = None
        for region, pat in REGION_PAT.items():
            if re.search(pat, name, re.I):
                hit = [n for n in sub if re.search(pat, n, re.I)]
                matched.update(hit)
                want = (hit + ["DIRECT"]) if hit else ["DIRECT"]
                if not hit:
                    log(f"  组 [{name}] 无匹配节点,保留 DIRECT 占位")
                break
        if want is None and name == "Proxy":
            want = sub + ["DIRECT"] + local

        if want is None or cur == want:
            continue
        g["proxies"] = want
        changed += 1
        log(f"  重建 [{name}]: {len(cur)} → {len(want)} 个成员")

    # 未归入任何地区组的节点:不影响上网(它们都在 Proxy 里),
    # 但值得提醒 —— 可能是机场启用了 REGION_PAT 里没有的新地区。
    orphan = [n for n in sub if n not in matched]
    if orphan:
        log(f"  提示:{len(orphan)} 个节点未匹配任何地区组(仍在 Proxy 内可用): "
            f"{', '.join(orphan[:4])}{' …' if len(orphan) > 4 else ''}")
        log("       若是新地区,请在 mihomo_groups.py 的 REGION_PAT 里加一条")
    return changed


def group_health(cfg):
    """检查聚合型组是否退化成只剩 DIRECT/REJECT。返回退化的组名列表。

    用于把"能解析但实际在直连"的配置挡在 known-good 快照之外。
    """
    bad = []
    groups = cfg.get("proxy-groups") or []
    gnames = {g.get("name") for g in groups}
    sub = [p["name"] for p in (cfg.get("proxies") or []) if p.get("type") != "direct"]
    if not sub:
        return bad
    for g in groups:
        name = g.get("name", "")
        if name in SKIP_GROUPS:
            continue
        ps = list(g.get("proxies") or [])
        if any(x in gnames for x in ps):
            continue
        is_region = any(re.search(p, name, re.I) for p in REGION_PAT.values())
        if not (is_region or name == "Proxy"):
            continue
        if not any(x in sub for x in ps):
            bad.append(name)
    return bad
