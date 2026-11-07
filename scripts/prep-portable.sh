#!/bin/bash
# 从上游 1.9.1「一体包」铺出包内运行时目录 fnpack/app/portable/
#
# 用法: bash scripts/prep-portable.sh <解包后的一体包根目录>
#       例: bash scripts/prep-portable.sh dl-1.9.1/x/FastLLM-Launcher-1.9.1-linux-x86_64-portable
#
# 保留：命令行 ftllm 与其完整 Python 运行时（含 CUDA 运行库）、网页启动器所需文件
# 丢弃：Electron 桌面端（GUI）—— fnOS 只走网页入口，这部分约 300MB（FastLLM-Launcher.bin、
#       lib/locales/*.pak/chrome_*/resources/desktop 等），没有任何调用方
# 瘦身：site-packages 里的 triton（894MB，ftllm 只做 import 探测，缺失自动降级）与
#       nvidia/nccl（384MB，单卡推理不用），以及 __pycache__、CPython 自带的 test/ensurepip 等
# 保留 media（199MB）：1.9.1 起启动器把 support/media/{bin,lib} 塞进 PATH/LD_LIBRARY_PATH，
#       ffmpeg/ffprobe 与 libav* 在那里，视频与多模态链依赖它，不能省。
set -euo pipefail

SRC="${1:-}"
[ -n "$SRC" ] || { echo "用法: $0 <一体包解包目录>"; exit 1; }
[ -x "$SRC/ftllm" ] || { echo "✗ $SRC 不像一体包根目录（缺 ./ftllm）"; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DST="$ROOT/fnpack/app/portable"
echo "═══ 铺包内运行时 ═══"
echo "源: $SRC"
echo "目标: $DST"

rm -rf "$DST"
mkdir -p "$DST/support"

# ── 1) 根目录入口（不含 Electron 的 Fastllm-Launcher）──
for f in ftllm ftllm-launch-webui launch.sh README.html; do
  [ -e "$SRC/$f" ] && cp -a "$SRC/$f" "$DST/"
done

# ── 2) support 下运行所需部分（白名单，避免把 Electron 一起搬进来）──
KEEP="entrypoint.sh env.sh ftllm ftllm-agent-runtime ftllm-check pip python terminal.sh launch.sh
      libexec docs licenses third-party runtime media BUILD-INFO.json LICENSE README.md THIRD-PARTY-NOTICES.md
      build-constraints.txt requirements.lock.txt version ELF-GLIBC-REQUIREMENTS.txt
      snapshot_blob.bin v8_context_snapshot.bin vk_swiftshader_icd.json"
for f in $KEEP; do
  if [ -e "$SRC/support/$f" ]; then cp -a "$SRC/support/$f" "$DST/support/"; fi
done

# ── 3) 瘦身：可缺省的大件 ──
SP="$DST/support/runtime/lib/python3.11/site-packages"
# NCCL 必须先救出来再删：上游只把 libnccl.so.2 放在 site-packages/nvidia/nccl/lib，
# 而该目录不在 LD_LIBRARY_PATH 里 —— 包内 CUDA 核心库会因缺 libnccl.so.2 加载失败，
# 再被 llm.py 静默降级成 CPU 版（2026-11-06 实际事故：面板选 cuda 却全程跑 CPU）。
# 修法：删目录前把 libnccl.so.2 / libnccl_device.bc 落到 support/runtime/lib（LD_LIBRARY_PATH 第一项）。
NCCL_DST="$DST/support/runtime/lib"
for f in libnccl.so.2 libnccl_device.bc; do
  for cand in "$SP/nvidia/nccl/lib/$f" "$ROOT/vendor/nccl/lib/$f"; do
    if [ -e "$cand" ]; then cp -a "$cand" "$NCCL_DST/$f"; break; fi
  done
done
if [ ! -e "$NCCL_DST/libnccl.so.2" ]; then
  echo "✗ 缺 libnccl.so.2（包内 nvidia/nccl 与 vendor/nccl/lib 都没有）—— CUDA 会静默退回 CPU"; exit 1
fi
rm -rf "$SP/triton" "$SP"/triton-*.dist-info 2>/dev/null || true
rm -rf "$SP/nvidia/nccl" "$SP"/nvidia_nccl_*.dist-info 2>/dev/null || true
# CPython 自带、命令行运行时用不到的部分
rm -rf "$DST/support/runtime/lib/python3.11/test" \
       "$DST/support/runtime/lib/python3.11/ensurepip" \
       "$DST/support/runtime/lib/python3.11/idlelib" \
       "$DST/support/runtime/lib/python3.11/turtledemo" \
       "$DST/support/runtime/lib/python3.11/lib2to3" \
       "$DST/support/runtime/include" 2>/dev/null || true
find "$DST" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
find "$DST" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete 2>/dev/null || true

# ── 4) 断言 ──
if [ -e "$DST/Fastllm-Launcher" ] || [ -e "$DST/support/FastLLM-Launcher.bin" ]; then
  echo "✗ Electron 桌面端仍在包里"; exit 1
fi
if [ ! -x "$DST/ftllm" ]; then echo "✗ 缺 $DST/ftllm"; chmod +x "$DST/ftllm" 2>/dev/null || true; fi
VER="$("$DST/ftllm" --version 2>&1 | tail -1)"
echo "  运行时: $VER"
case "$VER" in
  *"ftllm version: 1.9.1"*) ;;
  *) echo "✗ 版本不是 1.9.1：$VER"; exit 1 ;;
esac
# media 必须进包：启动器把 support/media/{bin,lib} 加进 PATH/LD_LIBRARY_PATH
if [ ! -x "$DST/support/media/bin/ffmpeg" ]; then
  echo "✗ 缺 support/media/bin/ffmpeg —— 视频与多模态功能会失效"; exit 1
fi
echo "  体积: $(du -sh "$DST" | cut -f1)"
echo "═══ 完成 ═══"
