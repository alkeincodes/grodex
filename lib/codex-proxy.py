#!/usr/bin/env python3
"""
Grok Build ↔ ChatGPT/Codex backend shim.

Grok's `responses` backend is *almost* compatible with the ChatGPT backend
(chatgpt.com/backend-api/codex), but two incompatibilities make it fail:

  1. REQUEST: Grok labels its agent system prompt with role "system", which the
     ChatGPT backend rejects (400 {"detail":"System messages are not allowed"}).
     Fix: rewrite input[].role "system" -> "developer".

  2. RESPONSE: the ChatGPT backend streams the assistant message via
     `response.output_item.done` events but leaves the terminal
     `response.completed` envelope's `output` array EMPTY. Standard OpenAI
     /v1/responses populates it. Grok streams the visible text fine, but then
     assembles the final turn from `response.output`, sees it empty, treats the
     turn as an "empty response from model", and loops the agent forever.
     Fix: accumulate the streamed output items and inject them into the
     terminal event's `output` array before forwarding.

This localhost proxy sits between Grok and the ChatGPT backend, applies both
fixes, and streams everything else through untouched. Grok's own Authorization /
chatgpt-account-id / originator headers (from ~/.codex via codex-auth.sh) are
forwarded upstream unchanged.

Run:  python3 ~/.grok/codex-proxy.py            # listens on 127.0.0.1:8765
Env:  GROK_CODEX_PROXY_PORT (default 8765)
      GROK_CODEX_UPSTREAM_HOST (default chatgpt.com)
      GROK_CODEX_UPSTREAM_BASE (default /backend-api/codex)
"""
import http.client
import json
import os
import ssl
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("GROK_CODEX_PROXY_PORT", "8765"))
UPSTREAM_HOST = os.environ.get("GROK_CODEX_UPSTREAM_HOST", "chatgpt.com")
UPSTREAM_BASE = os.environ.get("GROK_CODEX_UPSTREAM_BASE", "/backend-api/codex").rstrip("/")

HOP = {
    "host", "content-length", "connection", "keep-alive", "proxy-authenticate",
    "proxy-authorization", "te", "trailers", "transfer-encoding", "upgrade",
    "accept-encoding", "content-encoding",
}


def transform_request(raw: bytes) -> bytes:
    try:
        d = json.loads(raw)
    except Exception:
        return raw
    inp = d.get("input")
    if isinstance(inp, list):
        for item in inp:
            if isinstance(item, dict) and item.get("role") == "system":
                item["role"] = "developer"
    d["store"] = False
    d["stream"] = True
    # GPT-5.6 reasoning models on the ChatGPT backend reject sampling params
    # (400 "Unsupported parameter: temperature" / "top_p"). Grok's compaction
    # path sets them, which breaks /compact; normal turns don't send them.
    d.pop("temperature", None)
    d.pop("top_p", None)
    return json.dumps(d).encode()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    # ---- SSE response rewriting -------------------------------------------

    def _stream_rewrite(self, resp):
        """Yield SSE event blocks (as bytes), injecting streamed output items
        into the terminal response.{completed,incomplete} event's `output`."""
        collected = []
        event_lines = []

        def render(lines):
            ev_name = None
            data_parts = []
            for ln in lines:
                if ln.startswith("event:"):
                    ev_name = ln[6:].strip()
                elif ln.startswith("data:"):
                    data_parts.append(ln[5:].lstrip())
            if not data_parts:
                return "".join(lines)  # comment/keepalive/blank — pass through
            raw = "\n".join(p.rstrip("\n") for p in data_parts)
            try:
                d = json.loads(raw)
                typ = d.get("type", "")
                if typ == "response.output_item.done":
                    item = d.get("item")
                    if item is not None:
                        collected.append(item)
                elif typ in ("response.completed", "response.incomplete"):
                    ro = d.get("response")
                    if isinstance(ro, dict) and not ro.get("output"):
                        ro["output"] = list(collected)
                        raw = json.dumps(d)
            except Exception:
                pass
            head = f"event: {ev_name}\n" if ev_name is not None else ""
            return f"{head}data: {raw}\n\n"

        while True:
            line = resp.readline()
            if not line:
                if event_lines:
                    yield render(event_lines).encode()
                break
            text = line.decode("utf-8", "replace")
            if text.strip() == "":
                event_lines.append(text)
                yield render(event_lines).encode()
                event_lines = []
            else:
                event_lines.append(text)

    # ---- proxy core -------------------------------------------------------

    def _relay(self, method):
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length) if length else b""
        is_responses = self.path.endswith("/responses")
        if is_responses:
            body = transform_request(body)

        out_headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
        out_headers["Content-Length"] = str(len(body))
        out_headers["Accept-Encoding"] = "identity"
        out_headers.setdefault("originator", "codex_cli_rs")
        out_headers.setdefault("OpenAI-Beta", "responses=experimental")

        try:
            conn = http.client.HTTPSConnection(
                UPSTREAM_HOST, timeout=600, context=ssl.create_default_context()
            )
            conn.request(method, UPSTREAM_BASE + self.path, body=body, headers=out_headers)
            resp = conn.getresponse()
        except Exception as e:
            self.send_response(502)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(f"codex-proxy upstream error: {e}".encode())
            self.close_connection = True
            return

        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() in HOP:
                continue
            self.send_header(k, v)
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        total = 0
        injected = False
        ok_stream = is_responses and resp.status == 200
        try:
            if ok_stream:
                for block in self._stream_rewrite(resp):
                    if b'"output":' in block and b"response.completed" in block:
                        injected = True
                    total += len(block)
                    self.wfile.write(b"%X\r\n" % len(block) + block + b"\r\n")
                    self.wfile.flush()
            else:
                while True:
                    chunk = resp.read(2048)
                    if not chunk:
                        break
                    total += len(chunk)
                    self.wfile.write(b"%X\r\n" % len(chunk) + chunk + b"\r\n")
                    self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            conn.close()
        sys.stderr.write(
            f"[codex-proxy] {method} {self.path} -> {resp.status} {total}B "
            f"rewrite={ok_stream} injected_output={injected}\n"
        )
        sys.stderr.flush()

    def do_POST(self):
        self._relay("POST")

    def do_GET(self):
        self._relay("GET")


def main():
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(
        f"codex-proxy listening on http://127.0.0.1:{PORT}  ->  "
        f"https://{UPSTREAM_HOST}{UPSTREAM_BASE}  (system->developer + terminal-output injection)",
        file=sys.stderr, flush=True,
    )
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        srv.shutdown()


if __name__ == "__main__":
    main()
