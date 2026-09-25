#!/usr/bin/env bash
# mihomo.service 的 ExecStartPre(在 ensure-openvpn3.sh 之后)。
#
# 目的:让"重启"本身就能修复坏配置,而不是陷入 crash loop。
# 订阅刷新后节点改名/下线会让 proxy-groups 的引用悬空,整份配置解析失败;
# 这里按三级递进自愈,任一级通过即放行。
#
#   ① 当前配置能解析      → 直接放行,并存一份 known-good 快照
#   ② 剔除悬空引用后能解析 → 就地修复
#   ③ 仍不行              → 回滚到 known-good 快照
#   都失败                → 告警但不阻断(让 mihomo 自己报错,便于排查)
set -uo pipefail

CFG=/etc/mihomo/config.yaml
GOOD=/etc/mihomo/config.good.yaml
BIN=/usr/bin/verge-mihomo
PRUNE=/etc/mihomo/prune-dangling-proxies.py

log() { printf '[ensure-config] %s\n' "$*"; }
ok()  { "$BIN" -d /etc/mihomo -f "$1" -t >/dev/null 2>&1; }

[ -r "$CFG" ] || { log "配置不存在: $CFG"; exit 0; }

# 健康检查:能解析 != 能用。若 Proxy / 地区组退化成只剩 DIRECT,
# 走这些组的规则会静默直连。这种配置绝不能被存成 known-good 快照,
# 否则坏状态会被固化、连回滚都救不回来(2026-09-25 实际发生过)。
healthy() {
    python3 - "$1" <<'PYEOF' 2>/dev/null
import sys, os, yaml
sys.path.insert(0, "/etc/mihomo")
try:
    from mihomo_groups import group_health
except Exception:
    sys.exit(0)                      # 模块缺失时不阻断,退回旧行为
bad = group_health(yaml.safe_load(open(sys.argv[1])))
if bad:
    print(",".join(bad)); sys.exit(1)
PYEOF
}

# ① 直接可用
if ok "$CFG"; then
    log "配置校验通过"
    if bad="$(healthy "$CFG")"; then
        cp -a "$CFG" "$GOOD" 2>/dev/null && log "已更新 known-good 快照"
    else
        log "⚠ 配置能解析,但这些组已退化成只剩 DIRECT:${bad:-未知}"
        log "  → 不更新 known-good 快照(避免固化坏状态);请跑一次 mihomo-refresh 重建分组"
    fi
    exit 0
fi

log "配置校验失败,尝试自愈"

# ② 剔除悬空引用
TMP="$(mktemp /etc/mihomo/.config.heal.XXXXXX)"
trap 'rm -f "$TMP"' EXIT
if [ -x "$PRUNE" ] || [ -r "$PRUNE" ]; then
    if python3 "$PRUNE" "$CFG" "$TMP" 2>&1 | sed 's/^/  /' && ok "$TMP"; then
        cp -a "$CFG" "${CFG}.broken.$(date +%Y%m%d-%H%M%S)"
        install -m 0644 "$TMP" "$CFG"
        if bad="$(healthy "$CFG")"; then
            cp -a "$CFG" "$GOOD" 2>/dev/null
            log "✓ 已剔除悬空引用并修复,快照已更新"
        else
            log "✓ 已剔除悬空引用并修复,但组仍退化:${bad:-未知} → 不更新快照"
        fi
        exit 0
    fi
    log "剔除悬空引用后仍无法解析"
else
    log "缺少 $PRUNE,跳过剔除"
fi

# ③ 回滚到 known-good
if [ -r "$GOOD" ] && ok "$GOOD"; then
    cp -a "$CFG" "${CFG}.broken.$(date +%Y%m%d-%H%M%S)"
    install -m 0644 "$GOOD" "$CFG"
    log "✓ 已回滚到 known-good 快照(订阅节点可能过期,建议手动刷新)"
    exit 0
fi

log "⚠ 自愈失败:配置无法解析且无可用快照。mihomo 将报错退出,请人工检查"
exit 0
