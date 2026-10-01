#!/usr/bin/env python3
"""
把 CI 导出的 Web 版本在本地跑起来，用于在浏览器里核对"Web 展示正确"。

要点：
1. `.wasm` 必须是 `application/wasm`，否则浏览器的 `WebAssembly.instantiateStreaming` 会拒绝；
   Python 自带的 `http.server` 在部分版本里没这个 MIME，所以这里显式补齐。
2. 绑 `0.0.0.0`（预览环境在沙箱外），不能用 127.0.0.1。
3. 我们走的是**单线程（nothreads）**导出，因此**不需要** COOP/COEP 响应头。
   若以后打开 Thread Support（SharedArrayBuffer），下面那两行必须取消注释，
   否则浏览器会报 "SharedArrayBuffer is not defined"。

用法：
    python3 tools/serve_web.py [目录] [端口]
    # 默认：python3 tools/serve_web.py web-preview 8000
"""

from __future__ import annotations

import functools
import http.server
import socketserver
import sys
from pathlib import Path


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
        ".pck": "application/octet-stream",
        ".js": "text/javascript",
        ".mjs": "text/javascript",
    }

    def end_headers(self) -> None:
        self.send_header("Cache-Control", "no-store")
        # self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        # self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        super().end_headers()

    def log_message(self, fmt: str, *args) -> None:  # 访问日志（便于确认浏览器真的在拉文件）
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


def main() -> int:
    root = sys.argv[1] if len(sys.argv) > 1 else "web-preview"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 8000
    if not Path(root).is_dir():
        print(f"目录不存在：{root}\n先把 CI 的产物取回来：\n"
              "  git fetch origin ci/web-preview\n"
              "  git archive origin/ci/web-preview | tar -x -C web-preview", file=sys.stderr)
        return 1

    handler = functools.partial(Handler, directory=root)
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    with socketserver.ThreadingTCPServer(("0.0.0.0", port), handler) as httpd:
        print(f"serving {Path(root).resolve()} on http://0.0.0.0:{port}")
        sys.stdout.flush()
        httpd.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
