#!/usr/bin/env bash
# 给 /etc/fstab 的数据盘加 nofail(与可选的 x-systemd.device-timeout)。
#
# 为什么必须加:三个数据盘都是 `defaults`,都 RequiredBy=local-fs.target。
# 任一盘挂载失败 → local-fs.target 失败 → 系统进 emergency.target
# → 无网络、无 SSH、无 RDP,只能到机器跟前输 root 密码。
# 放大因素:
#   · /data1 与 /data3 在同一块物理盘(sda1 / sda2),一块盘坏两个挂载点同时失败
#   · /data3 是 pass=2,14T ext4 开机 fsck 很久;检查失败直接进 emergency
#   · Docker 的 overlay2 在 /data3 上 —— 它挂不上,edge 容器起不来,隧道也没了
#
# 加了 nofail 不能让坏盘变好,但能保证"坏盘"不升级成"整机远程够不着"——
# 这是 watchdog 的 L4 自动重启能作为救援手段的前提。
#
# 安全措施:改前备份、用 findmnt --verify 校验、校验不过自动回滚。
set -Eeuo pipefail
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }

FSTAB=/etc/fstab
TARGETS="${FSTAB_TARGETS:-/data1 /data2 /data3}"
# 设备迟迟不出现时不要无限等待(默认 90s)。留空则不添加此项。
DEVTIMEOUT="${FSTAB_DEVICE_TIMEOUT:-10s}"
ts="$(date +%Y%m%d-%H%M%S)"
BAK="$FSTAB.bak.nofail-$ts"

echo "[1/5] 备份"
cp -a "$FSTAB" "$BAK"
echo "  → $BAK"

echo "[2/5] 改前的相关行"
for m in $TARGETS; do
  awk -v m="$m" '$1 !~ /^#/ && $2==m {printf "  %s\n",$0}' "$FSTAB"
done

echo "[3/5] 加 nofail${DEVTIMEOUT:+ 与 x-systemd.device-timeout=$DEVTIMEOUT}"
python3 - "$FSTAB" "$DEVTIMEOUT" $TARGETS <<'PYADD'
import sys
fstab, devto = sys.argv[1], sys.argv[2]
targets = set(sys.argv[3:])
out, changed = [], 0
for line in open(fstab).read().splitlines(True):
    raw = line.rstrip("\n")
    if raw.strip().startswith("#") or not raw.strip():
        out.append(line); continue
    f = raw.split()
    if len(f) < 4 or f[1] not in targets:
        out.append(line); continue
    opts = [o for o in f[3].split(",") if o]
    add = []
    if "nofail" not in opts: add.append("nofail")
    if devto and not any(o.startswith("x-systemd.device-timeout=") for o in opts):
        add.append("x-systemd.device-timeout=" + devto)
    if not add:
        print("  %s 已有 nofail,跳过" % f[1]); out.append(line); continue
    # defaults 保留:它和 nofail 并不冲突,去掉反而会改变 rw/suid/exec 等默认值
    f[3] = ",".join(opts + add)
    out.append("\t".join(f) + "\n")
    changed += 1
    print("  %s 追加 %s" % (f[1], ",".join(add)))
open(fstab, "w").writelines(out)
print("  共修改 %d 行" % changed)
PYADD

echo "[4/5] 校验(不通过立即回滚)"
if findmnt --verify --verbose 2>&1 | tail -20 | sed 's/^/  /'; then :; fi
if ! findmnt --verify >/dev/null 2>&1; then
  echo "  x findmnt --verify 报错 → 回滚"
  cp -a "$BAK" "$FSTAB"
  echo "  已恢复 $FSTAB,请人工检查"
  exit 1
fi
echo "  findmnt --verify 通过"
systemctl daemon-reload
echo "  已 daemon-reload(重新生成 .mount 单元)"

echo "[5/5] 结果"
for m in $TARGETS; do
  awk -v m="$m" '$1 !~ /^#/ && $2==m {printf "  %s\n",$0}' "$FSTAB"
done
echo
echo "  当前挂载状态(应全部未变):"
for m in $TARGETS; do
  printf '    %-8s %s\n' "$m" "$(findmnt -n -o SOURCE,FSTYPE "$m" 2>/dev/null || echo 未挂载)"
done
echo
echo "-- 说明 --"
echo "  · 本次只改 fstab 的挂载【选项】,不动任何已挂载的文件系统,无需重启"
echo "  · nofail 在下次开机(或 systemctl daemon-reload 后重新挂载)时才体现效果"
echo "  · 回滚:sudo cp -a $BAK /etc/fstab && sudo systemctl daemon-reload"
echo "  · /data3 若想跳过开机 fsck,可把第 6 列 pass 由 2 改成 0 —— 但那会让文件系统"
echo "    错误长期积累不被发现,不建议;更好的做法是保留 fsck、靠 nofail 兜住失败后果"
