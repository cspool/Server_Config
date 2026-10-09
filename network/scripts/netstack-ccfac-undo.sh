#!/usr/bin/env bash
# 统一接口:撤销 2026-10-08 的 ccfac 改动,回到改动前状态;并可重新施加。
#
#   sudo bash netstack-ccfac-undo.sh check   只看会动什么,不改任何东西
#   sudo bash netstack-ccfac-undo.sh undo    撤销:退出 Clash Verge 与全部内核、恢复 4 个 .bak.ccfac 文件、
#                                            旧 refresh.py 重建 config.yaml、拉起 mihomo 自动栈
#   sudo bash netstack-ccfac-undo.sh redo    恢复到 undo 之前(ccfac 已施加)并自行拉起自动栈
# 两者结束时都是:单内核 mihomo.service 运行中,无 GUI。
#
# undo 之前会把当前(ccfac)版本整体快照到 /etc/mihomo/undo-snap/ccfac-applied-<时间>/,
# redo 默认取最新快照;也可 redo <快照目录>。
# 不回滚 /usr/local/sbin/netstack:旧版里 openvpn3/guard 命令是活的、无标注,与"openvpn3 已撤销"冲突;
#   现版 netstack 已把它们标注为撤销,保持现版。
# openvpn3 相关步骤:代码保留,OPENVPN3_RETIRED=1 时只打印"跳过(已撤销)"。
# 不碰:Beyond 相关的一切(remote-access-watchdog.sh、watchdog 计数与定时器、beyond 底层路由)、
#       mihomo.service 单元文件(它的 openvpn3→campus-net 改动早于 ccfac)、
#       openvpn3-autoload(ccfac 之前就是 disabled)。
# 注意:mihomo.service 重启时其 ExecStartPost(ensure-remote-access.sh)会按既有逻辑重启 edge 容器一次。
set -uo pipefail

TAG=ccfac-20261008-195424
OPENVPN3_RETIRED="${OPENVPN3_RETIRED:-1}"   # openvpn3 已整体撤销:相关步骤只标注跳过,代码保留
SNAPROOT=/etc/mihomo/undo-snap
FILES=(
  /etc/mihomo/mihomo_groups.py
  /etc/mihomo/refresh.py
  /etc/mihomo/ensure-campus-net.sh
  /etc/mihomo/sub.url
)
CFG=/etc/mihomo/config.yaml
GOOD=/etc/mihomo/config.good.yaml
BIN=/usr/bin/verge-mihomo
EC=127.0.0.1:9097
GUI_USER=descfly

ok(){ printf '  \033[32m✓\033[0m %s\n' "$*"; }
no(){ printf '  \033[31m✗\033[0m %s\n' "$*"; }
hd(){ printf '\n\033[1;36m%s\033[0m\n' "$*"; }
need_root(){ [ "$(id -u)" = 0 ] || { echo "需要 root: sudo bash $0 $1"; exit 1; }; }

validate(){ $BIN -d /etc/mihomo -f "$1" -t >/dev/null 2>&1; }

stop_gui(){
  # Clash Verge 界面 + 它拉起的内核一起退。它与 systemd 内核共用 9097,
  # 开着就会把自己的 profile 推进 systemd 内核,留着没有意义。
  local pids
  pids=$(pgrep -ax verge-mihomo 2>/dev/null | awk '/-d \/home\//{print $1}')
  pkill -u "$GUI_USER" -x clash-verge 2>/dev/null && sleep 2
  for p in $pids; do kill "$p" 2>/dev/null; done; sleep 1
  for p in $pids; do kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null; done
  pgrep -u "$GUI_USER" -x clash-verge >/dev/null 2>&1 && no "clash-verge 仍在" || ok "Clash Verge 界面与 GUI 内核已退出"
}

