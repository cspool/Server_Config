#!/bin/bash
# 检测 OpenVPN 的 TUN 网卡名，并同步到 Clash Verge 的 OpenVPN-tun0 出站（Script.js + mihomo 热加载）
# 判定规则：
#   1. 首选 `openvpn3 sessions-list` 里的 Device: 字段（OpenVPN 自己声明的，最可靠）
#   2. 回退：/sys/class/net 下带 tun_flags 的 tun 设备，排除 Clash 自己的 TUN（名字来自 Merge.yaml 的 tun.device，默认 Mihomo）
set -u
VERGE_DIR="$HOME/.local/share/io.github.clash-verge-rev.clash-verge-rev"
SCRIPT="$VERGE_DIR/profiles/Script.js"
MERGE="$VERGE_DIR/profiles/Merge.yaml"
GEN="$VERGE_DIR/clash-verge.yaml"
RUNTIME="$HOME/.cache/claude-vpn-sync/runtime.yaml"
API="http://127.0.0.1:9097"
LOG="$HOME/.cache/claude-vpn-sync/sync.log"
log(){ echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

clash_dev=$(sed -n 's/^\s*device:\s*//p' "$MERGE" | head -1); clash_dev=${clash_dev:-Mihomo}

# 1. OpenVPN 声明的设备
ovpn_dev=$(openvpn3 sessions-list 2>/dev/null | awk '/Device:/{print $NF; exit}')
# 2. 回退：非 Clash 的 tun 设备
if [ -z "$ovpn_dev" ]; then
  for d in /sys/class/net/*; do
    n=$(basename "$d"); [ -e "$d/tun_flags" ] || continue; [ "$n" = "$clash_dev" ] && continue
    ovpn_dev=$n; break
  done
fi
if [ -z "$ovpn_dev" ]; then log "no OpenVPN tun found (clash tun=$clash_dev); leaving config untouched"; exit 0; fi
if [ "$ovpn_dev" = "$clash_dev" ]; then log "ERROR: detected dev $ovpn_dev is Clash's own TUN, refusing"; exit 1; fi

cur=$(grep -oP '"interface-name":\s*"\K[^"]+' "$SCRIPT" | head -1)
if [ "$cur" = "$ovpn_dev" ] && [ "${1:-}" != "--force" ]; then exit 0; fi

log "OpenVPN tun: $ovpn_dev (was: ${cur:-none}); clash tun: $clash_dev -> updating"
sed -i "s/\"interface-name\":\s*\"[^\"]*\"/\"interface-name\": \"$ovpn_dev\"/" "$SCRIPT"

# 热加载：基于当前生成的配置，只替换 OpenVPN-tun0 的 interface-name
python3 - "$GEN" "$RUNTIME" "$ovpn_dev" <<'PY' || { log "patch failed"; exit 1; }
import sys, yaml
src, dst, dev = sys.argv[1:4]
c = yaml.safe_load(open(src))
found = False
for p in c.get("proxies", []):
    if p.get("name") == "OpenVPN-tun0":
        p["interface-name"] = dev; found = True
if not found:
    c["proxies"] = [{"name":"OpenVPN-tun0","type":"direct","interface-name":dev}] + c.get("proxies", [])
    c["rules"] = ["PROCESS-PATH-REGEX,(?i)claude,OpenVPN-tun0"] + [r for r in c.get("rules", []) if "OpenVPN-tun0" not in str(r)]
yaml.safe_dump(c, open(dst, "w"), allow_unicode=True, sort_keys=False)
PY
chmod 644 "$RUNTIME"
code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$API/configs?force=true" -H 'Content-Type: application/json' -d "{\"path\":\"$RUNTIME\"}")
log "mihomo reload HTTP $code"
