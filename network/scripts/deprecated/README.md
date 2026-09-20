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