stop_stack(){
  stop_gui
  systemctl stop mihomo.service 2>/dev/null; ok "mihomo.service 已停"
  for n in verge-mihomo mihomo clash clash-meta; do pkill -x "$n" 2>/dev/null; done; sleep 1
  ok "内核进程已清($(pgrep -cx verge-mihomo 2>/dev/null || echo 0) 个残留)"
  ip link del Mihomo 2>/dev/null || true
  for pri in 8999 9000 9001 9002 9003 9004 9010; do while ip rule del priority "$pri" 2>/dev/null; do :; done; done
  ip route flush table 2022 2>/dev/null; ip route flush table 100 2>/dev/null
  for r in 0.0.0.0/1 128.0.0.0/1; do ip route del "$r" 2>/dev/null; done
  resolvectl flush-caches 2>/dev/null
  ok "TUN / 策略规则 / 路由表 / DNS 缓存已清"
}

start_stack(){
  systemctl daemon-reload
  systemctl reset-failed mihomo.service 2>/dev/null || true
  systemctl start mihomo.service
  local i; for i in $(seq 20); do curl -s -m 2 --noproxy '*' -o /dev/null "http://$EC/version" 2>/dev/null && break; sleep 1; done
  printf '  mihomo.service: %s (API 就绪用时 %ss)\n' "$(systemctl is-active mihomo.service)" "$i"
  printf '  内核进程数: %s(应为 1)\n' "$(pgrep -cx verge-mihomo 2>/dev/null || echo 0)"
  ss -tlnp 2>/dev/null | grep -E '127.0.0.1:(7897|7899|9097)' | sed 's/^/    /'
}

selfcheck(){
  hd "自检"
  /usr/local/sbin/netstack status 2>/dev/null | sed 's/^/  /'
  echo "  --- 经 7897 的连通性 ---"
  for u in https://www.google.com/generate_204 https://api.anthropic.com/ https://github.com/; do
    printf '    %-40s HTTP=%s\n' "$u" "$(curl -s -o /dev/null -m 12 -x http://127.0.0.1:7897 -w '%{http_code}' "$u" 2>/dev/null || echo 000)"
  done
  echo "  --- Claude 组 ---"
  curl -s -m 5 --noproxy '*' "http://$EC/proxies/Claude" 2>/dev/null \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print("    type=%s now=%s 成员=%d"%(d.get("type"),d.get("now"),len(d.get("all",[]))))' 2>/dev/null \
    || echo "    (无 Claude 组 —— 撤销后这是预期)"
  _gui=$(pgrep -ax verge-mihomo 2>/dev/null | grep -c -- '-d /home/' || true)
  [ "${_gui:-0}" -gt 0 ] && no "GUI 内核仍在跑(退出失败?),它会通过 9097 覆盖 systemd 内核配置" || ok "单内核,无 GUI 干扰"
}

cmd_check(){
  hd "ccfac 改动范围($TAG)"
  for f in "${FILES[@]}"; do
    b="$f.bak.$TAG"
    if [ -e "$b" ]; then
      n=$(diff "$b" "$f" 2>/dev/null | grep -cE '^[<>]'); ok "$f  (备份存在,与当前差异 $n 行)"
    else no "$f  缺少备份 $b"; fi
  done
  printf '  openvpn.service 自启: %s —— openvpn3 已撤销,undo/redo 都不动它(跳过)\n' "$(systemctl is-enabled openvpn.service 2>&1|head -1)"
  printf '  config.yaml 里 Claude 组: %s 个, Claude 规则: %s 条\n' "$(grep -cE '^\s*-?\s*name: Claude$' "$CFG")" "$(grep -cE ',Claude$' "$CFG")"
  echo "  快照目录: $SNAPROOT"; ls -1d "$SNAPROOT"/ccfac-applied-* 2>/dev/null | sed 's/^/    /' || echo "    (尚无)"
  _gui=$(pgrep -ax verge-mihomo 2>/dev/null | grep -c -- '-d /home/' || true)
  printf '  GUI 内核: %s 个\n' "${_gui:-0}"
}

