# >>> 网络栈 CLI 重置 (仅宿主机) >>>
if [ ! -f /.dockerenv ] && ! grep -qE 'docker|containerd|kubepods' /proc/1/cgroup 2>/dev/null; then
  # 一键重置:停 mihomo(TUN消失) → 清残留路由 → 按链重启(openvpn3 步骤已撤销,脚本内标注跳过)
  alias netreset='sudo /usr/local/sbin/net-reset.sh'
  # 网络栈状态速览。openvpn3 / guard 已于 2026-10-08 整体撤销:相关行保留但只打印"跳过(已撤销)"
  netstat-paper() {
    local retired="${OPENVPN3_RETIRED:-1}"
    printf 'mihomo      : %s (自启 %s)\n' "$(systemctl is-active mihomo)" "$(systemctl is-enabled mihomo 2>&1)"
    if [ "$retired" = 1 ]; then
      printf 'guard.timer : 跳过(已撤销)\n'
      printf 'openvpn3    : 跳过(已撤销)\n'
    else
      printf 'guard.timer : %s (自启 %s)\n' "$(systemctl is-active claude-vpn-guard.timer)" "$(systemctl is-enabled claude-vpn-guard.timer 2>&1)"
      printf 'openvpn3    : %s 个会话  %s\n' "$(openvpn3 sessions-list 2>/dev/null | grep -c '^ *Path:')" "$(ip -o -4 addr show | awk '$4 ~ /^198\.18\./ {print $2" "$4; exit}')"
    fi
    printf 'Mihomo TUN  : %s\n' "$(ip -br link show Mihomo 2>/dev/null | awk '{print $1" "$2}' || echo 未出现)"
    if [ "$retired" = 1 ]; then
      printf 'VPN 域名    : 跳过(已撤销)\n'
    else
      printf 'VPN 域名    : %s (不应是 28.0.0.x)\n' "$(getent hosts ${VPN_DOMAIN:-your-vpn.example.com} 2>/dev/null | awk '{print $1}')"
    fi
    printf '兜底路由    : %s 条 (应为 0)\n' "$(ip route show | grep -cE '0.0.0.0/1|128.0.0.0/1')"
    printf 'Claude 出口 : %s\n' "$(curl -s -m 6 --noproxy '*' http://127.0.0.1:9097/proxies/Claude 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin);print("%s → %s"%(d.get("type"),d.get("now")))' 2>/dev/null || echo '无 Claude 组')"
  }
fi
# <<< 网络栈 CLI 重置 <<<
