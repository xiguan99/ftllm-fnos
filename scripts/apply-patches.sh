#!/bin/bash
# ftllm 本地补丁（幂等，可反复跑；由 build.sh 每次构建自动调用）
#
# 补丁 1（缓存头）：launcher.py 响应头中间件里 no-store 只覆盖页面路由与 /api/，
#   静态挂载 /ui_plugins、/assets（含 mount_studio_assets 挂的 /assets/webui/*）与
#   /assets/webui_locales.js 全无缓存头。一体包是确定性打包、文件 mtime 固定，
#   浏览器对无 Cache-Control 的响应做启发式长缓存 → 覆盖升级后浏览器里
#   新旧 JS/HTML 混搭，初始化链对混搭 DOM 取元素为 null（实测报错：
#   "Cannot set properties of null (setting 'onchange')"）。
#   修法：no-store 判断扩成 ("/api/", "/assets/", "/ui_plugins/")。
#   Starlette StaticFiles 自带 ETag/Last-Modified，协商缓存返回 304，局域网开销可忽略。
#
# 补丁 2（studio 空引用防御）：ui_plugins/studio/app.js 绑定链一行内
#   直接 $("#fileInput").onchange = …；当模板元素缺失（浏览器缓存混搭、模板加载异常等）
#   时整行抛 TypeError，把整个工作室初始化打挂。
#   修法：逐元素判空赋值，缺哪个跳哪个，其余照常绑定。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SP="$ROOT/fnpack/app/portable/support/runtime/lib/python3.11/site-packages/ftllm"
PY="$SP/launcher.py"
JS="$SP/ui_plugins/studio/app.js"

[ -f "$PY" ] || { echo "✗ 找不到 $PY（先跑 prep-portable.sh）"; exit 1; }
[ -f "$JS" ] || { echo "✗ 找不到 $JS"; exit 1; }

python3 - "$PY" "$JS" <<'PYEOF'
import sys

py_path, js_path = sys.argv[1], sys.argv[2]

# ── 补丁 1：launcher.py 缓存头 ──
# 覆盖：页面外壳 "/"（HTML 壳被启发式缓存是新旧混搭的主入口）、
# /api/（上游已有）、/assets/ 与 /ui_plugins/（launcher 与插件全部静态件，
# 含 mount_studio_assets 挂的 /assets/webui/* 与 webui_locales.js）。
PY_V0 = '        if is_webui or request.url.path.startswith("/api/"):\n'
PY_V1 = '        if is_webui or request.url.path.startswith(("/api/", "/assets/", "/ui_plugins/")):\n'
PY_NEW = '        if is_webui or request.url.path == "/" or request.url.path.startswith(("/api/", "/assets/", "/ui_plugins/")):\n'
MARK1 = 'path == "/" or request.url.path.startswith(("/api/", "/assets/", "/ui_plugins/")'

with open(py_path, encoding="utf-8") as f:
    py = f.read()

if MARK1 in py:
    print("  · launcher.py 缓存头补丁：已应用，跳过")
elif py.count(PY_V1) == 1:
    py = py.replace(PY_V1, PY_NEW, 1)
    with open(py_path, "w", encoding="utf-8") as f:
        f.write(py)
    print("  ✓ launcher.py 缓存头补丁已升级（补上根路由 /）")
else:
    n = py.count(PY_V0)
    if n != 1:
        sys.exit(f"✗ launcher.py 补丁 1 锚点命中 {n} 次（应为 1），上游文本已变，需人工核对补丁")
    py = py.replace(PY_V0, PY_NEW, 1)
    with open(py_path, "w", encoding="utf-8") as f:
        f.write(py)
    print("  ✓ launcher.py 缓存头补丁已应用")

# ── 补丁 2：studio/app.js 绑定判空 ──
JS_OLD = ('    $("#newChat").onclick = guard(newConversation); '
          '$("#newAgent").onclick = guard(openWorkspaceDialog); '
          '$("#attachButton").onclick = guard(() => $("#fileInput").click()); '
          '$("#fileInput").onchange = guard(event => uploadFiles([...event.target.files])); '
          '$("#agentButton").onclick = guard(() => { renderAgentSelection(); $("#agentDialog").showModal(); });')
JS_NEW = ('    for (const [el, key, val] of [['
          ' $("#newChat"), "onclick", guard(newConversation)], '
          '[ $("#newAgent"), "onclick", guard(openWorkspaceDialog)], '
          '[ $("#attachButton"), "onclick", guard(() => $("#fileInput").click())], '
          '[ $("#fileInput"), "onchange", guard(event => uploadFiles([...event.target.files]))], '
          '[ $("#agentButton"), "onclick", guard(() => { renderAgentSelection(); $("#agentDialog").showModal(); })]'
          ']) { if (el) el[key] = val; }')
MARK2 = "if (el) el[key] = val;"

with open(js_path, encoding="utf-8") as f:
    js = f.read()

if MARK2 in js:
    print("  · studio/app.js 判空补丁：已应用，跳过")
else:
    n = js.count(JS_OLD)
    if n != 1:
        sys.exit(f"✗ studio/app.js 补丁 2 锚点命中 {n} 次（应为 1），上游文本已变，需人工核对补丁")
    js = js.replace(JS_OLD, JS_NEW, 1)
    with open(js_path, "w", encoding="utf-8") as f:
        f.write(js)
    print("  ✓ studio/app.js 判空补丁已应用")
PYEOF

# 语法自检：python 编译 + node 解析（本机有 node 就跑）
python3 -m py_compile "$PY" && echo "  ✓ launcher.py 语法自检通过"
if command -v node >/dev/null 2>&1; then
  node --check "$JS" && echo "  ✓ studio/app.js 语法自检通过"
fi
echo "  补丁状态：launcher 元组=$(grep -c '"/api/", "/assets/", "/ui_plugins/"' "$PY") studio 判空=$(grep -c 'if (el) el\[key\] = val;' "$JS")"