cmd_undo(){
  need_root undo
  for f in "${FILES[@]}"; do [ -e "$f.bak.$TAG" ] || { no "缺少 $f.bak.$TAG,中止,什么都没改"; exit 1; }; done

  hd "0/5 快照当前(ccfac)状态,供 redo"
  SNAP="$SNAPROOT/ccfac-applied-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$SNAP"
  for f in "${FILES[@]}"; do cp -p "$f" "$SNAP/$(basename "$f")"; done
  cp -p "$CFG" "$SNAP/config.yaml"; [ -e "$GOOD" ] && cp -p "$GOOD" "$SNAP/config.good.yaml"
  systemctl is-enabled openvpn.service >"$SNAP/openvpn.enabled" 2>&1
  ok "快照: $SNAP"

  hd "1/5 停止自动栈"; stop_stack

  hd "2/5 恢复 ${#FILES[@]} 个文件到 ccfac 之前"
  for f in "${FILES[@]}"; do cp -p "$f.bak.$TAG" "$f" && ok "$f"; done
  rm -rf /etc/mihomo/__pycache__

  hd "3/5 openvpn.service 自启"
  if [ "$OPENVPN3_RETIRED" = 1 ]; then printf '  \033[33m-\033[0m openvpn.service 跳过(已撤销,保持 disabled)\n'; else
  systemctl enable --now openvpn.service >/dev/null 2>&1 && ok "openvpn.service enabled + started" || no "enable 失败"; fi

  hd "4/5 用旧 refresh.py 重新生成 config.yaml(拉订阅)"
  if python3 /etc/mihomo/refresh.py 2>&1 | sed 's/^/    /'; then
    ok "config.yaml 已由旧逻辑重建"
  else
    no "刷新失败(多半是订阅拉不到)。保留当前 config.yaml,它仍含 ccfac 的 Claude 组/规则;联网后 sudo python3 /etc/mihomo/refresh.py 即可"
  fi
  validate "$CFG" && ok "config.yaml 校验通过" || { no "config.yaml 校验失败,回退到 config.good.yaml"; cp -p "$GOOD" "$CFG"; }

  hd "5/5 启动自动栈"; start_stack
  selfcheck
  echo
  echo "  恢复到 undo 之前: sudo bash $0 redo   (快照 $SNAP)"
}

cmd_redo(){
  need_root redo
  SNAP="${1:-$(ls -1d "$SNAPROOT"/ccfac-applied-* 2>/dev/null | tail -1)}"
  [ -n "$SNAP" ] && [ -d "$SNAP" ] || { no "没有快照可用($SNAPROOT)"; exit 1; }
  hd "从快照恢复 ccfac 状态: $SNAP"
  stop_stack
  for f in "${FILES[@]}"; do cp -p "$SNAP/$(basename "$f")" "$f" && ok "$f"; done
  cp -p "$SNAP/config.yaml" "$CFG"; [ -e "$SNAP/config.good.yaml" ] && cp -p "$SNAP/config.good.yaml" "$GOOD"
  rm -rf /etc/mihomo/__pycache__
  validate "$CFG" && ok "config.yaml 校验通过" || no "config.yaml 校验失败"
  if [ "$OPENVPN3_RETIRED" = 1 ]; then printf '  \033[33m-\033[0m openvpn.service 跳过(已撤销,保持 disabled)\n'; else
  if grep -q '^enabled' "$SNAP/openvpn.enabled" 2>/dev/null; then systemctl enable openvpn.service >/dev/null 2>&1; else systemctl disable --now openvpn.service >/dev/null 2>&1; fi
  ok "openvpn.service 自启 = $(cat "$SNAP/openvpn.enabled")"; fi
  start_stack; selfcheck
}

case "${1:-check}" in
  check) cmd_check ;;
  undo)  cmd_undo ;;
  redo)  cmd_redo "${2:-}" ;;
  *) sed -n '2,13p' "$0" | sed 's/^# \?//'; exit 2 ;;
esac
