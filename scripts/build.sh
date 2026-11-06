#!/bin/bash
# ftllm-fnos 构建脚本
# 流程: 包内运行时（上游 1.9.0 一体包）→ 图标 → 入口前缀断言 → 隐私扫描 → fnpack 出 .fpk
#
# 1.8.x 及更早：包里只放 wheels（约 200MB），首启用系统 python 建 venv；
# 1.9.0 起上游改发「一体包」，自带 Python 运行时与全部依赖。
# 本脚本要求 fnpack/app/portable/ 已就位（scripts/prep-portable.sh 负责从一体包铺好并裁剪），
# 出包时运行时随包发布，装机即用，首启不再联网、不再建 venv。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FP_BIN="$ROOT/scripts/fnpack-1.2.3-linux-amd64"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
echo "═══ 构建 ftllm v$VERSION ═══"

APP="$ROOT/fnpack/app"
PORTABLE="$APP/portable"

# ── 1) 包内运行时（portable，来自上游一体包）──
echo "[1/5] 检查包内运行时 ..."
if [ ! -x "$PORTABLE/ftllm" ]; then
  echo "✗ 缺少 $PORTABLE/ftllm"
  echo "  先跑：bash scripts/prep-portable.sh <解包后的一体包目录>"
  exit 1
fi
PV="$("$PORTABLE/ftllm" --version 2>&1 | tail -1)"
echo "  运行时 $PV / $(du -sh "$PORTABLE" | cut -f1)"
case "$PV" in
  *"ftllm version: 1.9.0"*) ;;
  *) echo "✗ 包内 ftllm 版本不是 1.9.0：$PV"; exit 1 ;;
esac
# Electron 桌面端（GUI）不进包：fnOS 只走网页启动器，省 300MB+
if [ -e "$PORTABLE/Fastllm-Launcher" ] || [ -e "$PORTABLE/support/FastLLM-Launcher.bin" ]; then
  echo "✗ 包内仍含 Electron 桌面端，请重跑 prep-portable.sh 裁剪"; exit 1
fi

# ── 2) 图标（官方源图 assets/ftllm-icon.png → 256/64）──
echo "[2/5] 生成图标 ..."
SRC_ICON="$ROOT/assets/ftllm-icon.png"
ffmpeg -y -v error -i "$SRC_ICON" -vf "scale=256:256:flags=lanczos" "$APP/ui/images/icon_256.png"
ffmpeg -y -v error -i "$SRC_ICON" -vf "scale=64:64:flags=lanczos"   "$APP/ui/images/icon_64.png"
cp "$APP/ui/images/icon_256.png" "$ROOT/fnpack/ICON.PNG"
cp "$APP/ui/images/icon_256.png" "$ROOT/fnpack/ICON_256.PNG"
# 图标权限：fnOS 应用中心以组身份读取 ICON.PNG，组无读权限（如 705）会静默退回默认占位图。
# 2026-10-25 发现 ftllm 历史包的 ICON 全是 705，与 freellmapi/strata 同一个坑。
chmod 644 "$ROOT/fnpack/ICON.PNG" "$ROOT/fnpack/ICON_256.PNG" "$APP/ui/images/icon_256.png" "$APP/ui/images/icon_64.png" 2>/dev/null || true

# ── 3) 入口前缀断言（手机端走 /app/<appname>/ 网关前缀）──
# 桌面图标与应用中心是直连 service_port，但手机端应用中心走 nginx 网关前缀 /app/<appname>/，
# 自研 HTTP 入口（本应用是 supervisor.py）必须认这个前缀，否则手机端 404 页面刷不出来。
# 2026-10-25 真实事故：ftllm 手机端打不开，根因就是 do_GET 只认 "/" 和 "/index.html"。
echo "[3/5] 入口前缀断言 ..."
APPNAME="$(sed -n 's/^appname[[:space:]]*=[[:space:]]*//p' "$ROOT/fnpack/manifest" | head -1 | tr -d '[:space:]')"
ENTRY_PY="$ROOT/fnpack/app/supervisor.py"
PATTERN="path.startswith(\"/app/$APPNAME"
if ! grep -qF "$PATTERN" "$ENTRY_PY"; then
  echo "✗ $ENTRY_PY 没有处理 /app/$APPNAME 前缀 —— 手机端应用中心会 404"
  exit 1
fi
echo "  ✓ 入口认 /app/$APPNAME 前缀"

# ── 4) 隐私扫描（只扫自产文件；portable 是上游二进制不扫）──
echo "[4/5] 隐私扫描 ..."
if grep -rn -e '/vol[0-9]\+/\(work\|soft\)' -e '@app\(center\|data\)' \
     "$ROOT/fnpack/cmd" "$ROOT/fnpack/config" "$ROOT/fnpack/app/supervisor.py" \
     "$ROOT/fnpack/manifest" "$ROOT/README.md" 2>/dev/null | head -5 | grep -q .; then
  echo "✗ 自产文件泄漏本机路径，中止"; exit 1
