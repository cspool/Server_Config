# >>> 图形/CLI 模式快捷切换 (仅宿主机生效, 容器内不定义) >>>
if [ ! -f /.dockerenv ] && ! grep -qE 'docker|containerd|kubepods' /proc/1/cgroup 2>/dev/null; then

  # 退到 CLI: 停 gdm/Xorg/gnome-shell/桌面共享, 释放显存
  # 不影响: SSH、mihomo(系统服务)、Docker 容器、openvpn3
  cli() {
    local used
    used=$(nvidia-smi --query-gpu=index,memory.used --format=csv,noheader 2>/dev/null | tr '\n' ' ')
    echo "即将停止图形会话, 释放显存: ${used:-未知}"
    echo "  终止: gdm / Xorg / gnome-shell / 桌面共享(3390) / 桌面内所有程序"
    echo "  保留: SSH / mihomo / Docker 容器 / openvpn3"
    if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
      echo "  ⚠ 你正在图形会话的终端里, 执行后本窗口会一起关闭(请改用 SSH)"
    fi
    local a; read -r -p "确认退到 CLI? [y/N] " a
    case "$a" in [yY]) sudo systemctl isolate multi-user.target ;; *) echo "已取消"; return 1 ;; esac
  }

  # 回到图形模式(登录后桌面共享 3390 自动恢复)
  gui() {
    sudo systemctl isolate graphical.target && echo "已切到图形模式, 请在本机登录; 桌面共享(3390)随会话自动启动"
  }

  # 查看当前模式与显存
  guistat() {
    printf '默认 target : %s\n' "$(systemctl get-default)"
    printf 'gdm         : %s\n' "$(systemctl is-active gdm3 2>/dev/null)"
    printf 'mihomo      : %s\n' "$(systemctl is-active mihomo 2>/dev/null)"
    printf '显存        : %s\n' "$(nvidia-smi --query-gpu=index,memory.used --format=csv,noheader 2>/dev/null | tr '\n' ' ')"
  }

  # 永久默认(重启后生效)
  alias cli-default='sudo systemctl set-default multi-user.target && systemctl get-default'
  alias gui-default='sudo systemctl set-default graphical.target && systemctl get-default'
fi
# <<< 图形/CLI 模式快捷切换 <<<
