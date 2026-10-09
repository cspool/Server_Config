#!/usr/bin/env bash
set -Eeuo pipefail

[ "$(id -u)" -eq 0 ] || {
  echo "请用 sudo 运行: sudo bash $0"
  exit 1
}

CONFIG=/etc/mihomo/config.yaml
UNIT=/etc/systemd/system/mihomo.service
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR=/var/backups/claude-routing-removed-$TIMESTAMP

mkdir -p "$BACKUP_DIR"
for path in \
  "$CONFIG" \
  /etc/mihomo/config.good.yaml \
  "$UNIT" \
  /etc/systemd/system/claude-vpn-guard.service \
  /etc/systemd/system/claude-vpn-guard.timer \
  /usr/local/sbin/claude-vpn-guard.sh \
  /etc/mihomo/ensure-openvpn3.sh; do
  [ ! -e "$path" ] || cp -a "$path" "$BACKUP_DIR/"
done

sed -i -E \
  -e '/^  - \+\.wmtok\.com$/d' \
  -e '/^- name: OpenVPN-tun0$/,+2d' \
  -e '/^  - OpenVPN-tun0$/d' \
  -e '/^- PROCESS-NAME,openvpn3-service-client,DIRECT$/d' \
  -e '/^- PROCESS-NAME,openvpn3,DIRECT$/d' \
  -e '/^- PROCESS-NAME,openvpn,DIRECT$/d' \
  -e '/^- DOMAIN-SUFFIX,wmtok\.com,DIRECT$/d' \
  -e '/^- IP-CIDR,47\.117\.68\.187\/32,DIRECT,no-resolve$/d' \
  -e '/^- IP-CIDR,47\.102\.131\.83\/32,DIRECT,no-resolve$/d' \
  -e '/^- PROCESS-PATH-REGEX,\(\?i\)claude,.*$/d' \
  -e '/^- DOMAIN-SUFFIX,anthropic\.com,.*$/d' \
  -e '/^- DOMAIN-SUFFIX,claude\.ai,.*$/d' \
  -e '/^- DOMAIN-SUFFIX,claude\.com,.*$/d' \
  -e '/^- DOMAIN-SUFFIX,claudeusercontent\.com,.*$/d' \
  -e '/^- DOMAIN,http-intake\.logs\.us5\.datadoghq\.com,OpenVPN-tun0$/d' \
  "$CONFIG"

if grep -Eiq 'OpenVPN-tun0|PROCESS-PATH-REGEX,.*claude|DOMAIN-SUFFIX,(anthropic\.com|claude\.ai|claude\.com|claudeusercontent\.com)' "$CONFIG"; then
  echo "错误: Claude 专属规则仍有残留,已停止操作。备份位于 $BACKUP_DIR" >&2
  exit 1
fi

/usr/bin/verge-mihomo -d /etc/mihomo -f "$CONFIG" -t

sed -i -E \
  -e '/openvpn3/d' \
  -e '/OpenVPN/d' \
  -e '/Claude/d' \
  -e '/claude-vpn-guard/d' \
  -e '/guard/d' \
  -e '/VPN 连接尝试/d' \
  "$UNIT"

systemctl disable --now claude-vpn-guard.timer 2>/dev/null || true
systemctl stop claude-vpn-guard.service 2>/dev/null || true

for session_path in $(runuser -u descfly -- openvpn3 sessions-list 2>/dev/null | awk '/^ *Path:/{print $2}'); do
  runuser -u descfly -- openvpn3 session-manage --session-path "$session_path" --disconnect >/dev/null 2>&1 || true
done

while ip rule del priority 50 2>/dev/null; do :; done
ip route flush table 100 2>/dev/null || true
ip route del 0.0.0.0/1 2>/dev/null || true
ip route del 128.0.0.0/1 2>/dev/null || true
rm -f /run/campus-skip-openvpn3

for path in \
  /etc/systemd/system/claude-vpn-guard.service \
  /etc/systemd/system/claude-vpn-guard.timer \
  /usr/local/sbin/claude-vpn-guard.sh \
  /etc/mihomo/ensure-openvpn3.sh; do
  [ ! -e "$path" ] || mv "$path" "$BACKUP_DIR/"
done

install -m 0644 "$CONFIG" /etc/mihomo/config.good.yaml
systemctl daemon-reload
systemctl reset-failed
systemctl restart mihomo.service

echo
echo "Claude 专属路由已撤销。"
echo "备份: $BACKUP_DIR"
echo "mihomo: $(systemctl is-active mihomo.service)"
echo "OpenVPN 会话: $(runuser -u descfly -- openvpn3 sessions-list 2>/dev/null | grep -c '^ *Path:' || true)"
echo "priority 50 规则: $(ip rule show | grep -c '^50:' || true)"
echo "table 100: $(ip route show table 100 2>/dev/null | tr '\n' ' ')"
