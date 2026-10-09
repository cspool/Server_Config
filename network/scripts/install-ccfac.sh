#!/usr/bin/env bash
# 迁到 CCFAC 订阅 + Claude 固定 IP 出口 + 单内核收口(2026-10-08)
#
# 本机实测到的状态,也是本脚本要解决的:
#   ① 有【两个】mihomo 内核在跑 ——
#      systemd mihomo.service : 持有 Mihomo TUN、rule 模式、【旧订阅】
#                               ← 开机与 CLI 模式下唯一会起的就是它
#      Clash Verge GUI 的内核 : 无 TUN、global 模式、CCFAC 订阅,
#                               但占着 7897 / 7899 / 9097
#      于是"现在能用"靠的是 GUI,一进 CLI 模式就退回旧订阅。
#   ② Claude 要走【同时含「美国」「小水管」「固定IP」三个关键词】的节点;
#      其余流量走 Auto(自动选最快)或直连。
#   ③ openvpn.service 仍 enabled —— openvpn3 分流已整体撤销,不该再自启。
#
# 顺序不可调换:先把新订阅落到 systemd 内核,再关 GUI 内核。
# 反过来会出现一段"7897 由旧订阅接管"的窗口,远程会话会断在那里。
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "需要 root: sudo bash $0"; exit 1; }

SRC="$(cd "$(dirname "$0")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
VPN_USER=descfly
GUI_DIR="/home/$VPN_USER/.local/share/io.github.clash-verge-rev.clash-verge-rev"
PROFILES="$GUI_DIR/profiles.yaml"
SUB_NAME="${SUB_NAME:-CCFAC.yaml}"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()  { printf '  OK  %s\n' "$*"; }
no()  { printf '  !!  %s\n' "$*"; }

install_one() {
    local src="$1" dst="$2"
    [ -r "$src" ] || { no "源文件缺失: $src"; exit 1; }
    case "$src" in
        *.sh) bash -n "$src" || { no "语法检查失败: $src"; exit 1; } ;;
        *.py) python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$src" \
                  || { no "语法检查失败: $src"; exit 1; } ;;
    esac
    [ -e "$dst" ] && cp -a "$dst" "${dst}.bak.ccfac-${TS}"
    install -m 0755 "$src" "$dst"
    ok "$dst"
}

say "[1/9] 取 ${SUB_NAME} 的订阅 URL(从 GUI 的 profiles.yaml;不回显内容)"
NEWURL="$(python3 "$SRC/.sub-url-from-profiles.py" "$PROFILES" "$SUB_NAME")" \
    || { no "取 URL 失败: $NEWURL"; exit 1; }
printf '  URL 域名: %s(长度 %s)\n' "$(sed -E 's#^(https?://[^/]+).*#\1#' <<<"$NEWURL")" "${#NEWURL}"
[ -e /etc/mihomo/sub.url ] && cp -a /etc/mihomo/sub.url "/etc/mihomo/sub.url.bak.ccfac-${TS}"
printf '%s\n' "$NEWURL" > /etc/mihomo/sub.url
chmod 0600 /etc/mihomo/sub.url
ok "已写入 /etc/mihomo/sub.url (0600)"

say "[2/9] 安装脚本"
install_one "$SRC/mihomo_groups.py"          /etc/mihomo/mihomo_groups.py
install_one "$SRC/refresh.py"                /etc/mihomo/refresh.py
install_one "$SRC/ensure-campus-net.sh"      /etc/mihomo/ensure-campus-net.sh
install_one "$SRC/remote-access-watchdog.sh" /etc/mihomo/remote-access-watchdog.sh
install_one "$SRC/netstack"                  /usr/local/sbin/netstack
rm -rf /etc/mihomo/__pycache__
ok "已清 __pycache__(旧 .pyc 会盖掉新模块)"

say "[3/9] 显式打开 find-process-mode(PROCESS-PATH-REGEX 规则要用)"
python3 "$SRC/.set-find-process-mode.py" || { no "设置失败"; exit 1; }

say "[4/9] 刷新订阅:下载 CCFAC → 重建分组 → 校验 → 落地 → 热重载"
# refresh.py 自带 4 种下载重试、临时文件校验、group_health 门禁;
# 任一环节失败都保留现有配置,所以这一步失败不会把机器弄坏。
if python3 /etc/mihomo/refresh.py 2>&1 | sed 's/^/  /'; then
    ok "刷新流程结束"
else
    no "刷新失败 —— 现有配置已保留,不要继续后面的步骤"
    exit 1
fi

say "[5/9] 核对新配置(不通过就停在这里,mihomo 仍跑旧配置,远程不会断)"
python3 "$SRC/.verify-ccfac-config.py" || { no "新配置不满足预期"; exit 1; }

