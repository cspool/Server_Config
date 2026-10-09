# 已证伪的方案(保留仅作记录,勿用)

## bind-beyond-eno2.py / toggle-beyond-eno2.py

用 mihomo 规则把 edge 指向一个 `type: direct` + `interface-name: eno2` 的伪出口。

**为什么无效**:流量仍然**先进 Mihomo TUN**(源地址变成 `28.0.0.1`),
mihomo 终结 UDP 再以自己的端口重新发起 —— 出站能通(注册、保活正常),
但 NAT 映射不稳定,**对端打洞进不来**,表现为 `utun0` 只有保活包、`tx` 恒为 0。

**正确做法**见 `../ensure-beyond-eno2.sh`:在**路由层**用主表 `/32 + onlink`
让流量根本不进 TUN。

## exclude-beyond-from-tun.py

用 `tun.route-exclude-address` 排除 Beyond 节点。方向对,但只解决"不进 TUN",
没解决"从哪块网卡出" —— 排除后会走主表默认路由(eno1),而需求是 eno2。
`/32 + onlink` 一步同时解决这两件事,故未采用。

## 2026-09-25:eno2 专用脚本整体归档

`ensure-beyond-eno2.sh`、`apply-beyond-eno2.sh`、`install-beyond-eno2.sh` 三个脚本
把网卡、网关、源地址**硬编码**为 eno2 / 192.168.10.1 / 192.168.10.86,已被参数化的
`../ensure-beyond-underlay.sh` + `/etc/mihomo/beyond.conf` 取代。

**为什么必须迁走 eno2**:eno2 所在网段(192.168.10.x)是校园网。认证过期后上游
用自签证书**透明劫持 HTTPS**,edge 请求控制面拿到的是 `gw.buaa.edu.cn` 的认证跳转
HTML 而不是 JSON:

```
[E] [confagent.go:87] invalid character '<' looking for beginning of value
```

于是永远拿不到节点列表 → `Racer` 阻塞在 `chan receive` → 隧道建不起来、控制台显示离线。
这个故障**极难诊断**:TCP 能连上(连的是认证网关)、路由全对、证书不校验时还回 HTTP 200,
所有常规检查都显示"正常"。判据是看 `/var/log/edge.log`(不是 `docker logs`)。

eno1(192.168.31.x)的证书正常(`CN=*.beyondnetwork.cn`),迁移后隧道立即恢复。

新脚本的可迁移性:只需改 `beyond.conf` 里的 `BEYOND_IFACE` 一行,源地址、网关、
是否需要 `onlink` 全部自动推导 —— 换网卡不必再改代码。


## 2026-10-08:claude-vpn-sync(用户级服务)归档

`claude-vpn-sync/` 下是 openvpn3 时代的用户级单元 `claude-vpn-sync.service` 与脚本。
它的逻辑:监听 `ip monitor link`,找一个**不是 Mihomo 的 tun 设备**当作 OpenVPN 的 tun,
把 Clash Verge 的 `clash-verge.yaml` 打补丁后 `PUT /configs` 推进 `127.0.0.1:9097`。

**为什么必须停**:openvpn3 撤销后,Beyond 的 `utun0` 正好满足"不是 Mihomo 的 tun"。
于是每当 edge 容器重启、`utun0` 重新出现(mihomo 每次启动的 ExecStartPost 都会重启 edge),
它就把 **GUI 的 profile(global 模式、无 TUN、Claude 组为普通 Selector)推进 systemd 内核**,
症状是启动约 9 秒后 `mode` 变 `global`、`Mihomo` TUN 消失、`Claude` 组从 fallback 变 Selector。
2026-10-08 当天被误判为"Clash Verge GUI 在推配置"两次,真正的持续推送方是它。

已执行:`systemctl --user disable --now claude-vpn-sync.service`(install-ccfac.sh 第 8 步也会做)。
原文件仍在 `~/.local/bin/claude-vpn-sync.sh` 与 `~/.config/systemd/user/claude-vpn-sync.service`,未删除。
