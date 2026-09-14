# >>> 开发容器快捷入口 (仅宿主机) >>>
if [ ! -f /.dockerenv ] && ! grep -qE 'docker|containerd|kubepods' /proc/1/cgroup 2>/dev/null; then

  # 列出开发容器
  dls() { docker ps --format '{{.Names}}\t{{.Status}}' | grep -vE 'paper-analysis|beyond' | column -t; }

  # 进容器普通 shell:  dsh MLX_chipyard_dev
  dsh() { [ -n "$1" ] || { echo "用法: dsh <容器>"; dls; return 1; }; docker exec -it "$1" bash -l; }

  # 进容器 tmux(有则接回, 无则新建):  dtm AgentSys_dev [会话名]
  dtm() {
    [ -n "$1" ] || { echo "用法: dtm <容器> [会话名, 默认 work]"; dls; return 1; }
    docker exec -it "$1" tmux new-session -A -s "${2:-work}"
  }

  # 看容器里有哪些 tmux 会话:  dtl GPDPU_dev
  dtl() { [ -n "$1" ] || { echo "用法: dtl <容器>"; return 1; }; docker exec "$1" tmux ls 2>/dev/null || echo "无 tmux 会话"; }
fi
# <<< 开发容器快捷入口 <<<
