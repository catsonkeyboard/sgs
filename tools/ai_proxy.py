#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AI 本地代理：游戏用明文 HTTP 连它，由它转发到真正的 HTTPS 接口。

为什么需要它：LÖVE 内置的 LuaSocket 没有 luasec（ssl.https 直接 require 失败），
而 LLM 接口一律 HTTPS。与其在游戏里折腾 TLS，不如让游戏只跟本机明文通信，
TLS 交给 Python —— 标准库 urllib 就能做，零依赖、跨平台一致。

额外好处：
  - **密钥不进游戏进程**。游戏连的是 127.0.0.1，不需要知道 API key。
  - 调试方便：`--verbose` 能看到每一次完整的请求与响应。
  - 重试、超时、多模型路由都可以在这里加，不用改 Lua。

用法：
    export SGS_AI_URL="https://tokenhub.tencentmaas.com/v1/responses"
    export SGS_AI_KEY="sk-..."
    ./tools/ai_proxy.py                 # 默认监听 127.0.0.1:8899
    ./tools/ai_proxy.py --port 9000 -v  # 换端口 + 打印日志

然后另开一个终端：
    export SGS_AI_TRANSPORT=proxy
    ./run-game.sh

只监听 127.0.0.1（不对外暴露），且只接受本机回环连接。
用标准库实现，两个 Python 3.9 / 3.13 都能跑（不依赖 requests）。
"""

import argparse
import json
import os
import sys
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_PORT = 8899


def log(msg):
    print(msg, file=sys.stderr, flush=True)


class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    upstream = ""
    api_key = ""
    timeout = 90
    verbose = False

    def _reject(self, code, msg):
        body = json.dumps({"error": {"message": msg}}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        # 健康检查：游戏侧可据此判断代理在不在
        if self.path.rstrip("/").endswith("/health"):
            body = json.dumps({"ok": True, "upstream": bool(self.upstream)}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self._reject(404, "只接受 POST /v1/chat/completions 与 GET /health")

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""

        if not self.upstream:
            self._reject(500, "代理未配置 SGS_AI_URL")
            return

        headers = {"Content-Type": "application/json", "Accept": "application/json"}
        if self.api_key:
            headers["Authorization"] = "Bearer " + self.api_key

        if self.verbose:
            log("[->] %s %d 字节" % (self.upstream, len(body)))

        req = urllib.request.Request(self.upstream, data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                out, status = resp.read(), resp.status
        except urllib.error.HTTPError as e:
            # 上游返回 4xx/5xx：把错误体原样带回，游戏侧能看到真实原因
            out, status = e.read(), e.code
        except urllib.error.URLError as e:
            self._reject(502, "无法连接上游（%s）" % getattr(e, "reason", e))
            return
        except Exception as e:  # noqa: BLE001 - 兜住超时等，不能让代理线程挂掉
            self._reject(504, "请求上游失败：%s" % e)
            return

        if self.verbose:
            log("[<-] %s %d 字节" % (status, len(out)))

        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, fmt, *args):
        if self.verbose:
            log("[http] " + (fmt % args))


def main():
    ap = argparse.ArgumentParser(description="sgs 的 LLM 本地明文代理")
    ap.add_argument("--port", type=int, default=int(os.environ.get("SGS_AI_PROXY_PORT") or DEFAULT_PORT))
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--timeout", type=int, default=90)
    args = ap.parse_args()

    upstream = os.environ.get("SGS_AI_URL", "")
    api_key = os.environ.get("SGS_AI_KEY") or os.environ.get("OPENAI_API_KEY") or ""

    if not upstream:
        log("警告：未设置 SGS_AI_URL，代理起来后只能回健康检查。")
        log("      export SGS_AI_URL=https://tokenhub.tencentmaas.com/v1/responses")

    ProxyHandler.upstream = upstream
    ProxyHandler.api_key = api_key
    ProxyHandler.timeout = args.timeout
    ProxyHandler.verbose = args.verbose

    # ThreadingHTTPServer：单线程版本在游戏等待响应时会把第二个请求堵住
    srv = ThreadingHTTPServer((args.host, args.port), ProxyHandler)
    log("AI 代理已启动：http://%s:%d -> %s" % (args.host, args.port, upstream or "(未配置)"))
    log("游戏侧：export SGS_AI_TRANSPORT=proxy 后启动 ./run-game.sh")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        log("\n已停止")
        srv.shutdown()


if __name__ == "__main__":
    main()