fi
if grep -rn -e 'sk-[A-Za-z0-9]\{20,\}' -e 'ghp_[A-Za-z0-9]\{20,\}' \
     "$ROOT/fnpack/app/supervisor.py" "$ROOT/fnpack/cmd/main" 2>/dev/null | head -5 | grep -q .; then
  echo "✗ 自产文件疑似泄漏密钥，中止"; exit 1
fi

# ── 5) fnpack ──
echo "[5/5] fnpack 打包 ..."
# 打包前清字节码：本地验证时跑过运行时，site-packages 与标准库会生成 __pycache__/*.pyc。
# 这些不是上游发行物，不该进包（也避免不同机器上打出的包不一致）。
find "$APP" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
find "$APP" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete 2>/dev/null || true
JUNK="$(find "$APP" -type f \( -name '*.pyc' -o -name '*.pyo' \) | wc -l)"
[ "$JUNK" -eq 0 ] || { echo "✗ 包内仍有 $JUNK 个 .pyc，拒绝打包"; exit 1; }
sed -i "s/^version .*=.*/version               = $VERSION/" "$ROOT/fnpack/manifest"
mkdir -p "$ROOT/dist"
cd "$ROOT/fnpack"
"$FP_BIN" build
mv -f ftllm.fpk "$ROOT/dist/ftllm_v${VERSION}_x86.fpk"
# 出包后硬断言：图标必须 644（否则应用中心显示占位图，与 frellmapi/strata 同一个坑）
CHK="$(mktemp -d)"
tar -xzf "$ROOT/dist/ftllm_v${VERSION}_x86.fpk" -C "$CHK" ICON.PNG ICON_256.PNG 2>/dev/null || true
for ic in ICON.PNG ICON_256.PNG; do
  m="$(stat -c '%a' "$CHK/$ic" 2>/dev/null || echo MISSING)"
  [ "$m" = "644" ] || { echo "✗ $ic 权限=$m（必须 644，否则应用中心显示占位图）"; rm -rf "$CHK"; exit 1; }
done
rm -rf "$CHK"
echo "  ✓ 图标权限 644 断言通过"

# 出包后核对包内实物：不只信源码，防止 fnpack 打进旧文件
SUP="$(mktemp)"
tar -xzOf "$ROOT/dist/ftllm_v${VERSION}_x86.fpk" app.tgz | tar -xzOf - supervisor.py > "$SUP" 2>/dev/null || true
if ! grep -qF "$PATTERN" "$SUP"; then
  echo "✗ 包内 supervisor.py 不含 /app/$APPNAME 前缀处理，拒绝出包"
  rm -f "$SUP"; exit 1
fi
rm -f "$SUP"
echo "  ✓ 包内 supervisor.py 已含前缀处理"
# 包内必须自带运行时，且不得回退成「安装时建 venv」的老路
# 注意：这里先把清单落到临时文件再 grep。直接 `tar | tar -tzf - | grep -q` 在 set -o pipefail 下
# 会因 grep 提前退出导致上游 tar 收 SIGPIPE（141），把正确的包判成失败。
LIST="$(mktemp)"
tar -xzOf "$ROOT/dist/ftllm_v${VERSION}_x86.fpk" app.tgz | tar -tzf - > "$LIST"
if ! grep -qx "portable/ftllm" "$LIST"; then
  echo "✗ 包内缺少 portable/ftllm（运行时没进包）"; rm -f "$LIST"; exit 1
fi
echo "  ✓ 包内 portable/ftllm 已随包发布（$(grep -c "^portable/" "$LIST") 个运行时条目）"
# 修复断言：libnccl.so.2 必须落在 LD_LIBRARY_PATH 内的 runtime/lib（否则 CUDA 核心库静默降级 CPU）
if ! grep -qx "portable/support/runtime/lib/libnccl.so.2" "$LIST"; then
  echo "✗ 包内缺 portable/support/runtime/lib/libnccl.so.2 —— 面板选 cuda 会静默跑 CPU"; rm -f "$LIST"; exit 1
fi
echo "  ✓ 包内 libnccl.so.2 就位"
if grep -q "^wheels/" "$LIST"; then
  echo "✗ 包内仍有 wheels/（1.9.0 起不再用离线 wheel 建 venv）"; rm -f "$LIST"; exit 1
fi
rm -f "$LIST"
echo "  ✓ 包内无 wheels/ 残留"
ls -lh "$ROOT/dist/" | tail -3
echo "═══ 完成 ═══"
