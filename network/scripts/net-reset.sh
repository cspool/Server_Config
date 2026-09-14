#!/usr/bin/env bash
# 网络栈完整重置:撤销全部影响 → 验证裸机 → 重新施加 → 验证
#
# 为什么需要"撤销"阶段:杀掉 mihomo 进程并不会清理它对内核做的改动 ——
#   · ip rule 9000-9010 与 table 2022 仍在(进程死了不自动回收)
#   · systemd-resolved 仍缓存 fake-ip("${VPN_DOMAIN:-your-vpn.example.com}" -> 28.0.0.x)  ← 最隐蔽
# 结果就是"杀光 mihomo 后 openvpn3 依然连不上":它拿到缓存里的假 IP,发出去石沉大海。
#
#   sudo /usr/local/sbin/net-reset.sh
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行: sudo $0"; exit 1; }
VPN_USER=descfly
VPN_PROFILE=/home/descfly/Desktop/waimaot-liuzhixiang.ovpn
ok(){ printf '  \033[32m✓\033[0m %s\n' "$*"; }
no(){ printf '  \033[31m✗\033[0m %s\n' "$*"; }
hd(){ printf '\n\033[1;36m%s\033[0m\n' "$*"; }

hd "阶段 A — 撤销全部影响"

echo "A1 停止服务"
systemctl stop mihomo.service claude-vpn-guard.timer claude-vpn-guard.service 2>/dev/null
systemctl stop clash-verge-service.service 2>/dev/null
ok "服务已停"

echo "A2 杀掉残留内核进程"
for n in verge-mihomo mihomo clash clash-meta; do pkill -x "$n" 2>/dev/null; done
pkill -f clash-verge 2>/dev/null
sleep 1; ok "进程已清"

echo "A3 断开全部 openvpn3 会话"
for sp in $(runuser -u "$VPN_USER" -- openvpn3 sessions-list 2>/dev/null | awk '/^ *Path:/{print $2}'); do
    runuser -u "$VPN_USER" -- openvpn3 session-manage --session-path "$sp" --disconnect >/dev/null 2>&1
    echo "     断开 $sp"
done
sleep 2; ok "会话已断"

echo "A4 删除残留的 Mihomo 虚拟网卡"
ip link show Mihomo >/dev/null 2>&1 && { ip link del Mihomo 2>/dev/null && ok "已删除 Mihomo"; } || ok "Mihomo 不存在"

echo "A5 清理 mihomo 的策略规则(9000-9010)与 guard 的规则(50)"
for pri in 9000 9001 9002 9003 9004 9010 50; do
    while ip rule del priority "$pri" 2>/dev/null; do :; done
done
ok "策略规则已清"

echo "A6 清空路由表 2022(mihomo)与 100(guard)"
ip route flush table 2022 2>/dev/null; ip route flush table 100 2>/dev/null; ok "路由表已清空"

echo "A7 清理 guard 的兜底路由"
for r in 0.0.0.0/1 128.0.0.0/1; do ip route del "$r" 2>/dev/null && echo "     删除 $r"; done; ok "兜底路由已清"

echo "A8 清理指向已消失接口的残留规则"
ip rule show 2>/dev/null | grep -oE 'oif [a-zA-Z0-9]+ \[detached\]' | awk '{print $2}' | sort -u | while read -r i; do
    ip rule del oif "$i" lookup 100 2>/dev/null; echo "     删除 oif $i"
done
ip rule show 2>/dev/null | grep -q 'iif wg0 \[detached\]' && ip rule del iif wg0 lookup main 2>/dev/null
ok "残留规则已清"

echo "A9 刷新 DNS 缓存(清掉 fake-ip 记录) ← 关键"
resolvectl flush-caches 2>/dev/null && ok "systemd-resolved 缓存已刷新" || no "flush-caches 失败"
systemctl is-active nscd >/dev/null 2>&1 && { systemctl restart nscd; ok "nscd 已重启"; }

hd "阶段 B — 验证裸机状态(没有任何隧道/代理)"
b_ok=1
r=$(getent hosts "${VPN_DOMAIN:-your-vpn.example.com}" 2>/dev/null | awk '{print $1}')
case "$r" in 28.*) no "VPN 域名仍解析为假 IP: $r (缓存未清干净)"; b_ok=0 ;; "") no "VPN 域名解析失败"; b_ok=0 ;; *) ok "VPN 域名解析为真实 IP: $r" ;; esac
ip rule show | grep -qE "^90[0-9]{2}:" && { no "仍有 mihomo 策略规则残留"; b_ok=0; } || ok "无 mihomo 策略规则"
[ -z "$(ip route show table 2022 2>/dev/null)" ] && ok "table 2022 为空" || { no "table 2022 非空"; b_ok=0; }
if timeout 6 curl --noproxy '*' -s -o /dev/null http://www.baidu.com; then ok "直连公网正常"; else no "直连公网失败 ← 物理网络问题,与 VPN 栈无关"; b_ok=0; fi
[ "$b_ok" = 1 ] || { echo; no "裸机验证未通过,停在此处以便排查。修好后重跑本脚本。"; exit 1; }

hd "阶段 C — 重新施加策略"
echo "C1 启动 mihomo(链:无 TUN 环境建 VPN → 内核装规则 → 拉起 guard)"
systemctl start mihomo.service
sleep 8

hd "阶段 D — 验证"
printf '  openvpn3 会话 : %s 个 (应为 1)\n' "$(runuser -u "$VPN_USER" -- openvpn3 sessions-list 2>/dev/null | grep -c '^ *Path:')"
printf '  openvpn3 tun  : %s\n' "$(ip -o -4 addr show | awk '$4 ~ /^198\.18\./ {print $2" "$4; exit}')"
printf '  Mihomo TUN    : %s\n' "$(ip -br link show Mihomo 2>/dev/null | awk '{print $1" "$2}' || echo 未出现)"
printf '  mihomo        : %s\n' "$(systemctl is-active mihomo)"
printf '  guard.timer   : %s\n' "$(systemctl is-active claude-vpn-guard.timer)"
printf '  策略规则      : %s 条 (mihomo 重新装上)\n' "$(ip rule show | grep -cE '^90[0-9]{2}:')"
printf '  兜底路由      : %s 条 (应为 0)\n' "$(ip route show | grep -cE '^0.0.0.0/1|^128.0.0.0/1')"
printf '  VPN 域名解析  : %s (应为真实 IP)\n' "$(getent hosts ${VPN_DOMAIN:-your-vpn.example.com} 2>/dev/null | awk '{print $1}')"
echo "  连通性:"
printf '    直连 : '; timeout 6 curl --noproxy '*' -s -o /dev/null -w '%{http_code}\n' http://www.baidu.com || echo 失败
printf '    clash: '; timeout 10 curl -s -o /dev/null -w '%{http_code}\n' -x http://127.0.0.1:7897 https://www.google.com || echo 失败
