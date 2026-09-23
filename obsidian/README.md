# Obsidian:常驻服务与看护

Obsidian 在本机不是"桌面应用",而是一个 **systemd 用户服务**。这样做的目的是让
`obsidian` MCP(经 Local REST API 27123)与 Omnisearch HTTP API(51361)在
**CLI 模式下也可用** —— 切到 `multi-user.target` 后没有图形会话,Obsidian 仍然在跑。

## 文件

| 归档 | 部署位置 | 作用 |
| --- | --- | --- |
| `bin/obsidian-managed` | `~/.local/bin/obsidian-managed` | 启动器:有图形会话就开窗口,没有就用 Chromium ozone headless |
| `systemd/obsidian.service` | `~/.config/systemd/user/` | 常驻服务,`Restart=always`、`StartLimitIntervalSec=0` |
| `systemd/obsidian-rest-watchdog.{service,timer}` | 同上 | 每 60 秒探测 27123,连续两次失败才重启 Obsidian |
| `systemd/obsidian-gui-switch.service` | 同上 | 图形会话出现/消失时切换窗口模式 |

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
- watchdog 增加 **180 秒启动宽限期** —— `obsidian.service` 启动不足 180 秒时一律不探测。
  原来没有宽限期,watchdog 可能在 Obsidian 还没加载完插件时再把它掐一次,形成重启循环。
- timer 间隔 20s → **60s**(service 本身最长要跑 18 秒,20 秒太挤)。
- 51361 纳入探测但**只记录、不作为重启依据**:它比 27123 晚就绪,若拿它当重启条件,
  会在索引重建期间反复重启。日志里会出现
  `注意:27123 正常但 Omnisearch 51361 返回 <code>`。

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
```

## 索引范围

`.obsidian/app.json` 的 `userIgnoreFilters` 采用**白名单**思路:只保留
`paper_secs`、`knowledge_notes`、`experiment_notes`、`idea_notes`、`human_notes`、
`review_notes`,其余顶层目录全部排除(约 18900 个 md / 150 MB)。
Omnisearch 侧关闭了 PDF、图片、Office 索引。

改动 `userIgnoreFilters` 会触发 Omnisearch 全量重建索引,期间内存占用明显上升 ——
这也是上述 OOM 的诱因之一。改完请在空闲时段重启 Obsidian,不要在跑实验时改。
