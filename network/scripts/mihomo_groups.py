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

# 所有【英文缩写】都必须带词边界 \b。2026-09-29 的教训:
#   re.search("US", "DisneyPlus", re.I) 会命中 "Plus" 里的 "us"
#   → DisneyPlus 被误判成美国地区组、被塞进 Proxy 成员
#   → DisneyPlus 又引用 Proxy → mihomo 报
#     "loop is detected in ProxyGroup: [Proxy DisneyPlus]",整份配置校验失败。
# 中文词与 emoji 不需要边界(它们不会嵌在英文单词里)。
REGION_PAT = {
    "香港":   r"香港|\bHK\b|Hong\s*Kong|🇭🇰",
    "日本":   r"日本|\bJP\b|Japan|Tokyo|Osaka|🇯🇵",
    "美国":   r"美国|\bUSA?\b|United\s*States|America|🇺🇸",
    "新加坡": r"新加坡|\bSG\b|Singapore|狮城|🇸🇬",
    "台湾":   r"台湾|台灣|\bTW\b|Taiwan|🇹🇼",
    "英国":   r"英国|\bUK\b|\bGB\b|United\s*Kingdom|Britain|🇬🇧",
    "韩国":   r"韩国|韓國|\bKR\b|Korea|Seoul|🇰🇷",
    "德国":   r"德国|\bDE\b|German|Frankfurt|🇩🇪",
    "法国":   r"法国|\bFR\b|France|Paris|🇫🇷",
    "荷兰":   r"荷兰|\bNL\b|Netherlands|Amsterdam|🇳🇱",
}

# 这些组即使成员里没有别的组名,也不该被塞进节点。
SKIP_GROUPS = {"AdBlock"}

# 自动选优组的名字与参数。2026-09-29 新增,解决一个结构缺陷:
# 地区组本来就是 fallback(会自动切换),但 Proxy 是 Selector 且成员直接是
# 【具体节点】—— 用户选中的节点一挂,所有走 Proxy 的流量全卡,fallback 的
# 自动能力完全没被用上。实测那天 44 个节点只剩 7 个 alive、选中的节点 8/8 超时。
AUTO_GROUP = "Auto"
AUTO_DEF = {
    "name": AUTO_GROUP,
    "type": "url-test",
    "url": "http://www.gstatic.com/generate_204",
    "interval": 300,          # 每 5 分钟复测
    "tolerance": 50,          # 差值小于 50ms 不切,避免反复抖动
}
# Proxy 是"总出口"组,必须始终重建(即使它引用了别的组)。
# 其余引用了组名的选择型组一律不动 —— 它们靠被引用的组自动获得节点。
ALWAYS_REBUILD = {"Proxy"}


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

    # ── Auto 组:url-test,自动选最快的可用节点 ──
    # 它是自动故障转移的载体:节点挂了 mihomo 自己换,不需要人工干预。
    auto = next((g for g in groups if g.get("name") == AUTO_GROUP), None)
    if auto is None:
        auto = dict(AUTO_DEF)
        auto["proxies"] = list(sub)
        # 插在 Proxy 之前,便于阅读;顺序对 mihomo 无影响
        idx = next((i for i, g in enumerate(groups) if g.get("name") == "Proxy"), 0)
        groups.insert(idx, auto)
        gnames.add(AUTO_GROUP)
        changed += 1
        log(f"  新建 [{AUTO_GROUP}] (url-test): {len(sub)} 个节点,自动选最快")
    else:
        for k, v in AUTO_DEF.items():
            auto.setdefault(k, v)
        auto["type"] = AUTO_DEF["type"]          # 纠正被改成 select 的情况
        if list(auto.get("proxies") or []) != list(sub):
            n_old = len(auto.get("proxies") or [])
            auto["proxies"] = list(sub)
            changed += 1
            log(f"  重建 [{AUTO_GROUP}]: {n_old} → {len(sub)} 个节点")

    for g in groups:
        name = g.get("name", "")
        if name in SKIP_GROUPS or name == AUTO_GROUP:
            continue
        cur = list(g.get("proxies") or [])
        # 引用了其它组 → 选择型组,不动。Proxy 例外:它是总出口,必须始终重建。
        if name not in ALWAYS_REBUILD and any(x in gnames for x in cur):
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
            # 顺序即优先级(给人看的列表顺序):
            #   Auto(自动选优)→ 地区组(各自 fallback)→ 具体节点 → DIRECT → 本地伪出口
            # 默认选 Auto,所以节点挂了会自动切;需要固定某节点时仍可手动选。
            # 双重判据,缺一不可:
            #   ① 名字匹配地区正则
            #   ② 且它【直接指向节点】(成员里没有任何组名)
            # ② 是防循环的结构性保险:像 DisneyPlus 这种成员为
            # [Proxy, 香港, 日本...] 的选择型组,即使正则误判也进不来。
            regions = []
            for g2 in groups:
                n2 = g2.get("name", "")
                if n2 in SKIP_GROUPS or n2 in ALWAYS_REBUILD or n2 == AUTO_GROUP:
                    continue
                if not any(re.search(pt, n2, re.I) for pt in REGION_PAT.values()):
                    continue
                if any(x in gnames for x in (g2.get("proxies") or [])):
                    continue          # 引用了别的组 → 不是地区组
                regions.append(n2)
            want = [AUTO_GROUP] + regions + sub + ["DIRECT"] + local

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
        is_region = any(re.search(p, name, re.I) for p in REGION_PAT.values())
        if not (is_region or name in ("Proxy", AUTO_GROUP)):
            continue
        # Proxy 引用 Auto / 地区组是正常且期望的结构:只要它能【经由某个引用】
        # 到达真实节点就算健康,不必自己直接列节点。
        if any(x in sub for x in ps):
            continue
        reachable = False
        for x in ps:
            if x in gnames:
                sub_g = next((g2 for g2 in groups if g2.get("name") == x), None)
                if sub_g and any(y in sub for y in (sub_g.get("proxies") or [])):
                    reachable = True
                    break
        if not reachable:
            bad.append(name)
    return bad
