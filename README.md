# Server Config

单机 GPU 工作站的配置归档:**双 RTX 4090 + Ubuntu 24.04 + GNOME**。
解决三件事 —— 终端会话在任何入口下都能接回、图形与命令行按需切换、
VPN 按域名分流且开机自愈。

配置文件与脚本是**权威副本**,系统中的实际部署由 `network/scripts/install-*.sh` 产生。

---

## 解决了什么

### 1. 终端会话不随客户端消失

**问题**:VS Code 丢失容器连接、SSH 断线、关掉终端、切换图形模式 —— 跑了几小时的实验全没了。

**做法**:宿主机与每个容器都装 tmux,并把"进入 + 接回"封装成一条幂等命令。

```bash
dtm MLX_chipyard_dev        # 容器会话:有则接回,无则新建
tmux new -A -s host         # 宿主机会话:同理
# Ctrl+b d 脱离,任务继续跑
```

**效果**:四个入口(本地桌面终端 / TTY / 远程桌面里的终端 / SSH)用**完全相同的命令**接回同一个会话。本地开的实验出门 SSH 接回,远程开的实验回家在屏幕前接回。

会话消失只剩三种原因:自己 `exit`、容器停止、主机重启。关编辑器、断网、切模式都不影响。

### 2. 图形与命令行按需切换,显存可回收

**问题**:GNOME 桌面常驻占用约 1.3 GB 显存;需要时想让给训练任务。

**做法**:封装 `systemctl isolate` 并加确认与状态提示。

```bash
guistat        # 当前模式 + 两卡显存 + 服务状态
cli            # 关闭图形会话,释放显存(SSH / Docker / 网络栈不受影响)
gui            # 切回图形
```

**效果**:容器进程位于 `/system.slice/docker-<id>.scope`,`docker.service` 归属 `multi-user.target`,**切 CLI 不会杀死容器内的实验**。被终止的只有桌面程序与依附图形会话的远程桌面。

### 3. 远程访问:NAT 后的机器也能连进来

**问题**:机器在 NAT 后没有公网入口;GNOME 的远程登录需要 TPM 而本机没有;
双网卡导致回包走错网卡,表现为"密码对却认证超时"。

**做法**:三层各治一处。

| 层 | 配置 | 避开的坑 |
|---|---|---|
| **穿透** | BeyondNetwork edge(host network + privileged,`RestartPolicy=always`),本机**不配虚拟 IP**、只宣告站点子网(当前 `192.168.31.0/24`);底层流量用主表 `/32` 路由从**指定网卡直出,绕开 mihomo TUN**(网卡写在 `/etc/mihomo/beyond.conf`,当前 `eno1`) | 配虚拟 IP 会让 edge 劫持本机去局域网的流量;子网写成 `/16` 会把远端客户端自己的局域网也吸进隧道;**流量若进了 TUN,mihomo 会终结并重发 UDP,NAT 打洞失败 —— 隧道只有保活、`tx` 恒为 0** |
| **回包** | 全机只依赖 `eno1`,**eno2 已禁用** | 曾因双网卡各有默认路由导致请求从 eno2 进、回包从 eno1 出 → 认证超时;现单网卡不再有此问题 |
| **桌面** | GNOME 桌面共享,端口 **3390**,**关闭端口协商**,停用系统级远程登录 | 端口协商会把客户端重定向到隧道内不可达的端口;3389 上的系统级实例会抢先接管并甩给无凭据的 Handover 进程 |

**效果**:远端直接连 `192.168.31.116:3390`(桌面)或 `ssh descfly@192.168.31.116`(CLI),
P2P 直连 RTT ≈ 25 ms。远程桌面用镜像主屏模式,**不新建虚拟屏,本机双屏布局(含竖屏)不受扰动**。

### 4. VPN 按域名分流,开机自愈

**问题**:Claude 流量需走专用 OpenVPN 隧道,其余走 clash;而 clash 的 TUN 会拦截 OpenVPN 自身的握手,导致隧道建不起来;注销时 clash 退出又会触发路由兜底,打断其他隧道。

**做法**:收敛为**单一开机自启入口**,顺序不可颠倒。

```
mihomo.service
 ├─ ExecStartPre   → 确保 openvpn3 有有效会话(无 TUN 环境下握手)
 ├─ ExecStart      → mihomo 内核(TUN + 全局分流)
 └─ ExecStartPost  → 拉起路由守护 claude-vpn-guard
```

配置侧放行 VPN 自身的底层流量(`fake-ip-filter` + 前置 `DIRECT` 规则),使隧道在 TUN 运行中也能重连。

