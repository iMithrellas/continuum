#!/usr/bin/env python3
"""Publish this checkout's WASM into exclusively owned persistent server state.

No SDK or GUI mock: authenticated reducer calls and SQL use the pinned real CLI.
Each CLI invocation ends its connection; the silent interval has no client at all.
Evidence survives cleanup; database state, tokens and extracted tools do not.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[2]
IMAGE = "clockworklabs/spacetime@sha256:3e3645a3ada6f77a64343fb062a06df4b5185816e145c8f1b57eaa9f2a37eb25"
# SATS sums use stable wire ordinals, avoiding CLI variant-name normalization.
DEDICATED_HAULERS, RATIONED, LOGGING = "[1, []]", "[1, []]", "[1, []]"
STORAGE, FOREST = "[3, []]", "[2, []]"
SNAPSHOT_TABLES = (
    "config", "world_seed", "speed_control", "colony", "tile", "terrain",
    "colonist", "item_stack", "world_geometry", "terrain_chunk", "terrain_material",
    "excavation_designation", "work_order", "production_policy", "alert", "event_log",
)


class Gate:
    """Own resources by direct process/container handles, never broad cleanup."""

    def __init__(self, evidence):
        self.root = evidence
        self.private = evidence / "private"
        self.private.mkdir(mode=0o700)
        self.process = None
        self.container = None
        self.server_output = None
        self.secrets = set()
        self.db = "connected-colony-" + uuid.uuid4().hex[:12]
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            self.port = sock.getsockname()[1]
        self.host = f"http://127.0.0.1:{self.port}"
        self.events = (evidence / "evidence.jsonl").open("w")

    def record(self, event, **fields):
        entry = dict(event=event, **fields)
        encoded = self.clean(json.dumps(entry, sort_keys=True))
        self.events.write(encoded + "\n")
        self.events.flush()
        print(encoded, flush=True)

    def clean(self, text):
        """Defense in depth for retained evidence, including exceptional output."""
        for secret in sorted(self.secrets, key=len, reverse=True):
            if not secret:
                continue
            text = text.replace(secret, "<redacted>")
        return text

    def safe_argv(self, argv):
        """Register sensitive values before spawn; diagnostic argv is never raw."""
        args = list(map(str, argv))
        for index, arg in enumerate(args):
            if arg == "--token" and index + 1 < len(args):
                self.secrets.add(args[index + 1])
            elif arg.startswith("--token="):
                self.secrets.add(arg.split("=", 1)[1])
        return self.clean(repr(args))

    def run(self, argv, timeout=60):
        """Bound subprocess groups too, including build children on timeout."""
        description = self.safe_argv(argv)
        process = None
        try:
            process = subprocess.Popen(list(map(str, argv)), cwd=ROOT,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       text=True, start_new_session=True)
            out, err = process.communicate(timeout=timeout)
        except BaseException as error:
            disposal_error = ""
            if process is not None:
                try:
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                    process.communicate(timeout=5)
                except Exception:
                    disposal_error = "; subprocess disposal could not be verified"
            if isinstance(error, Exception):
                # Suppress the original exception chain: TimeoutExpired carries
                # raw argv, and spawn errors/child output may echo credentials.
                reason = "timed out" if isinstance(error, subprocess.TimeoutExpired) else type(error).__name__
                raise RuntimeError(f"command {reason} (limit {timeout}s): {description}{disposal_error}") from None
            raise
        return subprocess.CompletedProcess(description, process.returncode, self.clean(out), self.clean(err))

    def checked(self, argv, timeout=60):
        result = self.run(argv, timeout)
        if result.returncode:
            raise RuntimeError(self.clean(f"command failed: {self.safe_argv(argv)}\n{result.stdout}\n{result.stderr}")) from None
        return result.stdout

    def tools(self):
        native = Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share"))) / "Continuum/native/spacetimedb/2.10.0"
        self.cli = Path(os.environ.get("SPACETIME_CLI", str(native / "spacetimedb-cli")))
        self.runtime = Path(os.environ.get("SPACETIME_RUNTIME", str(native / "spacetimedb-standalone")))
        if not (os.access(self.cli, os.X_OK) and os.access(self.runtime, os.X_OK)):
            if "SPACETIME_CLI" in os.environ or "SPACETIME_RUNTIME" in os.environ:
                raise RuntimeError("explicit SPACETIME_CLI/SPACETIME_RUNTIME must both be executable")
            self.checked(["docker", "image", "inspect", IMAGE], 15)
            self.container = self.checked(["docker", "create", "--pull=never", IMAGE], 15).strip()
            tools = self.private / "tools"
            tools.mkdir()
            for name in ("spacetimedb-cli", "spacetimedb-standalone"):
                self.checked(["docker", "cp", f"{self.container}:/opt/spacetime/{name}", tools / name], 30)
            self.remove_container()
            self.cli, self.runtime = tools / "spacetimedb-cli", tools / "spacetimedb-standalone"
        for tool in (self.cli, self.runtime):
            version = self.checked([tool, "--version"], 10).strip()
            if "2.10.0" not in version:
                raise RuntimeError(f"expected pinned 2.10.0 tooling: {version}")
            self.record("tool", version=version)

    def start(self):
        for name in ("data", "keys"):
            (self.private / name).mkdir(exist_ok=True)
        self.server_output = (self.root / "server.log").open("a")
        self.process = subprocess.Popen([
            str(self.runtime), "start", "--listen-addr", f"127.0.0.1:{self.port}",
            "--data-dir", str(self.private / "data"), "--jwt-pub-key-path", str(self.private / "keys/id.pub"),
            "--jwt-priv-key-path", str(self.private / "keys/id"), "--non-interactive"],
            stdout=self.server_output, stderr=subprocess.STDOUT, start_new_session=True)
        self.wait(self.healthy, "private server startup", 30)
        self.record("server_started", host=self.host, database=self.db, pid=self.process.pid)

    def stop(self):
        if self.process:
            pid = self.process.pid
            if self.process.poll() is None:
                self.process.send_signal(signal.SIGINT)
                try:
                    self.process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(pid, signal.SIGKILL)
                    self.process.wait(timeout=10)
            if self.process.poll() is None:
                raise RuntimeError(f"owned runtime {pid} did not exit; preserving private state")
            self.record("server_stopped", pid=pid, exit=self.process.returncode)
            self.process = None
        if self.server_output:
            self.server_output.close()
            self.server_output = None

    def healthy(self):
        if self.process.poll() is not None:
            raise RuntimeError("private runtime exited; see server.log")
        # Confirm the listener belongs to our PID before sending even a ping.
        # A random-port bind race must never publish to somebody else's server.
        sockets = set()
        for fd in Path(f"/proc/{self.process.pid}/fd").iterdir():
            try:
                sockets.add(os.readlink(fd))
            except FileNotFoundError:
                pass  # Runtime threads can close unrelated descriptors here.
        endpoint = f"0100007F:{self.port:04X}"
        owned = any(fields[1] == endpoint and fields[3] == "0A"
                    and f"socket:[{fields[9]}]" in sockets
                    for fields in (line.split() for line in Path("/proc/net/tcp").read_text().splitlines()[1:]))
        if not owned:
            return False
        try:
            with urllib.request.urlopen(self.host + "/v1/ping", timeout=1) as response:
                return response.status == 200
        except OSError:
            return False

    def wait(self, predicate, label, timeout=60):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if predicate():
                return
            time.sleep(0.2)
        raise AssertionError(f"timed out: {label}")

    def command(self, *args, user="admin", reject=False, timeout=30):
        argv = [self.cli, "--root-dir", self.private / user, *map(str, args)]
        self.safe_argv(argv)
        try:
            result = self.run(argv, timeout)
        except Exception as error:
            if args[0] == "login":
                raise RuntimeError("private CLI identity login failed exceptionally (credentials redacted)") from None
            raise RuntimeError(self.clean(str(error))) from None
        if reject:
            error = (result.stderr + result.stdout).lower()
            expected = "caller lacks the required colony role"
            assert result.returncode and expected in error, self.clean(error)
            self.record("authorization_rejected", reducer=args[5] if len(args) > 5 else "unknown",
                        user=user, expected_reason=expected)
        elif result.returncode:
            if args[0] == "login":
                raise RuntimeError("private CLI identity login failed (token output redacted)")
            raise RuntimeError(self.clean(f"CLI failed: {args}\n{result.stdout}\n{result.stderr}")) from None
        return self.clean(result.stdout)

    def call(self, name, *args, user="admin", reject=False):
        encoded = [json.dumps(arg) if isinstance(arg, bool) else str(arg) for arg in args]
        return self.command("call", "-s", self.host, "--", self.db, name, *encoded, user=user, reject=reject)

    def rows(self, table, user="admin", timeout=30):
        result = json.loads(self.command("sql", "--format", "json", "-s", self.host,
                                         self.db, "SELECT * FROM " + table, user=user, timeout=timeout))[0]
        names = [field["name"]["some"] for field in result["schema"]["elements"]]
        return sorted([dict(zip(names, row)) for row in result["rows"]],
                      key=lambda row: json.dumps(row, sort_keys=True))

    def identity(self, user):
        request = urllib.request.Request(self.host + "/v1/identity", method="POST")
        with urllib.request.urlopen(request, timeout=5) as response:
            identity = json.load(response)
        self.command("login", "--token", identity["token"], user=user)
        return identity["identity"]

    def snapshot(self):
        """Explicit 16-table restart oracle, bounded to 90 seconds per snapshot.

        Sender-scoped my_role and private membership/jobs/schedule are not SQL
        snapshots. Role durability is proved separately by authorized reducers.
        """
        deadline = time.monotonic() + 90
        result = {}
        for name in SNAPSHOT_TABLES:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError("public-table snapshot exceeded 90 seconds")
            result[name] = self.rows(name, timeout=min(30, remaining))
        return result

    def baseline(self, wasm):
        self.identity("admin")
        operator = self.identity("operator")
        viewer = self.identity("viewer")
        self.command("publish", "--yes", "-s", self.host, "-b", wasm, self.db)
        self.call("set_time_scale", 0)
        self.call("set_speed_change_cooldown", 0)
        self.call("set_operator", json.dumps(viewer), False)
        tiles = self.rows("tile")
        forest = next(tile for tile in tiles if tile["kind"][0] == 2)
        before = self.snapshot()
        for reducer, args in (("set_time_scale", (600,)),
                              ("set_haul_policy", (DEDICATED_HAULERS,)),
                              ("set_work_order", (forest["id"], LOGGING, 3, True))):
            self.call(reducer, *args, user="viewer", reject=True)
        assert self.snapshot() == before, "unauthorized reducer mutated state"
        self.call("set_operator", json.dumps(operator), True)
        self.call("set_time_scale", 600, user="operator", reject=True)
        self.call("set_haul_policy", DEDICATED_HAULERS, user="operator")
        self.call("set_meal_policy", RATIONED, user="operator")
        self.call("set_zone_enabled", STORAGE, False, user="operator")
        self.call("set_work_order", forest["id"], LOGGING, 3, True, user="operator")
        intents = self.rows("work_order")
        config = self.rows("config")[0]
        assert config["haul_policy"][0] == config["meal_policy"][0] == 1, config
        assert all(not tile["enabled"] for tile in self.rows("tile") if tile["kind"][0] == 3)
        assert any(order["tile_id"] == forest["id"] and order["work"][0] == 1
                   and order["priority"] == 3 and order["enabled"] for order in intents), intents
        self.record("controlled_setup", config=config, order_count=len(intents))
        self.call("set_time_scale", 600)
        # No process/HTTP/SQL/subscription exists during this interval. Query only
        # after reconnecting; scheduled reducers must advance without a client.
        time.sleep(4)
        self.call("set_time_scale", 0)
        after = self.rows("config")[0]
        assert after["game_seconds"] >= config["game_seconds"] + 1200, after
        assert self.rows("work_order", user="operator") == intents
        self.record("disconnected_ticks_pass", before=config["game_seconds"], after=after["game_seconds"], silent_wall_seconds=4)

        def ground():
            return [row for row in self.rows("item_stack") if row["kind"][0] == 1 and row["amount"] > 0]

        self.call("set_time_scale", 600)
        self.wait(ground, "logging produced ground wood", 60)
        self.call("set_time_scale", 0)
        self.call("set_zone_enabled", FOREST, False, user="operator")
        piles = ground()
        assert piles, "wood disappeared with storage disabled"
        bodies = self.rows("colonist")
        assert not any(body["carried_amount"] > 0 for body in bodies), "pickup occurred without storage"
        stored_before = self.rows("colony")[0]["wood"]
        total = stored_before + sum(row["amount"] for row in piles)
        self.record("ground_pass", piles=piles, stored_wood=stored_before, total_wood=total)
        self.call("set_zone_enabled", STORAGE, True, user="operator")
        self.call("set_time_scale", 60)

        def carrying():
            return [body for body in self.rows("colonist") if body["carried_kind"][0] == 1 and body["carried_amount"] > 0]

        self.wait(carrying, "ground wood picked up", 90)
        self.call("set_time_scale", 0)
        carriers = carrying()
        assert carriers, "carried state missed; use slower sample speed"
        self.record("carried_pass", carriers=carriers)
        self.call("set_time_scale", 600)
        self.wait(lambda: self.rows("colony")[0]["wood"] > stored_before, "wood delivered into storage", 60)
        self.call("set_time_scale", 0)
        colony = self.rows("colony")[0]
        remaining = sum(row["amount"] for row in ground()) + sum(body["carried_amount"] for body in carrying())
        assert abs(colony["wood"] + remaining - total) < 0.01, (colony, remaining, total)
        assert self.rows("work_order") == intents, "ticks rewrote persistent order intents"
        self.record("stored_pass", stored_wood=colony["wood"], remaining_wood=remaining, conserved_total=total)
        self.call("set_production_policy", "[3, []]", 12345, user="operator")
        persisted = self.snapshot()
        (self.root / "paused-snapshot.json").write_text(json.dumps(persisted, indent=2))
        self.stop()
        self.start()
        assert self.snapshot() == persisted, "restart changed paused persistent state"
        assert self.rows("work_order", user="operator") == intents
        self.call("set_work_order", forest["id"], LOGGING, 3, True, user="operator")
        self.call("set_production_policy", "[3, []]", 12345, user="operator")
        self.call("set_time_scale", 0)
        self.call("set_time_scale", 600, user="viewer", reject=True)
        assert self.snapshot() == persisted, "post-restart authorization no-ops changed state"
        self.record("restart_persistence_pass", tables=list(persisted),
                    operator_authorized_noops=True, admin_authorized_noop=True)

    def remove_container(self):
        """Keep the exact owned handle until checked removal AND proven absence."""
        if self.container:
            owned = self.container
            self.checked(["docker", "rm", owned], 15)
            inspection = self.run(["docker", "container", "inspect", owned], 15)
            error = (inspection.stderr + inspection.stdout).lower()
            absent = any(f"no such {kind}: {owned}" in error for kind in ("container", "object"))
            if not inspection.returncode or not absent:
                raise RuntimeError(f"owned container absence not verified: {owned}")
            self.record("owned_container_removed", container=owned, absence_verified=True)
            self.container = None

    def close(self, successful=False):
        """Attempt independent bounded disposal; no pass if any resource remains.

        If the runtime cannot be stopped, retain its private data for safe retry.
        Docker failure never prevents independent runtime/directory cleanup.
        """
        failures = []
        try:
            try:
                self.stop()
            except Exception as error:
                failures.append("runtime: " + self.clean(str(error)))
            try:
                self.remove_container()
            except Exception as error:
                failures.append("container: " + self.clean(str(error)))
            try:
                if self.process is not None:
                    raise RuntimeError("runtime exit unverified; private state retained")
                if self.private.exists():
                    shutil.rmtree(self.private)
                if self.private.exists():
                    raise RuntimeError("private directory still exists")
            except Exception as error:
                failures.append("private state: " + self.clean(str(error)))
            if failures:
                self.record("cleanup_failed", failures=failures, owned_container=self.container,
                            owned_pid=self.process.pid if self.process else None,
                            private_state_removed=not self.private.exists())
                raise RuntimeError("owned cleanup failed: " + "; ".join(failures)) from None
            self.record("cleanup_pass", private_state_removed=True, runtime_exit_verified=True,
                        container_absence_verified=True)
            if successful:
                self.record("CONNECTED_COLONY_PASS")
        finally:
            self.events.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-timeout", type=int, default=300)
    args = parser.parse_args()
    def interrupted(signum, _frame):
        raise KeyboardInterrupt(f"gate interrupted by signal {signum}")
    signal.signal(signal.SIGTERM, interrupted)
    evidence = Path(tempfile.mkdtemp(prefix="continuum-connected-gate-", dir="/tmp/opencode"))
    print(f"CONNECTED_GATE_EVIDENCE={evidence}", flush=True)
    gate = Gate(evidence)
    completed = False
    try:
        gate.tools()
        result = gate.run(["cargo", "build", "--locked", "--manifest-path", ROOT / "backend/spacetimedb/Cargo.toml",
                           "--target-dir", ROOT / "backend/spacetimedb/target",
                           "--release", "--target", "wasm32-unknown-unknown"], args.build_timeout)
        (evidence / "build.log").write_text(result.stdout + result.stderr)
        assert result.returncode == 0, "WASM build failed; see build.log"
        wasm = ROOT / "backend/spacetimedb/target/wasm32-unknown-unknown/release/continuum_module.wasm"
        gate.record("build_pass", sha256=hashlib.sha256(wasm.read_bytes()).hexdigest())
        gate.start()
        gate.baseline(wasm)
        log = (evidence / "server.log").read_text().lower()
        assert not any(word in log for word in ("runtime error", "fuel exhausted", "wasm trap")), "runtime errors in server.log"
        completed = True
    except Exception as error:
        gate.record("CONNECTED_COLONY_FAIL", error=str(error))
        raise RuntimeError(gate.clean(str(error))) from None
    finally:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        gate.close(successful=completed)


if __name__ == "__main__":
    main()
