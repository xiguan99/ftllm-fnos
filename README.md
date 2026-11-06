# ftllm-fnos

[FastLLM](https://github.com/ztxz16/fastllm)（ztxz16/fastllm）官方网页启动器 `ftllm launch` 的 fnOS 打包版。

FastLLM 是一个纯 C++ 实现的大模型推理库；它的 `launch` 子命令会起一个网页工作台，用来管理模型、下载模型、查看硬件、配置并启动 API 服务。本包把这套工作台装进 fnOS 应用中心：装上之后点桌面图标就能用，桌面图标与端口地址都直达同一界面。

本包**只承载这个网页启动器**，不加载模型、不占用 GPU；模型实际由你自己配置的 launch item 决定何时加载。

## 特性

- **自带运行时**：包内直接携带上游 1.9.0「一体包」的 Python 运行时与全部依赖，装机即用；首次启动只需几秒，全程不联网、不建虚拟环境。
- **默认对外监听**：启动器绑定 `0.0.0.0`，局域网内其它设备可直接访问。
- **图标自动带令牌**：启动器每次启动生成随机控制令牌，桌面图标指向本应用的入口服务，点开时自动跳转并携带当次令牌，无需手工复制 URL。
- **端口直达**：图标与 `http://<NAS 地址>:8090/` 同一入口，不套反向代理、不走统一网关。
- **不干扰既有服务**：使用独立数据目录与独立运行环境，不与机器上已有的任何 FastLLM 服务共享进程或环境。

## 系统要求

- **系统**：fnOS x86_64。
- **Python**：不需要。包内自带 CPython 3.11 运行时；系统 `python3`（3.8 及以上）只用来跑一个几十行的端口转发进程。
- **磁盘**：安装后约 2 GB（包内运行时解包后的体积）。
- **显卡**：打开界面、管理模型不需要显卡；真正启动推理服务时需要 NVIDIA 显卡与可用驱动——这一点与直接使用 FastLLM 一致。

## 安装

1. 应用中心 → 手动安装，选择 `ftllm_v<版本>_x86.fpk`。
2. 安装完成后自动拉起启动器，几秒内即可访问（运行时随包发布，无需建环境）。
3. 点桌面图标，或访问 `http://<NAS 地址>:8090/`，进入 FastLLM Launcher。

## 使用

进入界面后依次：**Download model**（下载，或指定你已有的本地模型）→ **Add launch item**（配置模型路径、上下文、显存等）→ 启动 → **Open Studio** 进入对话页。

### 入口与令牌

启动器每次启动都会生成一个新的随机控制令牌，用来保护它的管理接口与内嵌网页。入口服务（8090）做的事就是：你访问它的瞬间读出当前令牌，然后跳转（302）到启动器地址并把令牌带上。

- **正常入口**：桌面图标，或 `http://<NAS 地址>:8090/` —— 会自动跳转到 `http://<同一主机>:8099/?token=<当次令牌>`。用局域网里其它设备（手机、平板）打开也同样成立，跳转目标跟随你访问时用的主机名/IP。
- **令牌每次变**：重启应用后旧令牌立即失效，旧链接会打不开管理接口——重新从图标或 8090 进入即可，不用手工复制 URL。
- **直接访问启动器端口**：`http://<NAS 地址>:8099/` 也能看到界面，但没带令牌，管理类操作会被拒绝（接口返回 403）。这不是故障，请从 8090 进。
- **排查用**：`GET :8090/healthz` 返回服务与启动器状态；`GET :8090/token.json` 仅限本地访问。

## 升级与卸载

- **升级**：直接安装新版本 fpk 覆盖即可，配置保留在数据目录；运行时随包整体替换，重启即生效。
- **卸载**：先在应用中心停止应用，再执行卸载。卸载只清理本应用自己的日志与令牌，不会删除你已有的模型文件（模型放在你指定的目录里）。

## 常见问题

**首次启动没有立刻出现界面**
运行时随包发布，一般几秒就好；若看到「正在启动」页，等它自动刷新。若持续不动，看数据目录下 `logs/supervisor.log` 与 `logs/launcher.log`。

**提示运行时缺失**
说明安装目录里的 `portable/` 被清理或安装中断，重新安装应用即可（无需装任何系统依赖）。

**选了 CUDA 却实际跑在 CPU 上**
1.9.0.1 及更早版本有这个问题：包内 CUDA 核心库依赖 `libnccl.so.2`，而上游一体包只把它放在 `site-packages/nvidia/nccl/lib`（不在库加载路径里），打包时该目录又被当作冗余裁掉，于是 CUDA 库加载失败、静默退回 CPU 版，界面上没有任何提示。1.9.0.2 起把 `libnccl.so.2` 与 `libnccl_device.bc` 放进 `portable/support/runtime/lib`（加载路径第一项），并给「降级到 CPU」加了一行明确告警。判断方法：启动日志里出现 `Load libfastllm_tools.so` 才是 CUDA，出现 `Load libfastllm_tools-cpu.so` 就是 CPU（并在 `nvidia-smi` 里看不到显存占用）。设备号注意：面板里的 `cuda:N` 是 CUDA 序号，与 `nvidia-smi` 的序号可能不同，选卡前先看启动器「硬件」页的对应关系。

**页面能打开但点按钮没反应 / 提示无权限**
说明你是直接访问了启动器端口（8099）而没有令牌。改从桌面图标或 8090 进入。

**端口冲突**
启动器内部端口为 8099、入口端口为 8090。若与机器上其它服务冲突，可在应用配置中调整（`FTLLM_LAUNCHER_PORT` / `FTLLM_SHIM_PORT`）。

**能不能用它替代我现有的 FastLLM 服务**
本包只装启动器，不管理、也不改动机器上已有的 FastLLM 进程或环境。两者互不影响。

## 构建

```sh
scripts/build.sh
```

构建前需先把上游「一体包」铺进包内运行时目录：

```sh
# 1) 取上游 1.9.0 一体包并校验
#    FastLLM-Launcher-<版本>-linux-x86_64-portable.tar.gz（发布页 SHA256SUMS 对照）
# 2) 解包
tar xzf FastLLM-Launcher-1.9.0-linux-x86_64-portable.tar.gz -C /tmp
# 3) 铺入包内（自动砍掉 Electron 桌面端，瘦身 site-packages）
bash scripts/prep-portable.sh /tmp/FastLLM-Launcher-1.9.0-linux-x86_64-portable
# 4) 出包
bash scripts/build.sh

上游一体包里的 NCCL 运行库会在铺包时自动落到 `portable/support/runtime/lib`；若某个上游版本自己不带，
把 `libnccl.so.2` 与 `libnccl_device.bc` 放到 `vendor/nccl/lib/` 即可（`pip download nvidia-nccl-cu12 --no-deps` 解包可得），构建会断言包内就位。
```

产物在 `dist/ftllm_v<版本>_x86.fpk`。构建脚本会断言：包内 `portable/ftllm` 版本为 1.9.0、不含 Electron 桌面端、不含旧 `wheels/`、图标权限 644、入口认 `/app/ftllm` 前缀。

## 版本

- **1.9.0.2**：修「面板选 cuda、实际全程跑 CPU」。根因是包内缺 NCCL——CUDA 核心库 `libfastllm_tools.so` 依赖 `libnccl.so.2`，加载失败后 `ftllm/llm.py` 静默降级到 `libfastllm_tools-cpu.so`，界面上毫无提示。现在 NCCL 2.32.3 的 `libnccl.so.2` 与 `libnccl_device.bc` 随包落在运行时加载路径里，构建脚本断言其存在，静默降级也改为打印告警。实测 `Qwen3-0.6B` 生成 200 token ≈142 tok/s（CPU 模式光 warmup 就要十分钟以上）。
- **1.9.0.1**：跟进上游 1.9.0「一体包」形态。运行时（CPython 3.11 + 全部依赖 + CUDA 运行库）随包发布，装机即用，首启从 1–2 分钟降到几秒，不再需要系统 Python 建虚拟环境。按 fnOS 场景砍掉 Electron 桌面端（GUI），只保留命令行 `ftllm` 与网页启动器；启动器仍是 `ftllm launch`，入口与令牌机制不变。版本号改为跟随上游（`1.9.0.1` = 上游 1.9.0 + 打包号 1）。
- **0.1.8.2.2**：修手机端打不开——自研入口 `supervisor.py` 原先只认 `/` 与 `/index.html`，而手机端应用中心走网关前缀 `/app/ftllm/`，一律 404。现认 `/app/ftllm` 与 `/app/ftllm/*` 并同样 302 到 launcher。打包脚本新增「入口必须认 `/app/<appname>` 前缀」断言，源码与包内实物各校验一次。
- **0.1.8.2.1**：首个构建，对应上游 `ftllm 0.1.8.2`。自带离线 wheel，首启本地建环境；入口服务自动注入随机令牌；默认对外监听。

## 许可证与致谢

本打包版遵循上游 [fastllm](https://github.com/ztxz16/fastllm) 的许可证。FastLLM 及其推理库的版权归上游作者所有，此仓库仅提供面向 fnOS 的打包与启动适配。
