#!/usr/bin/env python3
"""按关键词重建 mihomo 的聚合型 proxy-group 成员。

策略(2026-10-08 起,随订阅换到 CCFAC 重写):

  ① Claude 流量 → 必须走【同时含「美国」「小水管」「固定IP」三个关键词】的节点。
     这是用户的硬要求:Anthropic 会按出口 IP 判定,固定 IP 才稳。
     当前订阅里这样的节点只有 1 个(5 倍率),所以 Claude 组是单点 ——
     该节点挂掉时 Claude 会直接不通,不做任何自动降级:降级到共享 IP
     反而会触发风控,比不通更糟。要加备份请改 CLAUDE_KEYS 或手动在组里选。
  ② 其余流量 → Auto(url-test,自动选最快的可用节点)或 DIRECT。
     Auto 只收 ≤ AUTO_MAX_RATE 倍率的节点:url-test 按延迟选,
     "顶级/小水管" 这类高倍率节点延迟通常最低、会被优先选中,
     放进去等于让日常流量持续烧高倍率额度。它们仍可在 Proxy 里手动选。

设计约束:**不依赖任何固定节点名**。机场随时改名,所以只认关键词,
不认编号、机房代号、倍率后缀等易变部分。

refresh.py(每日刷新)与 prune-dangling-proxies.py(启动自愈)共用本模块,
避免两处实现漂移。
"""
import re

# ───── Claude 专属节点的判据 ─────
# 三个关键词必须【全部】命中(大小写不敏感:订阅里既有"固定ip"也有"固定IP")。
CLAUDE_KEYS = ("美国", "小水管", "固定ip")
CLAUDE_GROUP = "Claude"

# ───── 自动选优组 ─────
AUTO_GROUP = "Auto"
AUTO_MAX_RATE = 1.5      # 倍率上限;超过的不进 Auto,只能在 Proxy 里手动选
AUTO_DEF = {
    "name": AUTO_GROUP,
    "type": "url-test",
    "url": "http://www.gstatic.com/generate_204",
    "interval": 300,          # 每 5 分钟复测
    "tolerance": 50,          # 差值小于 50ms 不切,避免反复抖动
}

# ───── 固定拓扑 ─────
# 旧订阅按地区分组(香港/日本/新加坡/台湾)。新策略不再需要地区组:
# 除 Claude 以外一律交给 Auto。这些组留在配置里只会是空壳,统一删掉。
OBSOLETE_GROUPS = {"香港", "日本", "新加坡", "台湾", "英国", "韩国",
                   "德国", "法国", "荷兰", "马来西亚", "美国", "固定IP"}

# 服务型组的成员模板。顺序即 UI 里的优先级,第一项是默认值。
SERVICE_MEMBERS = [AUTO_GROUP, "Proxy", "DIRECT"]
SPECIAL_MEMBERS = {
    "Domestic":  ["DIRECT", "Proxy"],
    "AsianTV":   ["Domestic", "Proxy"],
    "Apple":     ["DIRECT", "Proxy"],
    "Microsoft": ["DIRECT", "Proxy"],
    "AdBlock":   ["REJECT", "DIRECT", "Proxy"],
    "Others":    [AUTO_GROUP, "Proxy", "Domestic"],
}
# AdBlock 的成员是人工语义(REJECT 优先),重建时不要塞节点。
SKIP_GROUPS = {"AdBlock"}
ALWAYS_REBUILD = {"Proxy", AUTO_GROUP, CLAUDE_GROUP}


def node_rate(name):
    """从节点名尾部解析倍率,如 "...-1.5x" → 1.5。解析不到按 1.0 处理。"""
    m = re.search(r"-(\d+(?:\.\d+)?)x\s*$", name)
    return float(m.group(1)) if m else 1.0


def is_claude_node(name):
    """三个关键词全部命中才算。"""
    return all(re.search(k, name, re.I) for k in CLAUDE_KEYS)


def sub_nodes(cfg):
    """订阅节点名(排除本机 direct 伪出口)。"""
    return [p["name"] for p in (cfg.get("proxies") or [])
            if p.get("type") != "direct" and p.get("server")]


def local_nodes(cfg):
    return [p["name"] for p in (cfg.get("proxies") or []) if p.get("type") == "direct"]


