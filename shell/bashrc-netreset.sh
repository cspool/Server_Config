# >>> 网络栈 CLI 重置 (仅宿主机) >>>
if [ ! -f /.dockerenv ] && ! grep -qE 'docker|containerd|kubepods' /proc/1/cgroup 2>/dev/null; then
  # 一键重置:停 mihomo(TUN消失) → 断 openvpn3 → 清残留路由 → 按链重启
  alias netreset='sudo /usr/local/sbin/net-reset.sh'
  # 网络栈状态速览
  netstat-paper() {
    printf 'mihomo      : %s (自启 %s)\n' "$(systemctl is-active mihomo)" "$(systemctl is-enabled mihomo 2>&1)"
    printf 'guard.timer : %s (自启 %s)\n' "$(systemctl is-active claude-vpn-guard.timer)" "$(systemctl is-enabled claude-vpn-guard.timer 2>&1)"
    printf 'openvpn3    : %s 个会话  %s\n' "$(openvpn3 sessions-list 2>/dev/null | grep -c '^ *Path:')" "$(ip -o -4 addr show | awk '$4 ~ /^198\.18\./ {print $2" "$4; exit}')"
    printf 'Mihomo TUN  : %s\n' "$(ip -br link show Mihomo 2>/dev/null | awk '{print $1" "$2}' || echo 未出现)"
    printf 'VPN 域名    : %s (不应是 28.0.0.x)\n' "$(getent hosts ${VPN_DOMAIN:-your-vpn.example.com} 2>/dev/null | awk '{print $1}')"
    printf '兜底路由    : %s 条 (应为 0)\n' "$(ip route show | grep -cE '0.0.0.0/1|128.0.0.0/1')"
  }
fi
# <<< 网络栈 CLI 重置 <<<
