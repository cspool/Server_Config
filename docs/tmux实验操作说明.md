# tmux 实验操作说明

> 生成于 2026-09-14。配套文档:[开发环境指南](开发环境指南.md)
>
> **一条原则**:所有工作放进 tmux。tmux 会话不属于任何终端,任何入口都能 attach 到同一个会话 ——
> 本地开的实验出门 SSH 接回,远程开的实验回家在屏幕前接回。

## 为什么用 tmux

**把会话从客户端剥离,只靠 CLI 就能恢复。**

| 出了什么事 | 不用 tmux | 用 tmux |
|---|---|---|
| VS Code 丢失容器连接 / 关掉编辑器 | ❌ 终端连同任务一起没 | ✅ 任务继续跑,`dtm <容器>` 原样接回 |
| SSH 断线、关掉终端窗口 | ❌ 同上 | ✅ 同上 |
| 切到 CLI 模式(`cli`)释放显存 | ❌ 桌面终端里的活全丢 | ✅ 不受影响 |
| 换个入口继续干(本地↔远程) | ❌ 只能重开、从头来 | ✅ 四个入口同一条命令接回 |

**恢复只需要 CLI** —— 不依赖 VS Code、不依赖图形界面。一条 `ssh` 加一条 `dtm` 就回到现场。

**一个例外:容器重启会丢会话。** tmux server 是容器内的进程,`docker restart` 后
`tmux ls` 报 `no server running`。但两样东西还在:

- **tmux 二进制**(overlay 层保留;容器**重建**才会丢,而启动脚本的 `ensure_tmux` 会自动装回)
- **claude 对话记录**(`~/.claude` 是宿主机 bind mount)→ 重启后 `dtm <容器>` 新建会话,
  `claude -c` 即可接续对话

所以边界是:**tmux 保护你不受"客户端消失"的影响,但保护不了"容器/主机重启"。**
长实验若怕重启,结果要落盘到挂载目录。

### 一句话边界

**只要容器和主机不停机、你自己不 exit,tmux 会话就一直在。**

会话消失只有三种原因:

| 原因 | 说明 | 还剩什么 |
|---|---|---|
| **你自己关掉** | 窗口里敲 `exit` 把所有窗口关完,或 `tmux kill-session -t <名>` | — |
| **容器停止 / 重启** | tmux server 是容器内的进程 | tmux 二进制(overlay)、`~/.claude` 对话记录 |
| **主机重启** | 所有进程终止,`/tmp` 开机清空,socket 一并没了 | 磁盘上的一切 |

除此之外——**关编辑器、断 SSH、拔网线、RDP 掉线、`cli` 切换、换入口**——会话统统还在。

所以日常只要守住一条:**走人按 `Ctrl+b d`,不要敲 `exit`。**



---

## 操作逻辑

```
① 连接 ──▶ ② 建会话/接回 ──▶ ③ 干活 ──▶ ④ 脱离 ──▶ 换任意入口回到 ②
                                          └──▶ ⑤ 结束会话(活干完了)
```

### ① 连接:到达宿主机 shell

| 入口 | 怎么进 |
|---|---|
| 本地 GUI | 桌面开 Terminal |
| 本地 CLI | `Ctrl+Alt+F3` → TTY 登录 |
| 远程 GUI | Windows App → `192.168.10.86:3390`(descfly / <RDP密码>)→ 里面开 Terminal |
| 远程 CLI | `ssh descfly@192.168.10.86` |

**四个入口之后,命令完全相同** —— 这就是入口透明。

### ② 建会话 / 接回(同一条命令)

| 会话在哪 | 建或接 | 列出 | 短暂用(断开即死) |
|---|---|---|---|
| **宿主机** | `tmux new -A -s <名>` | `tmux ls` | 当前 shell 直接敲命令 |
| **容器** | `dtm <容器> [名]` | `dtl <容器>` | `dsh <容器>` |

- `-A` = 有则接回、无则新建 → **建和接是同一条命令**,不用先判断
- `dtm <容器>` 会话名默认 `work`;`dtm <容器> train` 指定名字
- 有哪些容器:`dls`

**会话隔离**:宿主机和每个容器各有独立的 tmux server(socket 分别在
`/tmp/tmux-1000/` 与各容器的 `/tmp/tmux-0/`,`/tmp` 不共享)。
**在哪一层建的,就回哪一层找**,`tmux ls` 只报告当前层。