def node_server_domains(cfg):
    """节点 server 里的域名(去掉纯 IP),用于补 dns.fake-ip-filter。

    2026-10-07 的教训:机场改 CDN 域名后,fake-ip-filter 里那条旧域名
    (*.oix_nodes.com)就成了死条目,新域名没人加。节点域名一旦落进 fake-ip
    就可能形成自指环路。这里从配置本身派生,不再手写。
    """
    doms = set()
    for p in (cfg.get("proxies") or []):
        s = str(p.get("server") or "")
        if not s or re.fullmatch(r"[0-9.]+", s) or ":" in s:
            continue                      # 纯 IPv4 / IPv6 不需要
        parts = s.split(".")
        doms.add(".".join(parts[-2:]) if len(parts) >= 2 else s)
    return sorted(doms)


def rebuild(cfg, log=print):
    """重建聚合型组。返回改动的组数。"""
    groups = cfg.get("proxy-groups")
    if groups is None:
        groups = cfg["proxy-groups"] = []
    sub = sub_nodes(cfg)
    local = local_nodes(cfg)
    if not sub:
        log("  订阅节点为 0,不重建分组")
        return 0

    changed = 0

    # ── 删除空壳地区组 ──
    drop = [g for g in groups if g.get("name") in OBSOLETE_GROUPS]
    if drop:
        for g in drop:
            groups.remove(g)
        changed += len(drop)
        log("  删除已废弃的地区组: " + ", ".join(g.get("name", "?") for g in drop))

    def upsert(name, defaults, members, why):
        nonlocal changed
        g = next((x for x in groups if x.get("name") == name), None)
        if g is None:
            g = dict(defaults)
            g["name"] = name
            g["proxies"] = list(members)
            groups.insert(0, g)
            changed += 1
            log(f"  新建 [{name}] ({g.get('type')}): {len(members)} 个成员 — {why}")
            return g
        for k, v in defaults.items():
            g[k] = v                       # 纠正被手改过的 type/interval 等
        g["name"] = name
        if list(g.get("proxies") or []) != list(members):
            n_old = len(g.get("proxies") or [])
            g["proxies"] = list(members)
            changed += 1
            log(f"  重建 [{name}]: {n_old} → {len(members)} 个成员 — {why}")
        return g

    # ── Claude 组:三词全中的节点,不加 DIRECT、不加别的节点 ──
    claude = [n for n in sub if is_claude_node(n)]
    if claude:
        upsert(CLAUDE_GROUP, {"type": "fallback",
                              "url": AUTO_DEF["url"], "interval": 300},
               claude, f"固定 IP 专用({'、'.join(CLAUDE_KEYS)})")
        if len(claude) == 1:
            log(f"  ⚠ [{CLAUDE_GROUP}] 只有 1 个节点({claude[0]}),"
                f"倍率 {node_rate(claude[0])}x —— 单点,该节点挂掉 Claude 即不通")
    else:
        log(f"  ⚠ 没有节点同时命中 {CLAUDE_KEYS} → [{CLAUDE_GROUP}] 退回 Auto")
        upsert(CLAUDE_GROUP, {"type": "select"}, [AUTO_GROUP, "Proxy"],
               "无三词全中的节点,临时退回 Auto")

    # ── Auto 组:倍率 ≤ AUTO_MAX_RATE 的全部节点 ──
    # 注意:url-test 组里【绝不能】放 DIRECT —— DIRECT 延迟近 0,会被永远选中,
    # 结果是静默直连。2026-09-25 的 github 不通就是这类退化。
    cheap = [n for n in sub if node_rate(n) <= AUTO_MAX_RATE and n not in claude]
    pricey = [n for n in sub if n not in cheap and n not in claude]
    upsert(AUTO_GROUP, AUTO_DEF, cheap or sub,
           f"自动选最快(倍率 ≤ {AUTO_MAX_RATE}x)")
    if pricey:
        log(f"  高倍率节点未进 Auto(仍可在 Proxy 手动选): "
            f"{', '.join(pricey[:4])}{' …' if len(pricey) > 4 else ''}")

    # ── Proxy:总出口,人工可选全部 ──
    upsert("Proxy", {"type": "select"},
           [AUTO_GROUP, CLAUDE_GROUP] + sub + ["DIRECT"] + local,
           "总出口,默认 Auto")

    # ── 其余服务型组 ──
    gnames = {g.get("name") for g in groups}
    for g in groups:
        name = g.get("name", "")
        if name in SKIP_GROUPS or name in ALWAYS_REBUILD:
            if name in SKIP_GROUPS:
                want = SPECIAL_MEMBERS.get(name)
                if want and list(g.get("proxies") or []) != want:
                    g["proxies"] = list(want)
                    changed += 1
                    log(f"  重建 [{name}]: → {want}")
            continue
        want = SPECIAL_MEMBERS.get(name, SERVICE_MEMBERS)
        want = [x for x in want if x in gnames or x in ("DIRECT", "REJECT")]
        if list(g.get("proxies") or []) != want:
            n_old = len(g.get("proxies") or [])
            g["proxies"] = list(want)
            changed += 1
            log(f"  重建 [{name}]: {n_old} → {len(want)} 个成员")
    return changed


