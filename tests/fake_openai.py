#!/usr/bin/env python3
"""偽の OpenAI Chat Completions サーバー（標準ライブラリのみ）。

POST /v1/chat/completions に固定の応答を返し、受け取ったリクエストヘッダと本文を
FAKE_OPENAI_LOG（JSON 1行）に記録する。checkRisk.sh の整形経路をオフラインで検証するために使う。

使い方: python3 tests/fake_openai.py <port>
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = os.environ.get("FAKE_OPENAI_LOG")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # 標準のアクセスログを黙らせる
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8", errors="replace")
        if LOG:
            with open(LOG, "a", encoding="utf-8") as f:
                f.write(json.dumps({
                    "path": self.path,
                    "authorization": self.headers.get("Authorization", ""),
                    "body": body,
                }, ensure_ascii=False) + "\n")
        try:
            model = json.loads(body).get("model", "?")
        except Exception:
            model = "?"
        resp = {
            "id": "chatcmpl-fake",
            "model": model,
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": "### 🔴 今すぐ対応（Top5）\n1. (stub)\n\n（偽サーバーの固定応答）"},
                "finish_reason": "stop",
            }],
        }
        data = json.dumps(resp, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    srv = HTTPServer(("127.0.0.1", port), Handler)
    # ポート 0 指定時は実際のポートを stdout に出す
    print(srv.server_address[1], flush=True)
    srv.serve_forever()
