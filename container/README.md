# 容器启动脚本(不复制,指向源仓库)

这些文件在各自项目的 git 仓库内维护,此处只记录位置与改动点,避免双份漂移。

| 项目 | 路径 | 默认容器名 |
|---|---|---|
| MLX_dev | `/data3/Projects/MLX_dev/docker/run_project_gpu.sh` | `MLX_chipyard_dev` |
| AgentSys | `/data3/Projects/AgentSys/docker/run_project_gpu.sh` | `AgentSys_dev` |
| GPDPU | `/data3/Projects/GPDPU/docker/run_project_gpu.sh` | `GPDPU_dev` |

生成器(codex skill):

| 文件 | 路径 |
|---|---|
| 模板 | `~/.codex/skills/project-docker-runner/references/run_project_gpu.sh.template` |
| 生成器 | `~/.codex/skills/project-docker-runner/scripts/create_project_gpu_runner.py` |
| 说明 | `~/.codex/skills/project-docker-runner/SKILL.md`(第 13 条为 tmux 契约) |

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
