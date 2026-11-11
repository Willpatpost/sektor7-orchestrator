#!/usr/bin/env python3
"""SEKTOR7 orchestrator test mock daemon v3 (Phase 2 round-2 corrective tests).

Loopback mock of the Qwen Code serve daemon API. Scenario state is read from
scenario.json in the working directory on EVERY request:

{
  "sessions": {
    "<sessionId>": {"state": "idle|active", "pending": 0, "permWait": false,
                     "questionWait": false, "activePrompt": false}
  },
  "postPrompt": {"ok": true, "promptId": "aaaaaaaa-1111-1111-1111-111111111111",
                  "delayMs": 0, "httpStatus": 202,
                  "mode": "normal|missing-promptId|malformed|empty-body"},
  "statusMode": "normal|null-state|null-booleans|wrong-typed|mismatched-session",
  "pendingMode": "normal|null-pending",
  "trackPosts": false
}

Every POST /session/:id/prompt increments the `postcount` file in the working
directory (all attempts, accepted or not) so concurrency tests can assert
exactly-once submission. With "trackPosts": true, accepted POSTs are also
tracked per session (posted-<sid8> files) and reflected in that session's
status (pending count / activePrompt), so gate-after-POST behavior is
realistic for the R3 concurrency regressions.
"""
import json
import os
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

SCENARIO = os.path.join(os.getcwd(), "scenario.json")
POSTCOUNT = os.path.join(os.getcwd(), "postcount")
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def scenario():
    with open(SCENARIO) as f:
        return json.load(f)


def bump_postcount():
    n = 0
    if os.path.exists(POSTCOUNT):
        with open(POSTCOUNT) as f:
            n = int(f.read().strip() or 0)
    with open(POSTCOUNT, "w") as f:
        f.write(str(n + 1))


def tracked_posts(sid):
    f = os.path.join(os.getcwd(), "posted-" + sid[:8])
    if os.path.exists(f):
        with open(f) as fh:
            return int(fh.read().strip() or 0)
    return 0


def bump_tracked(sid):
    with open(os.path.join(os.getcwd(), "posted-" + sid[:8]), "w") as fh:
        fh.write(str(tracked_posts(sid) + 1))


def record_last_prompt(text):
    with open(os.path.join(os.getcwd(), "lastprompt"), "w") as fh:
        fh.write(text)


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
            mode = scenario().get("statusMode", "normal")
            if mode == "null-state":
                return self._json(200, {"sessionId": sid, "activeWorkState": None})
            if mode == "null-booleans":
                return self._json(200, {"sessionId": sid, "activeWorkState": "idle",
                                        "hasActivePrompt": None,
                                        "isWaitingForPermission": None,
                                        "isWaitingForUserQuestion": None})
            if mode == "wrong-typed":
                return self._json(200, {"sessionId": sid, "activeWorkState": "idle",
                                        "hasActivePrompt": "no",
                                        "isWaitingForPermission": "no",
                                        "isWaitingForUserQuestion": "no"})
            if mode == "mismatched-session":
                return self._json(200, {"sessionId": "99999999-9999-9999-9999-999999999999",
                                        "activeWorkState": "idle",
                                        "hasActivePrompt": False,
                                        "isWaitingForPermission": False,
                                        "isWaitingForUserQuestion": False})
            s = scenario().get("sessions", {}).get(sid)
            if s is None:
                s = {}
            tracked = tracked_posts(sid) if scenario().get("trackPosts") else 0
            return self._json(200, {
                "sessionId": sid,
                "activeWorkState": s.get("state", "idle"),
                "hasActivePrompt": bool(s.get("activePrompt", s.get("state") == "active") or tracked > 0),
                "pendingInteractionCount": 0,
                "isWaitingForPermission": s.get("permWait", False),
                "isWaitingForUserQuestion": s.get("questionWait", False),
                "_trackedPosts": tracked})
        m = re.match(r"^/session/([^/]+)/pending-prompts$", self.path)
        if m:
            sid = m.group(1)
            if scenario().get("pendingMode") == "null-pending":
                return self._json(200, {"pendingPrompts": None})
            if scenario().get("pendingMode") == "race":
                # V5-F2 deterministic race: the status query reported idle,
                # but a prompt arrived before the pending query — busy now.
                return self._json(200, {"pendingPrompts": [{"raced": True}]})
            s = scenario().get("sessions", {}).get(sid, {})
            n = int(s.get("pending", 0))
            if scenario().get("trackPosts"):
                n += tracked_posts(sid)
            return self._json(200, {"pendingPrompts": [{"mock": i} for i in range(n)]})
        return self._json(404, {"error": "unknown route"})

    def do_POST(self):
        if not self._auth_ok():
            return self._json(401, {"error": "unauthorized"})
        m = re.match(r"^/session/([^/]+)/prompt$", self.path)
        if m:
            sid = m.group(1)
            length = int(self.headers.get("Content-Length", 0))
            try:
                body = json.loads(self.rfile.read(length) or b"{}")
            except json.JSONDecodeError:
                return self._json(400, {"error": "bad json"})
            prompt = body.get("prompt")
            if not isinstance(prompt, list) or not prompt:
                return self._json(400, {
                    "error": "`prompt` is required and must be a non-empty array"})
            record_last_prompt(json.dumps(prompt))
            p = scenario().get("postPrompt", {"ok": True, "promptId": "aaaaaaaa-1111-1111-1111-111111111111"})
            delay = int(p.get("delayMs", 0))
            if delay:
                time.sleep(delay / 1000.0)
            bump_postcount()
            mode = p.get("mode", "normal")
            status = int(p.get("httpStatus", 202))
            if not p.get("ok", True):
                self.send_response(500)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if status != 202:
                self.send_response(status)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if mode == "missing-promptId":
                return self._json(202, {"lastEventId": 1})
            if mode == "malformed":
                body = b"this is not json{{{"
                self.send_response(202)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if mode == "empty-body":
                self.send_response(202)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if scenario().get("trackPosts"):
                bump_tracked(sid)
            return self._json(202, {"promptId": p.get("promptId", "aaaaaaaa-1111-1111-1111-111111111111"),
                                    "lastEventId": 1, "eventEpoch": "mock-epoch"})
        return self._json(404, {"error": "unknown route"})


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 4199
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