def group_health(cfg):
    """检查关键组是否退化成只剩 DIRECT/REJECT。返回退化的组名列表。

    用于把"能解析但实际在直连"的配置挡在 known-good 快照之外。
    """
    bad = []
    groups = cfg.get("proxy-groups") or []
    gnames = {g.get("name") for g in groups}
    sub = sub_nodes(cfg)
    if not sub:
        return bad
    for g in groups:
        name = g.get("name", "")
        if name not in ("Proxy", AUTO_GROUP, CLAUDE_GROUP):
            continue
        ps = list(g.get("proxies") or [])
        if any(x in sub for x in ps):
            continue
        reachable = False
        for x in ps:
            if x in gnames:
                sg = next((g2 for g2 in groups if g2.get("name") == x), None)
                if sg and any(y in sub for y in (sg.get("proxies") or [])):
                    reachable = True
                    break
        if not reachable:
            bad.append(name)
    return bad


# ───── 规则与 DNS 的自维护 ─────
# 这两件事以前靠手改配置,换一次订阅就忘一次。2026-10-07 的
# *.oix_nodes.com 死条目、2026-10-08 被 remove-claude-routing.sh 一并删掉的
# Claude 规则,都是这么来的。现在由刷新流程每天重放一次。

CLAUDE_RULE_DOMAINS = [
    ("DOMAIN-SUFFIX", "anthropic.com"),
    ("DOMAIN-SUFFIX", "claude.ai"),
    ("DOMAIN-SUFFIX", "claude.com"),
    ("DOMAIN-SUFFIX", "claudeusercontent.com"),
    ("DOMAIN",        "http-intake.logs.us5.datadoghq.com"),
]
# claude / codex 的 CLI 进程:除上面这些域名外还会连 statsig、sentry 等,
# 一并钉到同一个固定 IP 出口,免得出口 IP 在两处之间跳。
CLAUDE_RULE_PROCESS = [("PROCESS-PATH-REGEX", r"(?i)claude")]

# 必须直连的判据/认证端点 —— 它们绝不能排在 Claude 规则之后,
# 否则链路未认证时连"能上网"都测不出来。见 campus-portal-direct.py。
_DIRECT_HEAD_HINTS = ("buaa.edu.cn", "connectivitycheck", "msftconnecttest",
                      "connect.rom.miui.com", "wifi.vivo.com.cn",
                      "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")


def ensure_claude_rules(cfg, log=print):
    """把 Claude 规则放在「认证直连块之后、其余规则之前」。返回新增条数。"""
    rules = cfg.get("rules")
    if rules is None:
        rules = cfg["rules"] = []
    gnames = {g.get("name") for g in (cfg.get("proxy-groups") or [])}
    if CLAUDE_GROUP not in gnames:
        log(f"  ⚠ 没有 [{CLAUDE_GROUP}] 组,跳过 Claude 规则维护")
        return 0

    want = [f"{k},{v},{CLAUDE_GROUP}" for k, v in CLAUDE_RULE_DOMAINS + CLAUDE_RULE_PROCESS]
    have = {str(r) for r in rules}
    missing = [w for w in want if w not in have]
    if not missing:
        return 0

    # 插入点:跳过开头连续的「认证/内网直连」规则
    pos = 0
    for i, r in enumerate(rules):
        if any(h in str(r) for h in _DIRECT_HEAD_HINTS):
            pos = i + 1
        else:
            break
    for off, w in enumerate(missing):
        rules.insert(pos + off, w)
    log(f"  补回 {len(missing)} 条 Claude 规则(插在第 {pos} 条之后): "
        + ", ".join(m.split(',')[1] for m in missing))
    return len(missing)


