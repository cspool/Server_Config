# 容器启动脚本(不复制,指向源仓库)

这些文件在各自项目的 git 仓库内维护,此处只记录位置与改动点,避免双份漂移。

| 项目 | 路径 | 默认容器名 |
|---|---|---|
| MLX_dev | `/data3/Projects/MLX_dev/docker/run_project_gpu.sh` | `MLX_chipyard_dev` |
| AgentSys | `/data3/Projects/AgentSys/docker/run_project_gpu.sh` | `AgentSys_dev` |
| GPDPU | `/data3/Projects/GPDPU/docker/run_project_gpu.sh` | `GPDPU_dev` |

生成器 skill:`project-docker-runner`。

⚠ **这个 skill 存在两份副本,分别被不同客户端加载,必须同步:**

| 路径 | 被谁加载 |
|---|---|
| `~/.codex/skills/project-docker-runner/` | Codex(`codex`、`paper_codex`) |
| `~/.claude/skills/project-docker-runner/` | Claude Code(`/project-docker-runner`) |

每份内含:

| 文件 | 作用 |
|---|---|
| `references/run_project_gpu.sh.template` | 启动脚本模板 |
| `scripts/create_project_gpu_runner.py` | 生成器 |
| `SKILL.md` | 契约说明,**第 13 条为 tmux** |
| `references/startup-contract.md` | 挂载、权限、容器 PATH 的速查 |

改其中一份后立即镜像到另一份:

```bash
rsync -a --delete --exclude='*.bak.*' \
  ~/.codex/skills/project-docker-runner/ \
  ~/.claude/skills/project-docker-runner/
diff -r --exclude='*.bak.*' \
  ~/.codex/skills/project-docker-runner \
  ~/.claude/skills/project-docker-runner && echo in-sync
```

容器内 tmux 的**操作**方法(接回、脱离、多窗口、什么能活过什么)见
[`../docs/tmux实验操作说明.md`](../docs/tmux实验操作说明.md);此处只记录**启动器如何把 tmux 装进容器**。

## 2026-09-14 的改动

四个文件(模板 + 三个启动脚本)都加入了幂等的 `ensure_tmux`:

```bash
ensure_tmux() {
  command -v tmux >/dev/null 2>&1 && return 0
  [ "$(id -u)" = "0" ] || return 1
  command -v apt-get >/dev/null 2>&1 || return 1
  apt-get update -qq && apt-get install -y --no-install-recommends tmux
  hash -r
}
```

插在 `ensure_npm_cli … claude` 之后、`fix_host_shared_permissions_once` 之前。
备份为各自目录下的 `*.bak.tmux-<时间戳>`。

## 2026-09-24 的修复:两份 skill 副本脱节

发现 `~/.claude/skills/project-docker-runner/` 还停在 2026-09-10 的版本 ——
**整个第 9~13 条都不存在**(官方 API 默认、状态栏、Paper Analysis MCP 挂载、
`.claude.json` 处理、tmux),模板也是旧的 24833 字节版,`tmux` 出现 0 次。
也就是说通过 Claude Code 的 `/project-docker-runner` 生成出来的启动脚本
**不会装 tmux**,而通过 Codex 生成的会 —— 同一个 skill,两种结果。

原因:本文件此前只登记了 `~/.codex/` 那一份,`~/.claude/` 的存在没有被记录,
于是每次更新都只改了前者。

处置:以 `~/.codex/` 为准做了全量同步(旧版已备份为
`~/.claude/skills/project-docker-runner.bak.<时间戳>.tgz`),并在两份 SKILL.md
末尾加了"Installed copies — keep in sync"一节,把镜像命令写在编辑者看得到的地方。

同步后已校验:两份逐文件一致;模板中的 tmux 段落与三个线上启动器
(`MLX_dev` / `AgentSys` / `GPDPU`)逐字相同。

## 2026-09-24 的修复:tmux 里丢失 bypass 模式

新建的 `SWHWyard_dev` 容器里直接输入 `claude` 没有进入 bypass 模式。

**根因**:容器内的 bypass 是靠 `~/.bashrc` 里的 alias 实现的

```bash
_claude_with_host_permissions() { command claude --dangerously-skip-permissions "$@"; ... }
alias claude='_claude_with_host_permissions'
```

而 alias 只对**交互式非登录** shell 生效。**登录** shell 按顺序读
`~/.bash_profile` → `~/.bash_login` → `~/.profile`,**不读 `~/.bashrc`**;
而启动器播种的容器私有 home 里这三个文件一个都没有。`tmux` 起的正是登录 shell,
所以 SKILL.md 第 13 条推荐的 `docker exec -it <c> tmux new-session -A -s work`
反而会**静默丢掉 bypass** —— 同一个 `claude`,在 `docker exec -it … bash` 里有,
在 tmux 里没有。

实测(修复前,`SWHWyard_dev`):

| 入口 | alias |
|---|---|
| `bash -i` | ✓ 存在 |
| `bash -l` | ✗ 缺失 |
| `bash -li` | ✗ 缺失 |
| tmux 会话 | ✗ 缺失 |

**处置**:启动器新增 `write_container_user_profile`,在容器 home 写一个 `.profile`
把两条链接起来:

```bash
if [ -n "$BASH_VERSION" ] && [ -f "$HOME/.bashrc" ]; then
  . "$HOME/.bashrc"
fi
```

改动落在 5 个文件:模板 + 四个线上启动器(`MLX_dev`、`AgentSys`、`GPDPU`、`SWHWyard`),
各自备份为 `*.bak.profile-<时间戳>`,全部 `bash -n` 通过。两份 SKILL.md 的第 8 条
也一并改写:明确"容器默认 bypass 是与宿主机有意不同的行为",并说明必须同时写
`.profile`,否则第 13 条的 tmux 工作流会与第 8 条互相矛盾。

修复后验证矩阵:

| 容器 | `bash -i` | `bash -l` | tmux |
|---|---|---|---|
| SWHWyard_dev | ✓ | ✓ | ✓ |
| MLX_chipyard_dev | ✓ | ✓ | ✓ |
| AgentSys_dev | ✓ | ✓ | ✓ |
| GPDPU_dev | (exited,下次启动时由启动器生成) | | |

非交互 shell(`bash -c`、脚本)仍然不带 alias —— 这是正确的,脚本不应受 alias 影响。

自检命令:

```bash
docker exec -i <container> bash -l -c 'alias claude'   # 应输出 _claude_with_host_permissions
docker exec -i <container> bash -i -c 'alias claude'
```

