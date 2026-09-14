#!/usr/bin/env python3
# 修复 mihomo 策略:放行 openvpn3 的底层握手流量
#  1) fake-ip-filter 加入 VPN 域名 -> DNS 返回真实 IP(不再是 28.0.0.x 假 IP)
#  2) rules 最前面插入 DIRECT 规则 -> 握手 UDP 直连,不进代理
import yaml, os, sys, shutil, datetime

CFG = "/etc/mihomo/config.yaml"
VPN_DOMAINS = ["+.<VPN域名>"]
DIRECT_RULES = [
    "PROCESS-NAME,openvpn3-service-client,DIRECT",
    "PROCESS-NAME,openvpn3,DIRECT",
    "PROCESS-NAME,openvpn,DIRECT",
    "DOMAIN-SUFFIX,<VPN域名>,DIRECT",
    "IP-CIDR,<VPN服务器IP-1>/32,DIRECT,no-resolve",
    "IP-CIDR,<VPN服务器IP-2>/32,DIRECT,no-resolve",
]

cfg = yaml.safe_load(open(CFG))
shutil.copy2(CFG, CFG + ".bak.policy-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))

# 1) fake-ip-filter
dns = cfg.setdefault("dns", {})
filt = dns.get("fake-ip-filter") or []
added_f = [d for d in VPN_DOMAINS if d not in filt]
dns["fake-ip-filter"] = added_f + filt

# 2) rules 前置
rules = cfg.get("rules") or []
added_r = [r for r in DIRECT_RULES if r not in rules]
cfg["rules"] = added_r + rules

tmp = CFG + ".tmp"
yaml.safe_dump(cfg, open(tmp, "w"), allow_unicode=True, sort_keys=False)
os.replace(tmp, CFG)
print(f"  fake-ip-filter 新增 {len(added_f)} 条: {added_f}")
print(f"  DIRECT 规则新增 {len(added_r)} 条")
print(f"  规则总数: {len(cfg['rules'])}, fake-ip-filter 总数: {len(dns['fake-ip-filter'])}")
