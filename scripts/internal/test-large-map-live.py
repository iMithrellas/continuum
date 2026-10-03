#!/usr/bin/env python3
"""Own a private production runtime. Never build, reset or contact shared services."""
import os
from pathlib import Path
import socket
import signal
import subprocess
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
NATIVE = Path.home() / ".local/share/Continuum/native/spacetimedb/2.10.0"
WASM = Path(os.environ["CONTINUUM_STREAM_WASM"]).resolve()
RUN = ROOT / "client/godot/build/stream-live" / str(time.time_ns())
RUN.mkdir(parents=True)
env = dict(os.environ, HOME=str(RUN / "home"), XDG_CONFIG_HOME=str(RUN / "config"), XDG_DATA_HOME=str(RUN / "user-data"))
env.pop("DISPLAY", None)
env.pop("WAYLAND_DISPLAY", None)
Path(env["HOME"]).mkdir()
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
assert port != 3001
host = f"http://127.0.0.1:{port}"
db = "stream-private"
server = None

def cli(*args):
    result = subprocess.run([str(NATIVE / "spacetimedb-cli"), "--root-dir", str(RUN / "cli"), *args], env=env, capture_output=True, text=True, timeout=90)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout

def start(log):
    global server
    server = subprocess.Popen([str(NATIVE / "spacetimedb-standalone"), "start", "--listen-addr", f"127.0.0.1:{port}", "--data-dir", str(RUN / "data"), "--jwt-pub-key-path", str(RUN / "jwt.pub"), "--jwt-priv-key-path", str(RUN / "jwt"), "--non-interactive"], env=env, stdout=log, stderr=subprocess.STDOUT)
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if server.poll() is not None:
            raise RuntimeError("private runtime exited")
        try:
            with urllib.request.urlopen(host + "/v1/ping", timeout=1):
                return
        except OSError:
            time.sleep(0.1)
    raise RuntimeError("private runtime startup timed out")

def stop():
    if server is not None and server.poll() is None:
        server.terminate()
        try:
            server.wait(timeout=15)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait(timeout=10)

def gate(label, *args):
    command = ["python3", "client/godot/tools/map_client_x11.py", "--scene", "res://tools/large_map_live_test.tscn", "--", f"--stdb-host={host}", f"--stdb-db={db}", *args]
    with (RUN / f"{label}.log").open("w") as log:
        child = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = child.wait(timeout=150)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait(timeout=10)
            raise
    text = (RUN / f"{label}.log").read_text()
    for line in text.splitlines():
        if line.startswith(("LARGE_MAP_LIVE_", "LIVE_WAIT_DEBUG", "LIVE_PERF")):
            print(line)
    diagnostics = [line for line in text.splitlines() if line.startswith("ERROR:")]
    if diagnostics:
        print(f"RUNTIME_RENDER_DIAGNOSTICS count={len(diagnostics)} first={diagnostics[0]} log={RUN / f'{label}.log'}")
    if code:
        raise RuntimeError(f"{label} failed; evidence in {RUN}")

try:
    with (RUN / "runtime.log").open("w") as log:
        start(log)
        cli("publish", "--server", host, "--bin-path", str(WASM), "--yes", db)
        gate("fresh")
        stop()
        start(log)
        gate("restart")
        gate("disconnect-loading", "--disconnect-loading")
finally:
    stop()
print(f"PRIVATE_STREAM_LIVE_CORE_PASS evidence={RUN}")
