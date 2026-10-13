#!/usr/bin/env python3
"""Fake llama-server for Substation smoke tests.

Speaks just enough of the llama-server surface:
  GET  /health               -> {"status":"ok"}
  GET  /metrics              -> Prometheus-ish llama:* lines
  GET  /slots                -> []
  POST /v1/chat/completions  -> SSE (3 tokens) or non-stream JSON;
                                triage-format requests -> 404 (forces the
                                orchestrator onto its heuristic fallback)
Flags from llama-server (-m/--alias/--host/--port/...) are accepted and
mostly ignored; --port / --host are honored.
"""
import json
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def parse_args(argv):
    port, host = 8080, "127.0.0.1"
    model = "fake-model"
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--port", "-p") and i + 1 < len(argv):
            port = int(argv[i + 1]); i += 2; continue
        if a == "--host" and i + 1 < len(argv):
            host = argv[i + 1]; i += 2; continue
        if a in ("--alias", "--model", "-m") and i + 1 < len(argv):
            model = argv[i + 1]; i += 2; continue
        i += 1
    return port, host, model


class Handler(BaseHTTPRequestHandler):
    model = "fake-model"

    def log_message(self, *args):
        pass

    def _send(self, code, body, ctype="application/json"):
        raw = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/health":
            self._send(200, json.dumps({"status": "ok"}))
        elif path == "/metrics":
            now = time.monotonic()
            self._send(200, (
                f"# fake engine\n"
                f"llama:decode_tokens {int(now * 40)}\n"
                f"llama:decode_seconds {now:.3f}\n"
                f"llama:queue_count 0\n"
                f"llama:active_slots 1\n"
            ), ctype="text/plain; version=0.0.4")
        elif path == "/slots":
            self._send(200, json.dumps([{"id": 0, "state": "idle"}]))
        elif path == "/props":
            self._send(200, json.dumps({"model_path": self.model, "n_ctx": 4096}))
        elif path == "/api/node/blob":
            self._send(200, b"\0" * (16 * 1024 * 1024), ctype="application/octet-stream")
        else:
            self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        path = self.path.split("?")[0]
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw or b"{}")
        except Exception:
            body = {}

        if path != "/v1/chat/completions":
            self._send(404, json.dumps({"error": "not found"}))
            return

        if "response_format" in body:
            # triage probe -> endpoint 404 -> daemon must fall back to heuristics
            self._send(404, json.dumps({"error": "json mode not served here"}))
            return

        if body.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            for tok in ("Hello", " from", " fake"):
                chunk = {
                    "id": "cmpl-fake", "object": "chat.completion.chunk",
                    "created": int(time.time()), "model": self.model,
                    "choices": [{"index": 0, "delta": {"content": tok}, "finish_reason": None}],
                }
                self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
                self.wfile.flush()
                time.sleep(0.05)
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            return

        self._send(200, json.dumps({
            "id": "cmpl-fake", "object": "chat.completion",
            "created": int(time.time()), "model": self.model,
            "choices": [{"index": 0, "message": {"role": "assistant", "content": "Hello from fake"},
                         "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 5, "completion_tokens": 3, "total_tokens": 8},
        }))


def main():
    port, host, model = parse_args(sys.argv[1:])
    Handler.model = model
    srv = ThreadingHTTPServer((host, port), Handler)
    srv.daemon_threads = True
    print(f"fake-engine on http://{host}:{port} model={model}", file=sys.stderr)
    srv.serve_forever()


if __name__ == "__main__":
    main()
