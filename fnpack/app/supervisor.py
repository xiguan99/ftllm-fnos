#!/usr/bin/env python3
"""FastLLM Launcher 入口 shim。

桌面图标/端口（service_port 8090）指向本服务：每次被访问时读取当前 launcher 的
控制 token，再 302 到 `http://<同主机>:<launcher 端口>/?token=<token>`。
token 是每次启动随机生成的，所以图标 URL 保持静态、由这里在访问瞬间注入。

同时是 launcher 子进程的监督者：拉起 `ftllm launch --host 0.0.0.0`，把 stdout 写日志
并实时解析 token 写入 launcher-token.json（0600）。
"""

from __future__ import annotations

import http.server
import json
import os
import re
import signal
import socketserver
import subprocess
import sys
import threading
import time
from pathlib import Path

VAR = Path(os.environ.get("TRIM_PKGVAR") or "/tmp/ftllm-var")
APP = Path(os.environ.get("TRIM_APPDEST") or Path(__file__).resolve().parents[1])
VENV = VAR / "venv"
LOGS = VAR / "logs"
TOKEN_FILE = VAR / "launcher-token.json"
LAUNCHER_LOG = LOGS / "launcher.log"
SUPERVISOR_LOG = LOGS / "supervisor.log"

LAUNCHER_PORT = int(os.environ.get("FTLLM_LAUNCHER_PORT", "8099"))
SHIM_PORT = int(os.environ.get("FTLLM_SHIM_PORT", "8090"))

TOKEN_RE = re.compile(r"https?://[^\s/]+(?::\d+)?/\?token=([A-Za-z0-9_-]{16,})")
STATE = {"token": None, "url": None, "at": 0.0, "proc": None}
LOCK = threading.Lock()


