import json
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
LOG = sys.argv[2]
TEST_NAME = sys.argv[3]


def log(line):
    with open(LOG, "a") as f:
        f.write(line + "\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        log("GET " + self.path)
        body = json.dumps({"object": "list", "data": [{"id": "nano/sonnet-5.5", "object": "model"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        try:
            req = json.loads(raw)
        except Exception:
            req = {}
        msgs = req.get("messages", [])
        tools = [t.get("function", {}).get("name") for t in req.get("tools", []) or []]
        has_tool_result = any(m.get("role") == "tool" for m in msgs)
        log("POST %s stream=%s msgs=%d tools=%s tool_result=%s" % (
            self.path, req.get("stream"), len(msgs), ",".join(t for t in tools if t), has_tool_result))
        for m in msgs:
            if m.get("role") == "tool":
                log("TOOL_RESULT " + json.dumps(m.get("content"))[:4000])
        if not req.get("stream"):
            content = "ok"
            body = json.dumps({"id": "x", "object": "chat.completion", "choices": [{"index": 0, "message": {"role": "assistant", "content": content}, "finish_reason": "stop"}], "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        def send(obj):
            self.wfile.write(("data: " + json.dumps(obj) + "\n\n").encode())
            self.wfile.flush()
            time.sleep(0.03)

        base = {"id": "chatcmpl-probe", "object": "chat.completion.chunk", "created": int(time.time()), "model": "nano/sonnet-5.5"}
        last = msgs[-1] if msgs else {}
        last_tool = last.get("content") if last.get("role") == "tool" else None
        if last_tool is not None and not isinstance(last_tool, str):
            last_tool = json.dumps(last_tool)
        call = None
        if "run_tests" in tools and last.get("role") == "user":
            call = ("call_list_1", "list_test_targets", {})
        elif "run_tests" in tools and last_tool and re.search(r'source=\\*"list_test_targets', last_tool):
            found = re.search(r'id\\*"\s*:\s*\\*"((?:[^"\\]|\\+/)*#' + re.escape(TEST_NAME) + ')', last_tool)
            if found:
                target = re.sub(r'\\+/', '/', found.group(1))
                call = ("call_probe_1", "run_tests", {"targetIDs": [target], "timeoutSeconds": 120})
        if call:
            log("CALL %s %s" % (call[1], json.dumps(call[2])))
            send(dict(base, choices=[{"index": 0, "delta": {"role": "assistant", "content": ""}, "finish_reason": None}]))
            send(dict(base, choices=[{"index": 0, "delta": {"tool_calls": [{"index": 0, "id": call[0], "type": "function", "function": {"name": call[1], "arguments": ""}}]}, "finish_reason": None}]))
            send(dict(base, choices=[{"index": 0, "delta": {"tool_calls": [{"index": 0, "function": {"arguments": json.dumps(call[2])}}]}, "finish_reason": None}]))
            send(dict(base, choices=[{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]))
        else:
            text = "Sandbox probe finished." if has_tool_result else "No run_tests tool was offered."
            send(dict(base, choices=[{"index": 0, "delta": {"role": "assistant", "content": text}, "finish_reason": None}]))
            send(dict(base, choices=[{"index": 0, "delta": {}, "finish_reason": "stop"}]))
        send(dict(base, choices=[], usage={"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}))
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