### ③④⑤ 会话内操作

| 操作 | 按键 / 命令 | 记法 |
|---|---|---|
| **④ 脱离**(任务继续跑,日常用这个) | `Ctrl+b` 然后 `d` | **d**etach |
| **多开窗口** | `Ctrl+b` 然后 `c` | **c**reate |
| **切换窗口** | `Ctrl+b` 然后 `数字` | 状态栏上看得见编号 |
| 切换(其他方式) | `n` 下一个 / `p` 上一个 / `w` 列表选 | **n**ext / **p**rev / **w**indow |
| 窗口改名 | `Ctrl+b` 然后 `,` | — |
| 关当前窗口 | 敲 `exit` | — |
| **⑤ 结束整个会话** | 关完所有窗口,或 `tmux kill-session -t <名>` | — |

所有快捷键都是**先按 `Ctrl+b` 松开,再按第二个键**。

进会话后屏幕最下方是状态栏,左边即窗口列表,带 `*` 的是当前窗口:

```
0:edit  1:build  2:logs*
```

> **脱离 ≠ 退出**:`Ctrl+b d` 走人,任务继续;敲 `exit` 是关窗口,活就没了。日常只用脱离。

### 两个场景

**远程**(RDP 看文档 + SSH 跑实验,并行,不切 CLI):

```bash
ssh descfly@192.168.10.86
dtm MLX_chipyard_dev          # 容器里跑实验
python train.py
# Ctrl+b d                     # 脱离
exit                           # 退出 SSH,实验继续跑
```
同时 Windows App 连 `192.168.10.86:3390` 看文档。两条链路独立,互不影响。

**本地**(随时切换):

```bash
dtm MLX_chipyard_dev          # 和远程 SSH 进的是同一个会话
python train.py
# Ctrl+b d

guistat                        # 要显存时
cli                            # 关图形(本终端一并关闭,正常)
#   → Ctrl+Alt+F3 登录 TTY
dtm MLX_chipyard_dev          # 现场原样还在
gui                            # 完事切回图形,在屏幕前登录
```

> **远程不切 CLI 的原因**:`gnome-remote-desktop` 是用户级服务,`cli` 后随图形会话一起消失;
> `gui` 只能到 GDM 登录界面,而 GDM 自动登录仅开机首次生效,远程无法完成登录 → 3390 回不来。
> 能服务登录界面的 3389 需要 TPM,本机(Supermicro X12DAi-N6)没有。
> 代价仅为保留约 1292 MiB 显存(GPU0 的 5%),换零风险。

### 存活边界

| 事件 | tmux 会话(主机/容器) | 裸终端里的进程 |
|---|---|---|
| SSH 断线 / 关终端 | ✅ | ❌ |
| RDP 断开 | ✅ | ✅(桌面终端还在) |
| `cli` 切换 | ✅ | ❌ |
| **重启** | ❌ 会话丢;容器还需 `docker start` | ❌ |

**铁律:超过一分钟的活,先进 tmux。唯一活不过的是重启。**


## 三个开发容器

| 容器 | 项目目录 | 默认会话名 |
|---|---|---|
| `MLX_chipyard_dev` | `/workspace/MLX_dev` | `work` |
| `AgentSys_dev` | `/workspace/AgentSys` | `work` |
| `GPDPU_dev` | `/workspace/GPDPU` | `work` |

三个容器都已装 tmux,且各自的 `docker/run_project_gpu.sh` 含幂等的 `ensure_tmux`,
**容器重建后会自动装回**。

## 常见问题

#### 重启之后容器不见了

三个开发容器是 `RestartPolicy=no`,重启不会自动恢复:

```bash
docker start MLX_chipyard_dev AgentSys_dev GPDPU_dev
dls                                  # 确认
```

想让它们开机自启:

```bash
docker update --restart unless-stopped MLX_chipyard_dev AgentSys_dev GPDPU_dev
```

#### 接管 VS Code 终端里已有的 claude

VS Code 集成终端属于客户端,CLI 下接不回。改用 tmux 重开:

```bash
dsh MLX_chipyard_dev
pkill -f claude                      # 清掉旧进程,避免同会话两个进程
exit
dtm MLX_chipyard_dev
claude -c                            # ~/.claude 宿主机与容器共享,对话接得上
```

