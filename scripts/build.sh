#!/bin/bash
# ftllm-fnos 构建脚本
# 流程: 离线 wheel 集 → 图标 → 隐私扫描 → fnpack 出 .fpk
# 包内不含 venv（解压版 557MB），改为带 wheels（约 200MB）+ 首启离线建 venv
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FP_BIN="$ROOT/scripts/fnpack-1.2.3-linux-amd64"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
echo "═══ 构建 ftllm v$VERSION ═══"

APP="$ROOT/fnpack/app"
WHEELS="$APP/wheels"

# ── 1) 离线 wheel 集（vendor/wheels 为本地缓存，不入 git）──
echo "[1/4] 准备离线 wheels ..."
SRC_WHEELS="$ROOT/vendor/wheels"
if [ ! -d "$SRC_WHEELS" ] || [ -z "$(ls -A "$SRC_WHEELS" 2>/dev/null)" ]; then
  echo "✗ 缺少 vendor/wheels。先取一次："
  echo "  pip download -d vendor/wheels --no-deps ftllm==<ver> && \\"
  echo "  pip download -d vendor/wheels uvicorn fastapi requests"
  exit 1
fi
rm -rf "$WHEELS"; mkdir -p "$WHEELS"
cp "$SRC_WHEELS"/*.whl "$WHEELS"/
n=$(ls "$WHEELS"/*.whl | wc -l)
echo "  wheels $(du -sh "$WHEELS" | cut -f1) / $n 个"
for bad in nvidia triton torch; do
  if ls "$WHEELS" | grep -qi "$bad"; then echo "✗ 包内不应含 $bad（环保依赖，不许进包）"; exit 1; fi
done

# ── 2) 图标（官方源图 assets/ftllm-icon.png → 256/64）──
echo "[2/4] 生成图标 ..."
SRC_ICON="$ROOT/assets/ftllm-icon.png"
ffmpeg -y -v error -i "$SRC_ICON" -vf "scale=256:256:flags=lanczos" "$APP/ui/images/icon_256.png"
ffmpeg -y -v error -i "$SRC_ICON" -vf "scale=64:64:flags=lanczos"   "$APP/ui/images/icon_64.png"
cp "$APP/ui/images/icon_256.png" "$ROOT/fnpack/ICON.PNG"
cp "$APP/ui/images/icon_256.png" "$ROOT/fnpack/ICON_256.PNG"

# ── 3) 隐私扫描（只扫自产文件；wheels 是上游二进制不扫）──
echo "[3/4] 隐私扫描 ..."
if grep -rn -e '/vol[0-9]\+/\(work\|soft\)' -e '@app\(center\|data\)' \
     "$ROOT/fnpack/cmd" "$ROOT/fnpack/config" "$ROOT/fnpack/app/supervisor.py" \
     "$ROOT/fnpack/app/ensure_venv.py" "$ROOT/fnpack/manifest" "$ROOT/README.md" 2>/dev/null | head -5 | grep -q .; then
  echo "✗ 自产文件泄漏本机路径，中止"; exit 1
fi
if grep -rn -e 'sk-[A-Za-z0-9]\{20,\}' -e 'ghp_[A-Za-z0-9]\{20,\}' \
     "$ROOT/fnpack/app/supervisor.py" "$ROOT/fnpack/app/ensure_venv.py" "$ROOT/fnpack/cmd/main" 2>/dev/null | head -5 | grep -q .; then
  echo "✗ 自产文件疑似泄漏密钥，中止"; exit 1
fi

# ── 4) fnpack ──
echo "[4/4] fnpack 打包 ..."
sed -i "s/^version .*=.*/version               = $VERSION/" "$ROOT/fnpack/manifest"
mkdir -p "$ROOT/dist"
cd "$ROOT/fnpack"
"$FP_BIN" build
mv -f ftllm.fpk "$ROOT/dist/ftllm_v${VERSION}_x86.fpk"
ls -lh "$ROOT/dist/" | tail -3
echo "═══ 完成 ═══"
