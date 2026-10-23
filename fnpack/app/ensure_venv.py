#!/usr/bin/env python3
"""首启离线建 venv：用系统 python 建虚拟环境，再从包内 wheels 装 ftllm（不联网）。

用法: ensure_venv.py <venv 目录> <wheels 目录> <日志文件>
退出码 0 = 就绪；非 0 = 失败（调用方据此给出人话提示）。
"""

from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path


def main() -> int:
    if len(sys.argv) < 4:
        print("用法: ensure_venv.py <venv> <wheels> <log>", file=sys.stderr)
        return 2
    venv = Path(sys.argv[1])
    wheels = Path(sys.argv[2])
    logfile = Path(sys.argv[3])
    logfile.parent.mkdir(parents=True, exist_ok=True)

    def log(msg: str) -> None:
        line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} [ensure-venv] {msg}"
        print(line, flush=True)
        with logfile.open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")

    log(f"开始：python={sys.executable} venv={venv} wheels={wheels}")
    if not wheels.is_dir() or not any(wheels.glob("*.whl")):
        log(f"错误：wheels 目录不存在或为空：{wheels}")
        return 3

    if not (venv / "bin" / "python3").exists():
        log("创建虚拟环境")
        r = subprocess.run([sys.executable, "-m", "venv", str(venv)], capture_output=True, text=True)
        if r.returncode != 0:
            log("创建 venv 失败：" + (r.stderr or r.stdout or "").strip()[-800:])
            log("提示：系统缺少 python3-venv（ensurepip）组件时无法创建虚拟环境")
            return 4

    pip = venv / "bin" / "pip"
    whl = sorted(str(p) for p in wheels.glob("*.whl"))
    log(f"从包内 wheels 离线安装（{len(whl)} 个 wheel，--no-deps 只装清单内文件）")
    # --no-deps：ftllm 元数据里声明了 triton / XlsxWriter 等与启动器无关的大依赖
    # （triton 是 GPU 训练侧、XlsxWriter 是导出侧），这里只装包内已 vendor 的最小集。
    cmd = [str(pip), "install", "--no-index", "--no-deps",
           "--disable-pip-version-check", "--no-warn-script-location", *whl]
    env = dict(os.environ, PIP_NO_INDEX="1", PIP_DISABLE_PIP_VERSION_CHECK="1")
    r = subprocess.run(cmd, capture_output=True, text=True, env=env)
    tail = (r.stdout or "")[-1500:] + (r.stderr or "")[-1500:]
    log("pip 退出码 " + str(r.returncode))
    if r.returncode != 0:
        log("离线安装失败，最后输出：\n" + tail.strip())
        return 5

    ftllm = venv / "bin" / "ftllm"
    if not ftllm.exists():
        log("安装完成但找不到 ftllm 可执行文件")
        return 6
    log("就绪：" + str(ftllm))
    return 0


if __name__ == "__main__":
    sys.exit(main())