**效果**:开机一条链自动就绪,重启后策略依旧生效。出问题一条命令四阶段重置:

```bash
netreset       # 撤销全部影响 → 验证裸机 → 重新施加 → 验证
netstat-paper  # 状态速览
```

---

### 5. 断线自愈与无人值守恢复

**问题**:Beyond 隧道偶发断连且不自行恢复,人不在机器跟前就彻底失联;主机重启后远程桌面不会自动回来。

**做法**:一个独立于 mihomo 的开机自启守护 `remote-access-watchdog`,每 5 分钟检查一次,分级升压。

| 级别 | 条件 | 动作 |
|---|---|---|
| L1 | edge 容器不在 running | `docker start` |
| L2 | `utun0` 缺失或无 overlay 路由 | `docker restart edge` |
| L3 | 容器与网卡都正常,但**无底层 UDP 会话** | `docker restart edge` |
| L4 | 同上且**连续 20 分钟、4 次重启全部无效** | `systemctl reboot` |
| RDP | 服务不活或 3390 无监听 | 重启 `gnome-remote-desktop`(**不会重启主机**) |

判据用的是 edge 与 Beyond 节点之间的底层 UDP `ESTAB` 会话,不是 `utun0` 的收发计数 ——
后者在**对端不在线时本来就不动**,拿它当判据会导致客户端一关机,主机就每 20 分钟自己重启,打断实验。

两道保险:开机不足 15 分钟不重启(防引导循环);两次自动重启至少间隔 2 小时(时间戳落在 `/var/lib/`,跨重启保留)。

**重启之后**(2026-09-22 实测,已更正早先的错误结论):

| 通道 | 是否自动恢复 | 说明 |
|---|---|---|
| SSH | 是 | 公钥登录;`ssh.socket` 开机自启,edge 容器 `RestartPolicy=always` |
| RDP 3390 端口监听 | 是 | 由 `graphical-session.target` 决定,**与登录钥匙环无关** |
| RDP 登录认证 | **未验证** | grd 在 NLA 阶段要从登录钥匙环读凭据,钥匙环锁定时能否通过没测过 |

日志时序证明监听与钥匙环无关:`17:15:54 gkr-pam: couldn't unlock the login keyring`(锁着)→
`17:15:58 graphical-session.target` → `17:15:59 RDP server started`(仍锁着,已监听)。
反向亦成立:执行 `cli` 后 `graphical-session.target` 停止,0.7 秒后 grd 打印 `RDP server stopped`。
**所以 CLI 模式下 3390 必然不监听,这是设计行为;排查 RDP 不通先确认模式,而不是查钥匙环。**

> 早先本节曾写"RDP 重启后不会自动恢复,需远程 `gnome-keyring-daemon --unlock` 解锁",**两条都是错的**,
> 已删除。线级证据:`--unlock` 裸调用一个字节都不发、根本不连已有 daemon;`--replace --unlock` 只发
> op=3(QUIT),载荷不含密码 —— 该二进制从不把密码经控制套接字交给已运行的 daemon。详见指南。

**启用自动重启前必须先处理的风险**:`/etc/fstab` 中 `/data1`、`/data2`、`/data3` 三条均为 `defaults`、
**没有 `nofail`**,且 `RequiredBy=local-fs.target`。任一磁盘掉线或 `/data3`(pass=2)开机 fsck 失败,
系统即进入 `emergency.target`,SSH 与 RDP 全部不可用。另:日志持久化目录虽已建立但尚未生效
(journal 仍写在 `/run/log/journal`),下次重启仍会丢失现场。两项都需先修。

**代价**:自动重启会丢掉所有 tmux 会话,以及 `RestartPolicy=no` 的容器。
若希望开发容器随主机回来:`docker update --restart unless-stopped <容器名>`。

## 目录结构

```
.
├── docs/
│   ├── 开发环境指南.md          完整参考:四个入口、分流原理、故障处置
│   └── tmux实验操作说明.md      操作速查:五步逻辑 + 两个场景
├── network/                     VPN 分流栈 + 远程访问守护
│   ├── scripts/                 启动链脚本(ensure-*)、netstack、refresh、guard、watchdog、安装脚本
│   │   └── deprecated/          已证伪的方案,仅作记录
│   ├── systemd/                 7 个单元文件(mihomo / refresh / guard / watchdog)
│   └── config/                  配置占位(含机场凭据与 VPN 凭据,均为空文件,不入库)
├── obsidian/                    Obsidian 常驻服务 + REST 看护(CLI 模式下 MCP 可用)
├── shell/                       ~/.bashrc 的三个自定义块
│   ├── bashrc-cli-gui.sh        cli / gui / guistat
│   ├── bashrc-container.sh      dls / dsh / dtm / dtl
│   └── bashrc-netreset.sh       netreset / netstat-paper
├── display/monitors.xml         GNOME 显示器配置(双屏,含竖屏旋转)
├── sudoers/                     cli/gui 切换的免密规则
└── container/README.md          容器启动脚本位置与改动点
```

