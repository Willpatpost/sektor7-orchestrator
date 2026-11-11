#!/usr/bin/env python3
"""SEKTOR7 orchestrator test mock daemon (Phase 2, local testing only).

Serves a configurable subset of the Qwen Code serve daemon API on loopback so
orchestrator/supervisor failure scenarios can be tested non-destructively.
Scenario state is read from scenario.json in the working directory on EVERY
request, so tests can mutate behavior between calls:

{
  "sessions": {
    "<sessionId>": {"state": "idle|active", "pending": 0, "permWait": false,
                     "questionWait": false, "activePrompt": false}
  },
  "postPrompt": {"ok": true, "promptId": "mock-prompt-1"}   // or {"ok": false}
}
"""
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

SCENARIO = os.path.join(os.getcwd(), "scenario.json")
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def scenario():
    with open(SCENARIO) as f:
        return json.load(f)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # keep test output quiet
        pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _auth_ok(self):
        header = self.headers.get("Authorization", "")
        with open(os.environ.get("MOCK_TOKEN_FILE", "/dev/null")) as f:
            expected = f.read().strip()
        return header == f"Bearer {expected}"

    def do_GET(self):
        if not self._auth_ok():
            return self._json(401, {"error": "unauthorized"})
        if self.path == "/capabilities":
            return self._json(200, {"v": 1, "qwenCodeVersion": "mock"})
        m = re.match(r"^/session/([^/]+)/status$", self.path)
        if m:
            sid = m.group(1)
            if not UUID_RE.match(sid):
                return self._json(404, {"error": "no such session"})
            s = scenario().get("sessions", {}).get(sid)
            if s is None:
                return self._json(200, {
                    "sessionId": sid, "activeWorkState": "idle",
                    "hasActivePrompt": False, "pendingInteractionCount": 0,
                    "isWaitingForPermission": False, "isWaitingForUserQuestion": False})
            return self._json(200, {
                "sessionId": sid,
                "activeWorkState": s.get("state", "idle"),
                "hasActivePrompt": s.get("activePrompt", s.get("state") == "active"),
                "pendingInteractionCount": 0,
                "isWaitingForPermission": s.get("permWait", False),
                "isWaitingForUserQuestion": s.get("questionWait", False)})
        m = re.match(r"^/session/([^/]+)/pending-prompts$", self.path)
        if m:
            sid = m.group(1)
            s = scenario().get("sessions", {}).get(sid, {})
            n = int(s.get("pending", 0))
            return self._json(200, {"pendingPrompts": [{"mock": i} for i in range(n)]})
        return self._json(404, {"error": "unknown route"})

    def do_POST(self):
        if not self._auth_ok():
            return self._json(401, {"error": "unauthorized"})
        m = re.match(r"^/session/([^/]+)/prompt$", self.path)
        if m:
            length = int(self.headers.get("Content-Length", 0))
            try:
                body = json.loads(self.rfile.read(length) or b"{}")
            except json.JSONDecodeError:
                return self._json(400, {"error": "bad json"})
            prompt = body.get("prompt")
            if not isinstance(prompt, list) or not prompt:
                return self._json(400, {
                    "error": "`prompt` is required and must be a non-empty array"})
            p = scenario().get("postPrompt", {"ok": True, "promptId": "mock-prompt-1"})
            if not p.get("ok", True):
                # simulate a transport failure after admission
                self.send_response(500)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            return self._json(202, {"promptId": p.get("promptId", "mock-prompt-1"),
                                    "lastEventId": 1, "eventEpoch": "mock-epoch"})
        return self._json(404, {"error": "unknown route"})


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 4199
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
