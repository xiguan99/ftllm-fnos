#!/bin/bash
# ftllm-fnos 构建脚本
# 流程: 离线 wheel 集 → 图标 → 入口前缀断言 → 隐私扫描 → fnpack 出 .fpk
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
# 断言必须打在实际代码上，不能只看注释里提没提：要求存在 path.startswith("/app/<appname>
PATTERN="path.startswith(\"/app/$APPNAME"
if ! grep -qF "$PATTERN" "$ENTRY_PY"; then
  echo "✗ $ENTRY_PY 没有处理 /app/$APPNAME 前缀 —— 手机端应用中心会 404"
  exit 1
fi
echo "  ✓ 入口认 /app/$APPNAME 前缀"
# ── 3) 隐私扫描（只扫自产文件；wheels 是上游二进制不扫）──
echo "[4/5] 隐私扫描 ..."
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
echo "[5/5] fnpack 打包 ..."
sed -i "s/^version .*=.*/version               = $VERSION/" "$ROOT/fnpack/manifest"
mkdir -p "$ROOT/dist"
cd "$ROOT/fnpack"
"$FP_BIN" build
mv -f ftllm.fpk "$ROOT/dist/ftllm_v${VERSION}_x86.fpk"
# 出包后硬断言：图标必须 644（否则应用中心显示占位图，与 freellmapi/strata 同一个坑）
CHK="$(mktemp -d)"
tar -xzf "$ROOT/dist/ftllm_v${VERSION}_x86.fpk" -C "$CHK" ICON.PNG ICON_256.PNG 2>/dev/null || true
for ic in ICON.PNG ICON_256.PNG; do
  m="$(stat -c '%a' "$CHK/$ic" 2>/dev/null || echo MISSING)"
  [ "$m" = "644" ] || { echo "✗ $ic 权限=$m（必须 644，否则应用中心显示占位图）"; rm -rf "$CHK"; exit 1; }
done
rm -rf "$CHK"
echo "  ✓ 图标权限 644 断言通过"

# 出包后核对包内实物：不只信源码，防止 fnpack 打进旧文件
if ! tar -xzOf "$ROOT/dist/ftllm_v${VERSION}_x86.fpk" app.tgz | tar -xzOf - supervisor.py | grep -qF "$PATTERN"; then
  echo "✗ 包内 supervisor.py 不含 /app/$APPNAME 前缀处理，拒绝出包"
  exit 1
fi
echo "  ✓ 包内 supervisor.py 已含前缀处理"
ls -lh "$ROOT/dist/" | tail -3
echo "═══ 完成 ═══"
