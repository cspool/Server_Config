# sudoers 片段

## gui-cli-switch

让 `cli` / `gui` 切换图形与命令行模式时不再询问 sudo 密码。
只放行三条精确命令,不能提权到 shell,也改不了系统配置。

安装:

```bash
sudo install -m 0440 sudoers/gui-cli-switch /etc/sudoers.d/gui-cli-switch
sudo visudo -c -f /etc/sudoers.d/gui-cli-switch      # 必须显示 parsed OK
```

验证(不执行,只测匹配):

```bash
sudo -n -l /usr/bin/systemctl isolate multi-user.target
sudo -n -l /usr/bin/systemctl isolate graphical.target
sudo -n -l /usr/bin/systemctl restart gdm3
```

**sudoers 是精确匹配整条命令** —— 多一个参数(如 `--dry-run`)就不匹配,会退回询问密码。
这是设计如此,不是配置错误。
