#!/usr/bin/env python3
"""Mock Anthropic-compatible provider. Behavior keyed by API-key tail suffix.

key tail        behavior
--------        --------
die401          401 {"error":"invalid x-api-key"}          -> key marked dead
bsy401          401 {"error":"server busy, try again"}     -> throttle (busy marker)
die403          403 forbidden                              -> key marked dead
pay402          402 payment required                       -> key exhausted
thr429          429 rate limited (Retry-After: 2)          -> throttle
srv500          500 internal error                         -> brief cooldown
srv529          529 overloaded                             -> brief cooldown
bad400          400 validation error                       -> passthrough, NO rotation
anything else   200 OK (JSON or SSE per request "stream")
"""
import json
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 9797

OK_BODY = {
    "id": "msg_mock", "type": "message", "role": "assistant",
    "model": "claude-sonnet-5",
    "content": [{"type": "text", "text": "PROXY-OK-42"}],
    "stop_reason": "end_turn",
    "usage": {"input_tokens": 10, "output_tokens": 5,
              "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0},
}

SSE_EVENTS = [
    ("message_start", {"type": "message_start", "message": {
        "id": "msg_mock", "type": "message", "role": "assistant",
        "model": "claude-sonnet-5", "content": [],
        "usage": {"input_tokens": 10, "output_tokens": 0}}}),
    ("content_block_start", {"type": "content_block_start", "index": 0,
                             "content_block": {"type": "text", "text": ""}}),
    ("content_block_delta", {"type": "content_block_delta", "index": 0,
                             "delta": {"type": "text_delta", "text": "STREAM-OK-77"}}),
    ("content_block_stop", {"type": "content_block_stop", "index": 0}),
    ("message_delta", {"type": "message_delta",
                       "delta": {"stop_reason": "end_turn"},
                       "usage": {"output_tokens": 5}}),
    ("message_stop", {"type": "message_stop"}),
]


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _key(self):
        return self.headers.get("x-api-key") or \
            (self.headers.get("authorization") or "").replace("Bearer ", "")

    def _send(self, code, obj, extra=None):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._send(200, {"mock": "ok", "path": self.path})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b"{}"
        try:
            req = json.loads(raw)
        except ValueError:
            req = {}
        key = self._key()
        if key.endswith("die401"):
            return self._send(401, {"error": {"type": "authentication_error",
                                              "message": "invalid x-api-key"}})
        if key.endswith("bsy401"):
            return self._send(401, {"error": {"type": "authentication_error",
                                              "message": "server busy, try again later"}})
        if key.endswith("die403"):
            return self._send(403, {"error": {"type": "permission_error",
                                              "message": "forbidden"}})
        if key.endswith("pay402"):
            return self._send(402, {"error": {"type": "billing_error",
                                              "message": "payment required, credit exhausted"}})
        if key.endswith("thr429"):
            return self._send(429, {"error": {"type": "rate_limit_error",
                                              "message": "rate limited"}},
                              {"Retry-After": "2"})
        if key.endswith("srv500"):
            return self._send(500, {"error": {"type": "api_error",
                                              "message": "internal server error"}})
        if key.endswith("srv529"):
            return self._send(529, {"error": {"type": "overloaded_error",
                                              "message": "overloaded"}})
        if key.endswith("bad400"):
            return self._send(400, {"error": {"type": "invalid_request_error",
                                              "message": "max_tokens required"}})
        if req.get("stream"):
            chunks = []
            for ev, data in SSE_EVENTS:
                chunks.append(f"event: {ev}\ndata: {json.dumps(data)}\n\n".encode())
            body = b"".join(chunks)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        return self._send(200, OK_BODY)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
