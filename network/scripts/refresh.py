#!/usr/bin/env python3
# 每天刷新: 下载订阅, 仅替换 config.yaml 的 proxies 段(保留本地 direct 节点如 OpenVPN-tun0),
# 分组/规则/tun 全部保留, 然后经 mihomo external-controller 热重载。
import sys, os, urllib.request, yaml, subprocess

BASE = "/etc/mihomo/config.yaml"
URL  = open("/etc/mihomo/sub.url").read().strip()
EC   = "127.0.0.1:9097"

def log(*a): print("[mihomo-refresh]", *a, flush=True)

# 1. 下载订阅
req = urllib.request.Request(URL, headers={"User-Agent": "clash-verge/mihomo"})
raw = urllib.request.urlopen(req, timeout=30).read().decode("utf-8", "replace")
sub = yaml.safe_load(raw)
if not isinstance(sub, dict) or "proxies" not in sub or not sub["proxies"]:
    log("订阅无 proxies, 放弃刷新(保留现有配置)"); sys.exit(1)
new_nodes = sub["proxies"]

# 2. 读基线, 保留非订阅来源的本地节点(type: direct, 例如 OpenVPN-tun0)
cfg = yaml.safe_load(open(BASE))
local = [p for p in cfg.get("proxies", []) if p.get("type") == "direct"]
names_new = {p["name"] for p in new_nodes}
local = [p for p in local if p["name"] not in names_new]
cfg["proxies"] = local + new_nodes

# 3. 原子写回
tmp = BASE + ".tmp"
yaml.safe_dump(cfg, open(tmp, "w"), allow_unicode=True, sort_keys=False)
os.replace(tmp, BASE)
log(f"proxies 更新: 本地{len(local)} + 订阅{len(new_nodes)} = {len(cfg['proxies'])}")

# 4. 热重载(不重启进程, 不断网)
r = subprocess.run(["curl","-s","-m","10","-X","PUT",
    f"http://{EC}/configs?force=true",
    "-H","Content-Type: application/json",
    "-d", f'{{"path":"{BASE}"}}'], capture_output=True, text=True)
log("reload:", r.stdout.strip() or "204 OK")