def log(msg: str) -> None:
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} [shim] {msg}"
    print(line, flush=True)
    try:
        LOGS.mkdir(parents=True, exist_ok=True)
        with SUPERVISOR_LOG.open("a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def save_token(token: str, url: str) -> None:
    data = {"token": token, "url": url, "at": time.time(), "port": LAUNCHER_PORT}
    tmp = TOKEN_FILE.with_suffix(".tmp")
    try:
        tmp.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        os.chmod(tmp, 0o600)
        tmp.replace(TOKEN_FILE)
        os.chmod(TOKEN_FILE, 0o600)
    except OSError as exc:
        log(f"写 token 文件失败: {exc}")
        return
    with LOCK:
        STATE.update(token=token, url=url, at=time.time())
    log(f"已获取控制 token（{len(token)} 字符），写入 {TOKEN_FILE}")


def read_token() -> dict | None:
    with LOCK:
        if STATE["token"]:
            return {"token": STATE["token"], "url": STATE["url"], "at": STATE["at"], "port": LAUNCHER_PORT}
    try:
        data = json.loads(TOKEN_FILE.read_text(encoding="utf-8"))
        if data.get("token"):
            with LOCK:
                STATE.update(token=data["token"], url=data.get("url"), at=float(data.get("at") or 0))
            return data
    except (OSError, ValueError):
        pass
    return None


def stream_output(proc: subprocess.Popen) -> None:
    """逐行读 launcher 输出：落日志，并从中抓 ?token=。"""
    LOGS.mkdir(parents=True, exist_ok=True)
    with LAUNCHER_LOG.open("a", encoding="utf-8") as lf:
        lf.write(f"\n=== {time.strftime('%Y-%m-%d %H:%M:%S')} ftllm launch 启动 ===\n")
        lf.flush()
        assert proc.stdout is not None
        for line in proc.stdout:
            try:
                lf.write(line)
                lf.flush()
            except OSError:
                pass
            m = TOKEN_RE.search(line)
            if m:
                token = m.group(1)
                url = line.strip().split()[-1]
                save_token(token, url)
    log(f"launcher 输出结束（退出码 {proc.poll()}）")


def start_launcher() -> subprocess.Popen | None:
    exe = VENV / "bin" / "ftllm"
    if not exe.exists():
        log(f"找不到 {exe}，先运行 ensure-venv")
        return None
    env = dict(os.environ)
    env.setdefault("HOME", str(VAR))
    env.setdefault("PYTHONUNBUFFERED", "1")
    cmd = [str(exe), "launch", "--host", "0.0.0.0", "--port", str(LAUNCHER_PORT), "--no-browser"]
    log("启动: " + " ".join(cmd))
    try:
        proc = subprocess.Popen(
            cmd, cwd=str(VAR), env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1,
        )
    except OSError as exc:
        log(f"启动失败: {exc}")
        return None
    with LOCK:
        STATE["proc"] = proc
    threading.Thread(target=stream_output, args=(proc,), daemon=True).start()
    return proc


PENDING_PAGE = """<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FastLLM Launcher 正在启动</title>
<style>body{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;background:#0f1115;color:#e6e6e6;
display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
.box{max-width:30rem;padding:2rem;text-align:center}code{background:#1b1f27;padding:.15rem .4rem;border-radius:.3rem}
.spin{width:1.6rem;height:1.6rem;border:3px solid #2a3040;border-top-color:#4f8cff;border-radius:50%;
margin:1.2rem auto;animation:r 1s linear infinite}@keyframes r{to{transform:rotate(360deg)}}</style></head>
<body><div class="box"><h2>FastLLM Launcher 正在启动</h2>
<div class="spin"></div><p>正在取得控制令牌，页面会自动刷新（约 3 秒）。</p>
<p style="color:#8b93a1;font-size:.85rem">如果长时间停在这里，请在应用中心查看 <code>%LOG%</code>。</p>
</div></body></html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "ftllm-shim/1.0"

    def log_message(self, fmt: str, *args) -> None:  # 静音默认访问日志
        pass

    def _host_only(self, host_header: str | None) -> str:
        if not host_header:
            return "127.0.0.1"
        host = host_header.rsplit("@", 1)[-1]
        if host.startswith("["):          # [::1]:8090
            return host.split("]")[0] + "]"
        return host.split(":")[0]

    def _send(self, code: int, body: bytes, ctype: str, extra: dict | None = None) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            info = read_token()
            if info:
                host = self._host_only(self.headers.get("Host"))
                target = f"http://{host}:{LAUNCHER_PORT}/?token={info['token']}"
                self.log_message("302 -> launcher")
                self._send(302, b"", "text/plain; charset=utf-8", {"Location": target})
                return
            page = PENDING_PAGE.replace("%LOG%", str(LAUNCHER_LOG))
            self._send(503, page.encode("utf-8"), "text/html; charset=utf-8", {"Refresh": "3"})
            return
        if path == "/healthz":
            with LOCK:
                proc = STATE["proc"]
                at = STATE["at"]
            alive = bool(proc and proc.poll() is None)
            body = json.dumps({
                "ok": alive, "launcher": alive, "port": LAUNCHER_PORT,
                "token_age_sec": round(time.time() - at, 1) if at else None,
            }).encode()
            self._send(200 if alive else 503, body, "application/json")
            return
        if path == "/token.json":
            if self.client_address[0] not in ("127.0.0.1", "::1"):
                self._send(403, b'{"error":"local only"}', "application/json")
                return
            info = read_token()
            if not info:
                self._send(503, b'{"error":"token not ready"}', "application/json")
                return
            self._send(200, json.dumps(info).encode(), "application/json")
            return
        self._send(404, b'{"error":"not found"}', "application/json")


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main() -> int:
    VAR.mkdir(parents=True, exist_ok=True)
    LOGS.mkdir(parents=True, exist_ok=True)
    log(f"shim 启动：端口 {SHIM_PORT}，launcher 内部端口 {LAUNCHER_PORT}，数据目录 {VAR}")
    proc = start_launcher()
    if proc is None:
        log("launcher 未能启动，shim 仍会提供启动中页面")

    httpd = Server(("0.0.0.0", SHIM_PORT), Handler)

    def shutdown(signum, _frame):
        log(f"收到信号 {signum}，收尾退出")
        try:
            httpd.shutdown()
        except Exception:
            pass
        with LOCK:
            p = STATE["proc"]
        if p and p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=8)
            except subprocess.TimeoutExpired:
                p.kill()
        sys.exit(0)

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, shutdown)

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        shutdown(0, None)
    return 0


if __name__ == "__main__":
    sys.exit(main())
