#!/usr/bin/env python3
"""每日订阅刷新 —— 永不产出坏配置。

流程:下载订阅 → 只替换 proxies 段(保留分组/规则/tun)→ 剔除悬空引用
      → 写临时文件 → verge-mihomo -t 校验 → 通过才替换并热重载。

2026-09-20 修复:此前只替换 proxies 而不管 proxy-groups 按名字的引用。
订阅更新后节点改名/下线会让引用悬空,整份配置解析失败 → mihomo 陷入
crash loop(实际发生过 212 次重启)。现在加了剔除 + 校验 + 回滚三道闸。

2026-09-25 修复:上一版的 prune 只做减法。机场改名后所有旧引用被剔除,
组被填成 ["DIRECT"] 占位,而没有任何环节把新节点填回去 —— 于是 Proxy 组
长期只剩 DIRECT,所有走 Proxy 的规则实际在直连(github.com 因此不通,
而 api.github.com 走 OpenAI 组反而正常)。现在增加 rebuild:每次刷新都按
**地区正则**重建组成员,不依赖任何固定节点名,机场随意改名也能跟上。
"""
import os, subprocess, sys, urllib.request, shutil, datetime, tempfile
import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mihomo_groups import rebuild, group_health

BASE   = "/etc/mihomo/config.yaml"
GOOD   = "/etc/mihomo/config.good.yaml"
SUBURL = "/etc/mihomo/sub.url"
BIN    = "/usr/bin/verge-mihomo"
EC     = "127.0.0.1:9097"
BUILTIN = {"DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE", "GLOBAL"}

def log(*a): print("[mihomo-refresh]", *a, flush=True)

def validate(path):
    r = subprocess.run([BIN, "-d", "/etc/mihomo", "-f", path, "-t"],
                       capture_output=True, text=True)
    return r.returncode == 0, (r.stdout + r.stderr).strip().splitlines()[-1:] or [""]

def prune(cfg):
    """剔除 proxy-groups 中指向不存在节点的引用,返回剔除条数。"""
    names  = {p["name"] for p in (cfg.get("proxies") or [])}
    groups = cfg.get("proxy-groups") or []
    valid  = names | {g["name"] for g in groups} | BUILTIN
    n = 0
    for g in groups:
        ps = g.get("proxies")
        if not ps:
            continue
        keep = [p for p in ps if p in valid]
        drop = [p for p in ps if p not in valid]
        if drop:
            n += len(drop)
            for d in drop:
                log(f"  剔除悬空引用 [{g['name']}] ← {d}")
            g["proxies"] = keep if keep else ["DIRECT"]
            if not keep:
                log(f"  组 [{g['name']}] 已清空,填 DIRECT 占位")

    # rules 也可能直接引用节点名(本机有 6 条指向 OpenVPN-tun0)。
    # 订阅换节点后同样会悬空 → 解析失败。丢弃这类规则,让流量落到后续规则/MATCH。
    rules, kept = cfg.get("rules") or [], []
    for r in rules:
        parts = [x.strip() for x in str(r).split(",")]
        t = parts[-1] if parts else ""
        if t in ("no-resolve", "src") and len(parts) > 2:
            t = parts[-2]
        if parts and t and t not in valid and parts[0] not in ("MATCH",):
            n += 1
            log(f"  丢弃悬空规则 → {t}: {str(r)[:60]}")
            continue
        kept.append(r)
    if len(kept) != len(rules):
        cfg["rules"] = kept
    return n

def main():
    url = open(SUBURL).read().strip()
    if not url:
        log("订阅 URL 为空,放弃"); return 1

    # 1. 下载订阅
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "clash-verge/mihomo"})
        sub = yaml.safe_load(urllib.request.urlopen(req, timeout=30)
                             .read().decode("utf-8", "replace"))
    except Exception as e:
        log(f"下载失败: {e};保留现有配置"); return 1
    new_nodes = (sub or {}).get("proxies") or []
    if not new_nodes:
        log("订阅无 proxies,保留现有配置"); return 1

    # 2. 以现有配置为基线,只换 proxies(保留本地 direct 节点如 OpenVPN-tun0)
    cfg   = yaml.safe_load(open(BASE))
    local = [p for p in (cfg.get("proxies") or []) if p.get("type") == "direct"]
    names_new = {p["name"] for p in new_nodes}
    local = [p for p in local if p["name"] not in names_new]
    cfg["proxies"] = local + new_nodes
    log(f"proxies: 本地 {len(local)} + 订阅 {len(new_nodes)} = {len(cfg['proxies'])}")

    # 3. 剔除悬空引用(订阅换节点后分组引用会失效)
    pruned = prune(cfg)
    log(f"剔除悬空引用 {pruned} 处")

    # 3b. 按地区正则重建组成员 —— prune 只做减法,没有这一步组会永久退化成
    #     仅剩 DIRECT(2026-09-25 的 github 不通就是这样来的)。
    nrb = rebuild(cfg, log=lambda m: log(m))
    log(f"重建分组 {nrb} 个")

    # 4. 写临时文件并校验 —— 不通过绝不落地
    fd, tmp = tempfile.mkstemp(dir="/etc/mihomo", prefix=".config.new.")
    os.close(fd)
    try:
        with open(tmp, "w") as f:
            yaml.safe_dump(cfg, f, allow_unicode=True, sort_keys=False)
        good, msg = validate(tmp)
        if not good:
            log(f"✗ 新配置校验失败,已放弃刷新,保留现有配置: {msg[0][:120]}")
            return 1
        log("✓ 新配置校验通过")

        # 健康门禁:能解析 != 能用。若聚合型组退化成只剩 DIRECT,
        # 所有走该组的规则会静默直连(2026-09-25 的 github 不通就是这样)。
        bad = group_health(cfg)
        if bad:
            log(f"✗ 组退化(只剩 DIRECT):{bad} —— 放弃刷新,保留现有配置")
            return 1

        # 5. 备份 → 替换 → 存 known-good 快照
        shutil.copy2(BASE, BASE + ".bak." +
                     datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
        os.chmod(tmp, 0o644)
        os.replace(tmp, BASE)
        tmp = None
        shutil.copy2(BASE, GOOD)
        log("已替换并更新 known-good 快照")
    finally:
        if tmp and os.path.exists(tmp):
            os.unlink(tmp)

    # 6. 热重载(不重启进程,不断网)
    r = subprocess.run(["curl", "-s", "-m", "10", "-X", "PUT",
                        f"http://{EC}/configs?force=true",
                        "-H", "Content-Type: application/json",
                        "-d", f'{{"path":"{BASE}"}}'],
                       capture_output=True, text=True)
    log("热重载:", r.stdout.strip() or "204 OK")

    # 7. 清理旧备份,只留最近 7 份
    baks = sorted(p for p in os.listdir("/etc/mihomo")
                  if p.startswith("config.yaml.bak."))
    for old in baks[:-7]:
        os.unlink(os.path.join("/etc/mihomo", old))
    return 0

if __name__ == "__main__":
    sys.exit(main())