def ensure_fakeip_filter(cfg, log=print):
    """让 dns.fake-ip-filter 跟上订阅的节点域名,并清掉已失效的旧条目。

    节点域名若落进 fake-ip,mihomo 连自己的节点时可能拿到 28.x 的假地址。
    这里从 proxies 派生,并删掉形如 *.xxx 的、已不在当前节点域名里的旧机场条目。
    返回 (新增数, 删除数)。
    """
    dns = cfg.get("dns")
    if not isinstance(dns, dict):
        return (0, 0)
    flt = dns.get("fake-ip-filter")
    if flt is None:
        flt = dns["fake-ip-filter"] = []

    doms = node_server_domains(cfg)
    want = ["+." + d for d in doms]
    added = [w for w in want if w not in flt]

    # 只清理「看起来是机场节点域名」的死条目:带通配且不是我们自己维护的系统条目。
    keep_always = {"*.lan", "*.localdomain", "*.example", "*.invalid", "*.localhost",
                   "*.test", "*.local", "*.home.arpa", "*.time.edu.cn"}
    removed = []
    for x in list(flt):
        if x in keep_always or x.startswith("time") or x.startswith("ntp"):
            continue
        if not (x.startswith("*.") or x.startswith("+.")):
            continue
        base = x[2:]
        if base in doms:
            continue
        # 保留我们自己钉的功能域名(认证页、Beyond 控制面等)
        if any(t in base for t in ("buaa", "beyond", "connectivitycheck",
                                   "msftconnecttest", "miui", "vivo", "ipw.cn", "wmtok")):
            continue
        flt.remove(x)
        removed.append(x)

    for w in added:
        flt.insert(0, w)
    if added:
        log(f"  fake-ip-filter 新增节点域名 {len(added)} 条: {', '.join(added[:6])}"
            + (" …" if len(added) > 6 else ""))
    if removed:
        log(f"  fake-ip-filter 清除失效机场域名 {len(removed)} 条: {', '.join(removed)}")
    return (len(added), len(removed))

# ───── Beyond overlay 段必须绕开 TUN ─────
# 和 ensure_claude_rules 同一个道理:这件事只要漏一次,表现就是
# "内网其他设备都能穿透,偏偏本机不通",而且极难定位(见 ensure-beyond-underlay.sh
# 里 install_overlay_bypass 的注释)。所以每天刷新时重放一次。
OVERLAY_CIDRS = ["100.64.0.0/16"]


def ensure_overlay_bypass(cfg, log=print):
    """保证 overlay 段既不被 TUN 接管、也不被规则送去代理。返回改动处数。"""
    n = 0
    tun = cfg.get("tun")
    if isinstance(tun, dict):
        ex = tun.get("route-exclude-address")
        if ex is None:
            ex = tun["route-exclude-address"] = []
        for c in OVERLAY_CIDRS:
            if c not in ex:
                ex.append(c)
                n += 1
                log(f"  tun.route-exclude-address += {c}")

    rules = cfg.get("rules")
    if rules is None:
        rules = cfg["rules"] = []
    have = {str(r) for r in rules}
    want = [f"IP-CIDR,{c},DIRECT,no-resolve" for c in OVERLAY_CIDRS]
    missing = [w for w in want if w not in have]
    if missing:
        # 和 Claude 规则一样插在「认证直连块」之后
        pos = 0
        for i, r in enumerate(rules):
            if any(h in str(r) for h in _DIRECT_HEAD_HINTS):
                pos = i + 1
            else:
                break
        for off, w in enumerate(missing):
            rules.insert(pos + off, w)
        n += len(missing)
        log(f"  补回 {len(missing)} 条 overlay 直连规则: {', '.join(missing)}")
    return n
