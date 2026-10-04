#!/usr/bin/env python3
"""Bounded multi-server/cache gates with private files and an owned HTTP fixture."""
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "client/godot"
GODOT = os.environ.get("GODOT", "godot")


class AuthFixture:
    """Only authenticates test strings; never opens a database or game runtime."""
    def __init__(self):
        self.requests = Counter()
        self.errors = []
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_POST(self):
                name, _, route = self.path.lstrip("/").partition("/")
                fixture.requests[name, route] += 1
                validation = "v1/identity/websocket-token"
                expected = {
                    "existing": "existing-identity", "preferred": "existing-identity",
                    "recreated": "deleted-server-identity", "remote": "remote-identity",
                    "unavailable": "existing-identity", "malformed": "existing-identity",
                    "unavailable-cached": "existing-identity",
                    "retry": "deleted-server-identity",
                }
                status, body = 200, {"token": "short-lived-re-signature"}
                if route == validation and name in expected:
                    if self.headers.get("Authorization") != "Bearer " + expected[name]:
                        fixture.errors.append("wrong credential for " + name)
                        status = 400
                    elif name in {"recreated", "remote", "retry"}:
                        status = 401
                    elif name in {"unavailable", "unavailable-cached"}:
                        status = 503
                    elif name == "malformed":
                        body = {"invalid": "response"}
                elif route == "v1/identity" and name in {"recreated", "retry", "fresh", "one-time"}:
                    if self.headers.get("Authorization"):
                        fixture.errors.append("replacement request must be unauthenticated")
                        status = 400
                    elif name == "retry" and fixture.requests[name, route] == 1:
                        status, body = 503, {"error": "temporary fixture failure"}
                    else:
                        token = {"fresh": "fresh-identity", "one-time": "one-time-identity"}.get(name, "new-server-identity")
                        body = {"token": token}
                else:
                    fixture.errors.append("unexpected authentication request: " + self.path)
                    status = 404
                encoded = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.url = f"http://127.0.0.1:{self.server.server_port}"

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_args):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)

    def verify(self):
        expected = Counter()
        for name in ["existing", "preferred", "recreated", "remote", "unavailable", "unavailable-cached", "malformed"]:
            expected[name, "v1/identity/websocket-token"] = 1
        expected["retry", "v1/identity/websocket-token"] = 2
        for name in ["recreated", "fresh", "one-time"]:
            expected[name, "v1/identity"] = 1
        expected["retry", "v1/identity"] = 2
        if self.errors or self.requests != expected:
            print(f"FAIL authentication HTTP contract: {self.errors}, requests={self.requests}", flush=True)
            return False
        return True


def main():
    with tempfile.TemporaryDirectory(prefix="managed-server-checks-", dir="/tmp/opencode") as temporary, AuthFixture() as auth:
        env = dict(os.environ)
        env.pop("DISPLAY", None)
        env.pop("WAYLAND_DISPLAY", None)
        for key in ["HOME", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR"]:
            path = Path(temporary) / key.lower()
            path.mkdir(mode=0o700)
            env[key] = str(path)
        env["CONTINUUM_NATIVE_ROOT"] = str(Path(temporary) / "native")
        commands = [
            ("import", [GODOT, "--headless", "--path", str(PROJECT), "--editor", "--import"], None),
            ("credential cache/HTTP", [GODOT, "--headless", "--path", str(PROJECT), "--script", "res://tools/credential_lifecycle_test.gd", "--", "--auth-fixture=" + auth.url], "CREDENTIAL_LIFECYCLE_PASS"),
            ("managed-server UI", [GODOT, "--headless", "--path", str(PROJECT), "--scene", "res://tools/managed_servers_test.tscn"], "MANAGED_SERVERS_PASS"),
            ("deletion locks/files", [sys.executable, str(ROOT / "scripts/internal/test-native-server-deletion.py")], None),
            ("module update locks/files", [sys.executable, str(ROOT / "scripts/internal/test-native-server-module-update.py")], None),
        ]
        for name, command, marker in commands:
            try:
                result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=120)
            except subprocess.TimeoutExpired:
                print(f"FAIL {name}: timeout", flush=True)
                return 1
            output = result.stdout + result.stderr
            errors = any("SCRIPT ERROR:" in line or line.startswith("ERROR:") for line in output.splitlines())
            if result.returncode or errors or (marker and marker not in output):
                print(f"FAIL {name}\n{output}", flush=True)
                return 1
            print(f"PASS {name}", flush=True)
        if not auth.verify():
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
