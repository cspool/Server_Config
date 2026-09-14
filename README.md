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
| **穿透** | BeyondNetwork edge(host network,`RestartPolicy=always`),本机**不配虚拟 IP**、只宣告 `192.168.10.0/24` 站点子网 | 配虚拟 IP 会让 edge 劫持本机去局域网的流量;子网写成 `/16` 会把远端客户端自己的局域网也吸进隧道 |
| **回包** | NetworkManager 持久化的源网段策略路由(规则 199/200 + 独立路由表) | 双网卡各有默认路由 → 请求从 eno2 进、回包从 eno1 出 → 认证超时 |
| **桌面** | GNOME 桌面共享,端口 **3390**,**关闭端口协商**,停用系统级远程登录 | 端口协商会把客户端重定向到隧道内不可达的端口;3389 上的系统级实例会抢先接管并甩给无凭据的 Handover 进程 |

**效果**:远端直接连 `192.168.10.86:3390`(桌面)或 `ssh descfly@192.168.10.86`(CLI),
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

## 目录结构

```
.
├── docs/
│   ├── 开发环境指南.md          完整参考:四个入口、分流原理、故障处置
│   └── tmux实验操作说明.md      操作速查:五步逻辑 + 两个场景
├── network/                     VPN 分流栈
│   ├── scripts/                 ensure-openvpn3 / net-reset / guard / refresh / 4 个安装脚本
│   ├── systemd/                 5 个单元文件
│   └── config/                  配置说明(mihomo 主配置含机场凭据,不入库)
├── shell/                       ~/.bashrc 的三个自定义块
│   ├── bashrc-cli-gui.sh        cli / gui / guistat
│   ├── bashrc-container.sh      dls / dsh / dtm / dtl
│   └── bashrc-netreset.sh       netreset / netstat-paper
├── display/monitors.xml         GNOME 显示器配置(双屏,含竖屏旋转)
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

远程入口:

| 用途 | 地址 |
|---|---|
| 远程桌面 | `192.168.10.86:3390`(端口必须写) |
| 远程 CLI | `ssh descfly@192.168.10.86` |

## 部署

```bash
sudo bash network/scripts/install.sh              # headless mihomo
sudo bash network/scripts/install-chain.sh        # 启动链 openvpn3 → mihomo → guard
sudo bash network/scripts/install-policy-fix.sh   # 放行规则 + guard 路径 + net-reset
sudo bash network/scripts/finish-setup.sh         # 开机自启 + 增强版 net-reset
```

四个脚本均幂等,可重复执行。shell 片段需手工并入 `~/.bashrc`。

## 说明

- `network/config/config.yaml` 含机场节点凭据,**不入库**。从 Clash 客户端导出后放到 `/etc/mihomo/config.yaml` 即可。
- 文档中的 RDP 密码已打码,本机用 `grdctl status --show-credentials` 查看。
- 远程桌面使用 GNOME Remote Desktop 的桌面共享模式;系统级远程登录需要 TPM,本机(Supermicro X12DAi-N6)无 TPM,故未启用。

## 环境

Ubuntu 24.04.5 · GNOME 46 · 双 RTX 4090(NVIDIA 595)· Docker 28 · mihomo 1.18.7 · tmux 3.4
