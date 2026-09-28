# Obsidian:常驻服务与看护

Obsidian 在本机不是"桌面应用",而是一个 **systemd 用户服务**。这样做的目的是让
`obsidian` MCP(经 Local REST API 27123)与 Omnisearch HTTP API(51361)在
**CLI 模式下也可用** —— 切到 `multi-user.target` 后没有图形会话,Obsidian 仍然在跑。

## 文件

| 归档 | 部署位置 | 作用 |
| --- | --- | --- |
| `bin/obsidian-managed` | `~/.local/bin/obsidian-managed` | 启动器:**默认 headless (CLI)**;要窗口须显式 `OBSIDIAN_FORCE_GUI=1` |
| `bin/obsidian-rest-watchdog` | `~/.local/bin/obsidian-rest-watchdog` | 看护逻辑本体(判据与参数都在脚本顶部注释里) |
| `systemd/obsidian.service` | `~/.config/systemd/user/` | 常驻服务,`Restart=always`、`StartLimitIntervalSec=0` |
| `systemd/obsidian-rest-watchdog.{service,timer}` | 同上 | 每 60 秒探测;**按"有没有推进"判定,不按时长** |
| `systemd/obsidian-gui-switch.service` | 同上 | 图形会话出现/消失时切换窗口模式(headless 默认后基本不再需要) |

部署后需 `systemctl --user daemon-reload`,并 `systemctl --user enable --now obsidian.service obsidian-rest-watchdog.timer`。
开机即生效需要 `loginctl enable-linger descfly`。

## 为什么会"时不时 error、时不时 OK"(2026-09-23 定位)

症状:MCP 的 `omnisearch` 模式查询间歇性返回 ERROR,过一会儿又正常。

两个原因叠加:

**① 渲染进程被 OOM 杀掉,重启期间接口不可用。**

Omnisearch 把 BM25 索引放在渲染进程的 V8 堆里。本 vault 索引约 150 MB markdown,
多个 MCP 搜索并发时堆会涨得很快。2026-09-22 的内核日志:

```
kernel:  V8Worker invoked oom-killer ... global_oom
systemd: obsidian.service: Failed with result 'oom-kill'
kernel:  Out of memory: Killed process 121476 (cicc) anon-rss:4.8GB
```

注意第三行:**是 Obsidian 触发的全局 OOM,内核转而杀掉了一个 4.8 GB 的 NVCC 编译进程**。
`Restart=always` 会把 Obsidian 拉回来,但那段窗口里接口是死的。

处置:`--max-old-space-size` 由 12288 提到 **32768 MB**(本机 251 GB 物理内存,
常态可用 230 GB 以上)。保留 `OOMScoreAdjust=200`:真到内存紧张时内核优先杀
Obsidian 而不是实验进程 —— Obsidian 能自动重启,实验不能。

**② 51361 比 27123 晚就绪,而 watchdog 只看 27123。**

Obsidian 启动顺序是:主进程 → Local REST API(27123/27124)→ 插件加载 →
Omnisearch 的 HTTP 服务(51361)。所以存在一个**27123 已经 200、51361 还没起**的窗口。
watchdog 原来只探测 27123,在这个窗口里判定"健康",而调用方用 `omnisearch` 模式就拿到 ERROR。

处置:
- ~~watchdog 增加 **180 秒启动宽限期**~~ → **2026-09-28 废弃,见下一节。固定宽限期本身就是后来那次长时间宕机的原因。**
- timer 间隔 20s → **60s**(service 本身最长要跑 18 秒,20 秒太挤)。
- 51361 纳入探测但**只记录、不作为重启依据**:它比 27123 晚就绪,若拿它当重启条件,
  会在索引重建期间反复重启。日志里会出现
  `注意:27123 正常但 Omnisearch 51361 返回 <code>`。

## 两次把 REST API 彻底搞挂的故障(2026-09-28 定位)

症状:27123 **完全不再监听**,不是间歇 ERROR。`systemctl --user status` 显示 `active (running)`,
但整个生命周期只消耗 3 秒 CPU、峰值 200–300 MB(加载完 vault 应为 880 MB+),renderer 进程从不生成。
两个**互相独立**的原因,先后发生。

### ① watchdog 的固定宽限期掐死了健康但慢的冷启动

上一节加的 `GRACE=180` 是个**猜出来的数**。timer 每 60s 探一次,宽限期一满就探测、
两次失败(相隔 10s)即重启 —— 于是**每 ~190 秒重启一轮**。本 vault 冷启动超过这个数,
Obsidian 永远跑不完加载,形成死亡循环(日志特征:`Started` 与 `State 'stop-sigterm' timed out. Killing.`
以 ~190s 为周期反复出现)。

**任何固定时长都会坏两次**:猜短了形成循环;猜长了真崩溃也发现不了(拉到半小时就等于废掉 watchdog);
而且语料一长大,原来够用的数字又不够了。

**处置:判据从"过了多久"改成"有没有在推进"。** 建索引期间 CPU 持续接近满核,
卡死的渲染进程是零 CPU —— 这两者可直接区分,不必知道加载该花多久:

| 情况 | 行为 |
| --- | --- |
| 端口通 | 正常退出(51361 未就绪只记录) |
| 端口不通,但 10s 探测间隔内 CPU 增长 ≥0.5s | **判为正在加载/建索引 → 永不重启,不管持续多久** |
| 端口不通且几乎无 CPU 增长 | 累计 strike,**连续 3 轮**才重启 |
| 最近一小时已重启 3 次 | **只告警、不再重启** —— 这条上限让重启循环在结构上不可能出现 |