#### dsh 和 dtm 该用哪个

| | `dsh` | `dtm` |
|---|---|---|
| 实质 | `docker exec -it <c> bash -l` | `docker exec -it <c> tmux new-session -A -s work` |
| 断开后进程 | **随终端死** | **继续运行** |
| 能否接回 | ❌ | ✅ 原样回到现场 |
| 适合 | 几秒钟的事、管道重定向到宿主机、一次性装包 | 实验、训练、claude 会话 |

一句话:**要"回来"的用 `dtm`,不打算回来的用 `dsh`。**

#### 多任务分会话

别都挤在默认的 `work` 里:

```bash
dtm MLX_chipyard_dev train      # 训练
python train.py                 # Ctrl+b d
dtm MLX_chipyard_dev logs       # 看日志
tail -f out.log                 # Ctrl+b d
dtl MLX_chipyard_dev            # 查看:train / logs 两个会话
```

#### 容器里没有 d* 命令

`dls` / `dsh` / `dtm` / `dtl` 定义在宿主机 `~/.bashrc`,且用容器判定包裹,**容器内不定义**。
容器里也没有 `docker` 命令(未做 docker-in-docker)。人已经在容器里,直接用 tmux 原生命令:

| 宿主机 | 容器内等价 |
|---|---|
| `dtm <容器>` | `tmux new-session -A -s work` |
| `dtm <容器> train` | `tmux new-session -A -s train` |
| `dtl <容器>` | `tmux ls` |

## 远程 VS Code 直接打开容器

tmux 解决的是"进程留在现场";想在远程机器上**用 VS Code 图形界面编辑容器里的代码**,
走 Remote-SSH 再套一层 Dev Containers 即可,不需要在容器里跑 sshd。

前提(宿主机已满足):`descfly` 在 `docker` 组、sshd 运行中、三个容器在跑(`dls` 确认)。
远程机器的 VS Code 装 **Remote - SSH** 与 **Dev Containers** 两个扩展(或 Remote Development 扩展包)。

### 方案一(推荐):Remote-SSH → Attach 容器

1. `F1` → **Remote-SSH: Connect to Host…** → `descfly@192.168.31.116`(外网走比扬云链路地址)。
   连上后左下角显示 `SSH: 192.168.31.116`。
2. 在该窗口 `F1` → **Dev Containers: Attach to Running Container…** → 选
   `AgentSys_dev` / `MLX_chipyard_dev` / `GPDPU_dev`。
3. VS Code 新开窗口并往容器装 vscode-server,左下角变成 `Container AgentSys_dev (SSH: …)`。
   **File → Open Folder** 输入对应项目目录(见上表 `/workspace/...`)。

也可以在 SSH 窗口侧栏 **Remote Explorer** 切到 *Dev Containers*,直接看到宿主机容器列表右键 attach。

### 方案二:本地 Docker CLI 直连远端 daemon

远程机器要有 docker CLI(不需要 daemon)且到宿主机 SSH 免密。本地 VS Code `settings.json` 加:

```json
"docker.host": "ssh://descfly@192.168.31.116"
```

然后直接 `F1` → **Dev Containers: Attach to Running Container…**。少一层跳转,但要装本地 docker CLI,
SSH 端口非 22 时需写进 `~/.ssh/config`。日常用方案一即可。

### 注意点

| 事项 | 说明 |
|---|---|
| 容器用户 | 容器以 `user=0:1000` 运行,attach 后终端是 root,新建文件属 root。要以自己身份进,在 attach 配置里加 `"remoteUser": "descfly"`(容器内需有此用户) |
| attach 配置位置 | 宿主机 `~/.config/Code/User/globalStorage/ms-vscode-remote.remote-containers/imageConfigs/<镜像名>.json`,可固定 `workspaceFolder` 和默认扩展,下次 attach 自动打开对应目录 |
| 与 tmux 的关系 | VS Code 集成终端仍属客户端,长任务照旧在其中执行 `tmux new-session -A -s work`,断开后进程才不会死 |

## 相关文档

- [开发环境指南](开发环境指南.md) —— 完整的四个入口、VPN 分流栈、网络重置
- `~/server_config/shell/bashrc-container.sh` —— `dls` / `dsh` / `dtm` / `dtl` 的定义
- `~/server_config/container/README.md` —— 容器启动脚本位置与 `ensure_tmux` 改动
