#!/usr/bin/env python3
"""把校园网认证相关的域名/网段加入直连白名单,让"未认证"时也能打开认证页。

2026-10-07 的问题:重启后 mihomo 自动起来,但校园网还没认证。此时:
  · 认证域名被 fake-ip 接管,浏览器拿到 28.0.0.x 假地址
  · 该域名没有专属规则 → 落到 MATCH,Others → Others 指向 Proxy → 走代理
  · 而代理节点此刻根本连不上(没认证就没有外网)→ 认证页打不开 → 死锁
顺序必须是:先能打开认证页 → 认证 → 才有外网 → 代理才有意义。

本脚本做三件事(都是幂等的),三层递进:
  ① dns.fake-ip-filter 加认证域名 —— 让它们解析出【真实 IP】而非 28.0.0.x
  ② rules 最前面插 DOMAIN-SUFFIX/IP-CIDR → DIRECT —— 确保不走代理
     位置必须在最前:rules 顺序匹配,插在后面会被前面两万条规则抢先命中
  ③ tun.route-exclude-address 加 RFC1918 —— 这些网段【根本不进 TUN】,
     在路由层就直出。意义:即使 mihomo 配置坏了、正在重启、或分组全退化,
     认证页照样能打开。②依赖 mihomo 正常运行,③不依赖。

为什么 ③ 安全(已逐项核对):
  · Beyond overlay 是 100.64.0.0/16,不在 RFC1918 内,不受影响
  · mihomo 的 fake-ip 是 28.0.0.0/8,也不在 RFC1918 内
  · 规则里本来就有 IP-CIDR,10.0.0.0/8,DIRECT —— 语义一致,只是提前到路由层
  · 唯一代价:"访问某个内网 IP 需要经代理"会失效(本机无此需求)
"""
import os, shutil, subprocess, sys, datetime
import yaml

CFG = "/etc/mihomo/config.yaml"
GOOD = "/etc/mihomo/config.good.yaml"
BIN = "/usr/bin/verge-mihomo"
EC = "127.0.0.1:9097"

# 认证门户与校园内网。改成你自己学校的域名即可。
PORTAL_DOMAINS = ["buaa.edu.cn"]
# 门户与校园内网段。10/8 与 172.16/12 已在规则里,这里补的是"必须最先匹配"。
PORTAL_CIDRS = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
# 连通性探测端点:认证成功与否靠它们判断,也必须直连才准
PROBE_DOMAINS = ["connectivitycheck.gstatic.com", "msftconnecttest.com",
                 "connect.rom.miui.com", "wifi.vivo.com.cn"]
# 要从 TUN 路由中排除的网段(RFC1918 私有地址全集)。
# 校园门户 10.200.21.4 与认证后的 online_ip 10.134.138.11 都在 10/8 内。
TUN_EXCLUDE = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]

MARK = "# campus-portal-direct (由 campus-portal-direct.py 维护,勿手工编辑此段)"


def log(*a):
    print("[campus-portal]", *a, flush=True)


def main():
    cfg = yaml.safe_load(open(CFG))
    changed = False

    # ── ① fake-ip-filter ──
    dns = cfg.setdefault("dns", {})
    filt = list(dns.get("fake-ip-filter") or [])
    want = ["+." + d for d in PORTAL_DOMAINS] + ["+." + d for d in PROBE_DOMAINS]
    add = [w for w in want if w not in filt]
    if add:
        dns["fake-ip-filter"] = add + filt
        changed = True
        for w in add:
            log(f"  fake-ip-filter 加入 {w}")
    else:
        log("  fake-ip-filter 已包含全部认证域名")

    # ── ② rules 最前面插直连规则 ──
    rules = [str(r) for r in (cfg.get("rules") or [])]
    new_rules = [f"DOMAIN-SUFFIX,{d},DIRECT" for d in PORTAL_DOMAINS] \
              + [f"DOMAIN-SUFFIX,{d},DIRECT" for d in PROBE_DOMAINS] \
              + [f"IP-CIDR,{c},DIRECT,no-resolve" for c in PORTAL_CIDRS]
    missing = [r for r in new_rules if r not in rules]
    if missing:
        # 已有的同名规则先去掉,避免重复;再整块插到最前
        rules = [r for r in rules if r not in new_rules and r != MARK]
        cfg["rules"] = new_rules + rules
        changed = True
        log(f"  rules 最前面插入 {len(new_rules)} 条直连规则")
        for r in new_rules:
            log(f"    {r}")
    else:
        # 已存在,但要确认它们在最前面(否则会被前面的规则抢先)
        first = rules.index(new_rules[0]) if new_rules[0] in rules else -1
        if first > len(new_rules):
            rules = [r for r in rules if r not in new_rules]
            cfg["rules"] = new_rules + rules
            changed = True
            log(f"  规则已存在但位置过后(第 {first} 条)→ 移到最前")
        else:
            log("  直连规则已在最前面")

    # ── ③ tun.route-exclude-address:这些网段根本不进 TUN ──
    tun = cfg.setdefault("tun", {})
    ex = list(tun.get("route-exclude-address") or [])
    add_ex = [c for c in TUN_EXCLUDE if c not in ex]
    if add_ex:
        tun["route-exclude-address"] = ex + add_ex
        changed = True
        for c in add_ex:
            log(f"  tun.route-exclude-address 加入 {c}")
    else:
        log("  tun.route-exclude-address 已包含全部内网段")

    if not changed:
        log("无需改动")
        return 0

    # ── 校验后落地 ──
    tmp = CFG + ".tmp.portal"
    yaml.safe_dump(cfg, open(tmp, "w"), allow_unicode=True, sort_keys=False)
    r = subprocess.run([BIN, "-d", "/etc/mihomo", "-f", tmp, "-t"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        os.unlink(tmp)
        log("✗ 校验失败,已放弃:" + (r.stdout + r.stderr).strip()[-200:])
        return 1
    shutil.copy2(CFG, CFG + ".bak.portal." +
                 datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
    os.chmod(tmp, 0o644)
    os.replace(tmp, CFG)
    shutil.copy2(CFG, GOOD)
    log("✓ 已落地并更新 known-good 快照")

    subprocess.run(["curl", "-s", "-o", "/dev/null", "-m", "10", "--noproxy", "*",
                    "-X", "PUT", f"http://{EC}/configs?force=true",
                    "-H", "Content-Type: application/json",
                    "-d", f'{{"path":"{CFG}"}}'], capture_output=True)
    log("已热重载")
    return 0


if __name__ == "__main__":
    sys.exit(main())