say "[6/9] 停掉 Clash Verge GUI 的第二个内核,让 systemd 内核独占端口"
# 只认 -d 指向用户目录的那个;systemd 的指向 /etc/mihomo,绝不能误杀。
# 必须用 pgrep -ax(精确进程名):-f 会把本脚本自己的命令行也匹配上。
GUIPIDS="$(pgrep -ax verge-mihomo 2>/dev/null | awk -v d="$GUI_DIR" '$0 ~ d {print $1}')"
if [ -z "$GUIPIDS" ]; then
    ok "没有 GUI 内核在跑"
else
    printf '  GUI 内核 pid: %s\n' "$GUIPIDS"
    pkill -u "$VPN_USER" -x clash-verge 2>/dev/null && ok "已退出 Clash Verge 界面" || true
    sleep 2
    for p in $GUIPIDS; do kill "$p" 2>/dev/null || true; done
    sleep 2
    for p in $GUIPIDS; do kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null || true; done
    ok "GUI 内核已停"
fi
# 它不会自己回来:verge.yaml 里 enable_auto_launch: false(已核实)。
# 但人工打开界面仍会再起一个 —— 那是 netstack gui 这条保底通道的用法。

say "[7/9] 重启 systemd 内核,接管 7897 / 7899 / 9097"
systemctl restart mihomo.service
for _ in $(seq 40); do
    ss -tln 2>/dev/null | grep -q '127.0.0.1:9097' && break
    sleep 1
done
printf '  mihomo.service: %s\n' "$(systemctl is-active mihomo.service)"
ss -tlnp 2>/dev/null | grep -E '9097|7897|7899' | sed 's/^/  /'

say "[8/9] 关掉 openvpn 的开机自启(代码与配置保留,要用时仍可手动 start)"
for u in openvpn.service openvpn3-autoload.service; do
    cur="$(systemctl is-enabled "$u" 2>/dev/null || echo -)"
    if [ "$cur" = enabled ]; then
        systemctl disable --now "$u" >/dev/null 2>&1 && ok "$u 已 disable" || no "$u disable 失败"
    else
        ok "$u 本就不是 enabled($cur)"
    fi
done
# 用户级残留:claude-vpn-sync 会把 Beyond 的 utun0 误认为 OpenVPN tun,
# 然后把 GUI profile 推进 9097(2026-10-08 定位)。必须一并停掉。
_u=descfly; _uid="$(id -u "$_u" 2>/dev/null || echo)"
if [ -n "$_uid" ] && [ -d "/run/user/$_uid" ]; then
    if runuser -u "$_u" -- env XDG_RUNTIME_DIR="/run/user/$_uid" systemctl --user is-enabled claude-vpn-sync.service >/dev/null 2>&1; then
        runuser -u "$_u" -- env XDG_RUNTIME_DIR="/run/user/$_uid" systemctl --user disable --now claude-vpn-sync.service >/dev/null 2>&1 \
            && ok "用户级 claude-vpn-sync.service 已 disable" || no "claude-vpn-sync.service disable 失败"
    else
        ok "用户级 claude-vpn-sync.service 本就不是 enabled"
    fi
else
    no "无 $_u 的用户会话,跳过 claude-vpn-sync.service(登录后手动: systemctl --user disable --now claude-vpn-sync.service)"
fi

say "[9/9] 重置 watchdog 计数并重启定时器"
echo 0 > /run/remote-access-watchdog.anyfail
echo 0 > /run/remote-access-watchdog.state
rm -f /run/remote-access-watchdog.reboot-requested
echo 0 > /var/lib/remote-access-watchdog.rebootcount
systemctl restart remote-access-watchdog.timer
systemctl restart mihomo-refresh.timer
ok "计数归零,定时器已重启"

say "=============== 自检 ==============="
/usr/local/sbin/netstack status 2>&1 | sed 's/^/  /'
echo
echo "  --- Claude 实际出口 IP(两次应相同) ---"
for i in 1 2; do printf '    #%s %s\n' "$i" "$(curl -s -m 20 https://api.ipify.org 2>/dev/null || echo 取不到)"; done
echo "  --- 连通性 ---"
for u in https://api.anthropic.com/ https://github.com/ https://www.google.com/generate_204; do
    printf '    %-38s %s\n' "$u" "$(curl -s -o /dev/null -m 15 -w 'HTTP=%{http_code} %{time_total}s' "$u" 2>/dev/null || echo 失败)"
done
echo
echo "完成。"
echo "  日常/开机形态 : CLI —— mihomo.service 单内核,Claude 钉固定 IP 节点"
echo "  保底通道      : sudo netstack gui   (撤销全部自动配置,人工用 Clash Verge 选节点)"
echo "  收回          : sudo netstack cli   (或直接重启,开机形态就是 CLI)"
echo
echo "回滚:/etc/mihomo/*.bak.ccfac-${TS}、/etc/mihomo/config.yaml.bak.*"
echo "     旧订阅 URL 在 /etc/mihomo/sub.url.bak.ccfac-${TS}"