状态存放在 `$XDG_RUNTIME_DIR/obsidian-rest-watchdog.state`。逻辑已从单行 `ExecStart`
移进 `bin/obsidian-rest-watchdog`(原来那条转义嵌套的单行 shell 无法维护)。

### ② headless 启动遇上活着的 GNOME 会话会卡死

**这是把默认改成 CLI/headless 优先时引入的。** 原逻辑"有图形会话→开窗口,没有→headless"
使模式与环境始终一致:**headless 只会在没有会话变量的场合运行**。

而桌面会话会通过 `systemctl --user import-environment` 把自己的变量注入 systemd user manager。
于是由 systemd 启动的 headless Obsidian 仍然看到 `SESSION_MANAGER`(X11 XSMP 会话管理器地址),
而 `DISPLAY` 已被 unset —— 它去连接会话管理器,然后**阻塞在 `do_poll`**:renderer 永不生成,
端口永不监听。同一个启动脚本**从交互 shell 跑却 10 秒就绪**,因为 shell 里没有这些变量 ——
这是 systemd 启动与手动启动之间唯一的实质差异。

**处置:headless 分支 scrub 整套桌面会话变量,不只是 display 三个:**

```
SESSION_MANAGER  XDG_CURRENT_DESKTOP  XDG_SESSION_DESKTOP  DESKTOP_SESSION
GDMSESSION  GNOME_DESKTOP_SESSION_ID  GNOME_SHELL_SESSION_MODE
GNOME_SETUP_DISPLAY  GTK_MODULES  QT_ACCESSIBILITY  IM_CONFIG_PHASE
```

改完 systemd 下 **3 秒**达到 `27123 = 200`。要窗口时仍可 `OBSIDIAN_FORCE_GUI=1`。

### 为什么默认改成 headless

1. 这个服务只为 MCP 提供 REST API,**窗口没有人看**;
2. 窗口模式把 GPU/合成器拉进依赖链(本机会打 `vaInitialize failed: unknown libva error`),纯属多出来的故障面;
3. 宿主切到 `multi-user.target` 时图形会话消失,窗口模式会在重启后换模式,headless 不受影响;
4. **确定性**:每次同一种模式,行为不再取决于启动时机是否恰好有图形会话。

### 排除掉的假设(每条都有测量,避免以后重复排查)

GUI vs headless 模式(**两种在 systemd 下都卡**)、`--max-old-space-size` 4096 vs 32768
(手动测**都正常**)、Chromium `Singleton*` 锁残留(清干净仍卡)、网络与代理
(shell 与 `systemd-run --user` 临时单元访问 GitHub **都是 200**)、资源限制
(fd/进程数/地址空间**完全一致**)、`obsidian-1.13.7.asar` 覆盖 1.12.7 AppImage 的版本错位
(移开 asar 跑原生 1.12.7 **仍卡**)、stdout 走 journald(`StandardOutput=null` 无效)、
unit 自身的 `Type`/`KillMode`/`Restart`(**默认设置的临时单元一样卡**)。

**定位的关键一步**:用 `systemd-run --user` 起同一个脚本 → 卡;从 shell 起同一个脚本 → 10 秒就绪。
这把范围从"脚本/参数/应用版本"一次性锁到"环境差异"上,随后完整 diff 环境变量即命中。

## 排查顺序

```bash
export XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus

# ① 服务在不在,起来多久了(刚重启过就等 1~3 分钟让 Omnisearch 建完索引)
systemctl --user status obsidian.service --no-pager | head -5

# ② 两个接口分别通不通 —— 27123 通而 51361 不通,说明插件还在加载
curl -s -o /dev/null -w '27123=%{http_code}\n' http://127.0.0.1:27123/
curl -s -o /dev/null -w '51361=%{http_code}\n' 'http://127.0.0.1:51361/search?q=healthcheck'

# ③ 是否被 OOM 杀过
journalctl --since -24h | grep -iE 'oom-kill|invoked oom-killer'

# ④ watchdog 做了什么
journalctl --user -u obsidian-rest-watchdog --since -1h --no-pager

# ⑤ 端口不通时，先分清「在建索引」还是「卡死」——这决定要不要动它
#    在建索引:CPU 接近满核、RSS 往 1GB+ 涨;卡死:CPU ~0、RSS 停在 200-300MB
ps -o pcpu=,rss= -C obsidian --no-headers | awk '{c+=$1;r+=$2} END {printf "%%CPU=%.0f RSS=%.2fGB\n", c, r/1048576}'
systemctl --user show obsidian.service -p CPUUsageNSec --value   # 只有几秒 = 从没真正启动起来
pgrep -cf 'type=renderer'                                        # 0 = renderer 没生成，属②类卡死

# ⑥ 若确认是②类卡死（renderer=0 且 CPU 不涨），先确认 headless 分支有没有 scrub 会话变量
tr '\0' '\n' < /proc/$(systemctl --user show obsidian.service -p MainPID --value)/environ \
  | grep -E '^(SESSION_MANAGER|XDG_CURRENT_DESKTOP|GNOME_)' && echo "会话变量泄漏 —— 见上一节②"
```

## 索引范围

`.obsidian/app.json` 的 `userIgnoreFilters` 采用**白名单**思路:只保留
`paper_secs`、`knowledge_notes`、`experiment_notes`、`idea_notes`、`human_notes`、
`review_notes`,其余顶层目录全部排除(约 18900 个 md / 150 MB)。
Omnisearch 侧关闭了 PDF、图片、Office 索引。

改动 `userIgnoreFilters` 会触发 Omnisearch 全量重建索引,期间内存占用明显上升 ——
这也是上述 OOM 的诱因之一。改完请在空闲时段重启 Obsidian,不要在跑实验时改。