## 命令总览

| 命令 | 作用 |
|---|---|
| `dls` | 列出开发容器 |
| `dtm <容器> [会话]` | 进容器 tmux(建或接,幂等) |
| `dtl <容器>` | 列出该容器的 tmux 会话 |
| `dsh <容器>` | 容器里开个临时 shell(断开即死) |
| `tmux new -A -s <名>` | 宿主机 tmux(建或接) |
| `cli` / `gui` / `guistat` | 图形与命令行模式切换、状态查看 |
| `netreset` / `netstat-paper` | 网络栈四阶段重置、状态速览 |
| `sudo netstack status\|stop\|start\|restart\|reset\|heal` | 整条分流链的开关与自愈 |
| `journalctl -u remote-access-watchdog -f` | 实时查看隧道/RDP 守护的动作 |
| `cat /run/remote-access-watchdog.state` | 当前连续失败轮数(0 表示正常) |
| `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:27123/` | Obsidian Local REST API 健康检查 |
| `curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1:51361/search?q=x'` | Omnisearch API 健康检查(比 27123 晚就绪) |

远程入口:

| 用途 | 地址 |
|---|---|
| 远程桌面 | `192.168.31.116:3390`(端口必须写) |
| 远程 CLI | `ssh descfly@192.168.31.116`(公钥免密配置见指南「远程 SSH 免密登录」) |

## 部署

```bash
sudo bash network/scripts/install.sh              # headless mihomo
sudo bash network/scripts/install-chain.sh        # 启动链 openvpn3 → mihomo → guard
sudo bash network/scripts/install-policy-fix.sh   # 放行规则 + guard 路径 + net-reset
sudo bash network/scripts/install-beyond-underlay.sh  # Beyond 底层出口(网卡由 beyond.conf 决定),绕开 mihomo TUN
sudo bash network/scripts/disable-eno2.sh         # 禁用 eno2(校园网劫持源),全机只依赖 eno1
sudo bash network/scripts/install-fix.sh          # 订阅刷新修复 + 启动配置自愈 + netstack
sudo bash network/scripts/fix-guard-order.sh      # guard 移到启动链最后 + IgnoreOnIsolate
sudo bash network/scripts/install-watchdog.sh     # 隧道/RDP 守护 + 开启日志持久化
```

全部脚本均幂等,可重复执行;顺序如上。shell 片段需手工并入 `~/.bashrc`。

可选:免去 `cli`/`gui` 的 sudo 密码(只放行三条精确命令)

```bash
sudo install -m 0440 sudoers/gui-cli-switch /etc/sudoers.d/gui-cli-switch
sudo visudo -c -f /etc/sudoers.d/gui-cli-switch
```

## 说明

- `network/config/config.yaml` 含机场节点凭据,**不入库**。从 Clash 客户端导出后放到 `/etc/mihomo/config.yaml` 即可。
- 文档中的 RDP 密码已打码,本机用 `grdctl status --show-credentials` 查看。
- 远程桌面使用 GNOME Remote Desktop 的桌面共享模式;系统级远程登录需要 TPM,本机(Supermicro X12DAi-N6)无 TPM,故未启用。
- **eno2 已禁用**(2026-09-25),全机只依赖 `eno1`。eno2 接的是校园网,认证过期后上游用自签
  证书**透明劫持 HTTPS** —— 曾导致 Beyond edge 拿到认证跳转 HTML 而非 JSON、隧道整体不可用,
  而所有网络层检查都显示"正常",极难定位。该账号只允许一个设备在线,而设备位被上游小米路由器的 WAN 占着 —— eno2 认证成功只会把路由器顶下线。
  禁用方式(`network/scripts/disable-eno2.sh`)保留了连接配置,一条命令可回切;
  需要校园网时的认证方法见指南「为什么禁用 eno2」一节。
- `network/config/beyond.conf` 的 `BEYOND_IFACE` 决定 Beyond 底层出口网卡(当前 `eno1`),
  源地址、网关、是否需要 `onlink` 均自动推导 —— 换网卡只改这一行。

## 环境

Ubuntu 24.04.5 · GNOME 46 · 双 RTX 4090(NVIDIA 595)· Docker 28 · mihomo 1.18.7 · tmux 3.4
