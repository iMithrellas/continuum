#!/usr/bin/env python3
"""Strict backend-free gameplay contracts (no server or visual-menu gates).

CHECKS preserves the original just test-gameplay-client list/order, then adds
the actual production world binding/schema and SDK u64 bit-pattern contracts.
Each run retains logs in a unique /tmp/opencode directory with private HOME/XDG.
Import has no Godot PASS marker; it requires clean, bounded successful completion.
Planning's existing zero-failures summary is its success marker (no invented PASS).
Offline runner regressions: python3 client/godot/tools/gameplay_client_checks_fault_test.py
"""
import argparse
from contextlib import contextmanager
from dataclasses import dataclass
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time

PROJECT = Path(__file__).resolve().parents[1]
CHECKS = (
    ("enum_key_cache_test", "script", r"ENUM_KEY_CACHE_PASS: .+"),
    ("unit_enum_key_contract_test", "script", r"UNIT_ENUM_KEY_CONTRACT_PASS: .+"),
    ("production_policy_bindings_test", "script", r"PRODUCTION_POLICY_BINDINGS_PASS: .+"),
    ("building_properties_bindings_test", "script", r"BUILDING_PROPERTIES_BINDINGS_PASS: .+"),
    ("operator_access_test", "script", r"OPERATOR_ACCESS_PASS"),
    ("colony_operations_model_test", "script", r"COLONY_OPERATIONS_MODEL_PASS"),
    ("production_suitability_test", "script", r"PRODUCTION_SUITABILITY_PASS"),
    ("large_map_foundations_test", "script", r"LARGE_MAP_FOUNDATIONS_PASS: \d+ assertions"),
    ("large_map_wire_test", "scene", r"LARGE_MAP_WIRE_PASS: \d+ assertions"),
    ("sdk_subscription_cache_test", "script", r"SDK_SUBSCRIPTION_CACHE_PASS: .+"),
    ("colony_guidance_test", "scene", r"COLONY_GUIDANCE_TEST: PASS"),
    ("production_targets_test", "scene", r"PRODUCTION_TARGETS_PASS"),
    ("production_wiring_test", "scene", r"PRODUCTION_WIRING_TEST: PASS"),
    ("map_feedback_test", "scene", r"MAP_FEEDBACK_PASS: \d+ assertions"),
    ("map_inspector_test", "scene", r"MAP_INSPECTOR_TEST_PASS assertions=\d+ failures=0"),
    ("planning_test", "scene", r"PLANNING_TEST \d+ assertions, 0 failures"),
    ("ux_panels_test", "script", r"UX_PANELS_PASS checks=\d+ failures=0"),
    ("world_bindings_test", "script", r"WORLD_BINDINGS_PASS: .+"),
    ("world_bindings_schema_test", "script", r"WORLD_BINDINGS_SCHEMA_PASS: .+"),
    ("sdk_u64_bitpatterns_test", "script", r"SDK_U64_BITPATTERNS_PASS: .+"),
)
ERRORS = re.compile(
    r"SCRIPT ERROR:|^ERROR:|\bObjectDB\s+instances?\s+(?:(?:was|were)\s+)?leaked\b|resources still in use at exit|"
    r"orphan(?:ed)? (?:nodes?|objects?)|(?:nodes?|objects?|resources?) leaked",
    re.MULTILINE | re.IGNORECASE,
)
FAILURE_MARKERS = re.compile(r"\b[A-Z][A-Z0-9_]*_FAIL\b|_TEST: FAIL\b")


class Cancelled(Exception):
    pass


@dataclass
class Result:
    name: str
    passed: bool
    reason: str
    elapsed: float
    log: Path


def log_problem(text, marker):
    if ERRORS.search(text):
        return "runtime error or leak diagnostic"
    if FAILURE_MARKERS.search(text):
        return "failure marker"
    if marker is not None and not re.search(r"^(?:" + marker + r")$", text, re.MULTILINE):
        return "missing expected success marker"
    return ""


def group_alive(pgid):
    """Inspect only our exact process group; zombies no longer hold resources.

    /proc allows Linux orphan zombies to be distinguished from running children.
    On other POSIX hosts conservatively use killpg(0), never a global process scan
    for cleanup targets. Actual signals always target the spawned session's PGID.
    """
    proc = Path("/proc")
    if proc.is_dir():
        for entry in proc.iterdir():
            if not entry.name.isdigit():
                continue
            try:
                fields = (entry / "stat").read_text().rsplit(")", 1)[1].split()
                if int(fields[2]) == pgid and fields[0] not in ("Z", "X"):
                    return True
            except (FileNotFoundError, ProcessLookupError):
                continue
        return False
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    return True


@contextmanager
def uninterrupted_cleanup():
    handlers = {sig: signal.signal(sig, signal.SIG_IGN) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        yield
    finally:
        for sig, handler in handlers.items():
            signal.signal(sig, handler)


def dispose_group(process, grace=0.5, kill_timeout=2):
    """Terminate/grace/kill only this owned session, even if its leader exited."""
    with uninterrupted_cleanup():
        for sig, budget in ((signal.SIGTERM, grace), (signal.SIGKILL, kill_timeout)):
            if group_alive(process.pid):
                try:
                    os.killpg(process.pid, sig)
                except ProcessLookupError:
                    pass
            end = time.monotonic() + budget
            while True:
                process.poll()
                if not group_alive(process.pid):
                    process.wait(timeout=max(0.01, end - time.monotonic()))
                    return
                if time.monotonic() >= end:
                    break
                time.sleep(max(0, min(0.02, end - time.monotonic())))
        raise RuntimeError("owned process group disposal unverified")


def run_check(name, command, marker, timeout, env, output):
    """Retain each result; errors, timeout and cancellation cannot bypass disposal."""
    start = time.monotonic()
    log = output / (name + ".log")
    process = None
    reason = ""
    cancelled = None
    try:
        # Direct file output avoids communicate() hanging on a child's inherited
        # pipe after the Godot leader has exited. Also preserves partial crash logs.
        with log.open("w") as stream:
            process = subprocess.Popen(command, env=env, stdout=stream, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            deadline = start + timeout
            while process.poll() is None:
                text = log.read_text(errors="replace")
                if ERRORS.search(text) or FAILURE_MARKERS.search(text):
                    reason = log_problem(text, None)
                    break
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    reason = f"wall timeout ({timeout:g}s)"
                    break
                try:
                    process.wait(timeout=min(0.1, remaining))
                except subprocess.TimeoutExpired:
                    pass
            if not reason:
                if process.returncode != 0:
                    reason = f"nonzero exit ({process.returncode})"
                elif group_alive(process.pid):
                    reason = "leaked child process"
    except (Cancelled, KeyboardInterrupt) as error:
        reason = "cancelled"
        cancelled = error
    except Exception:
        reason = "subprocess/log execution error"
    finally:
        if process is not None:
            try:
                dispose_group(process)
            except Exception:
                reason = (reason + "; " if reason else "") + "owned process group disposal unverified"
    if not reason:
        reason = log_problem(log.read_text(errors="replace"), marker)
    success = "clean import completion" if marker is None else "clean exit and success marker"
    result = Result(name, not reason, reason or success, time.monotonic() - start, log)
    line = f"{'PASS' if result.passed else 'FAIL'} {name} elapsed_s={result.elapsed:.2f} {result.reason}"
    print(line, flush=True)
    with (output / "summary.log").open("a") as stream:
        stream.write(line + "\n")
    if cancelled is not None:
        raise cancelled
    return result


def private_environment(state):
    env = dict(os.environ)
    env.pop("DISPLAY", None)
    env.pop("WAYLAND_DISPLAY", None)
    for key, leaf in (("HOME", "home"), ("XDG_DATA_HOME", "data"), ("XDG_CONFIG_HOME", "config"),
                      ("XDG_CACHE_HOME", "cache"), ("XDG_RUNTIME_DIR", "runtime"), ("TMPDIR", "tmp")):
        path = state / leaf
        path.mkdir(mode=0o700)
        env[key] = str(path)
    return env


def positive_seconds(value):
    seconds = float(value)
    if not math.isfinite(seconds) or seconds <= 0:
        raise argparse.ArgumentTypeError("timeout must be finite and positive")
    return seconds


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--import-timeout", type=positive_seconds, default=120)
    parser.add_argument("--test-timeout", type=positive_seconds, default=120)
    args = parser.parse_args(argv)
    output = Path(tempfile.mkdtemp(prefix="continuum-gates-gameplay-", dir="/tmp/opencode"))
    env = private_environment(output)
    base = [os.environ.get("GODOT", "godot"), "--headless", "--path", str(PROJECT)]
    print("Evidence: " + str(output), flush=True)

    def interrupt(signum, _frame):
        raise Cancelled(f"signal {signum}")

    handlers = {sig: signal.signal(sig, interrupt) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        if not run_check("import", [*base, "--editor", "--import"], None, args.import_timeout, env, output).passed:
            print("FAIL gameplay suite: import blocked; tests not run", flush=True)
            return 1
        failures = []
        for name, mode, marker in CHECKS:
            suffix = "tscn" if mode == "scene" else "gd"
            result = run_check(name, [*base, "--" + mode, f"res://tools/{name}.{suffix}"],
                               marker, args.test_timeout, env, output)
            if not result.passed:
                failures.append(name)
                if "disposal unverified" in result.reason:
                    print("FAIL gameplay suite: cleanup unverified; remaining tests not run", flush=True)
                    return 1
        print("FAIL gameplay suite: " + ", ".join(failures) if failures else "GAMEPLAY_CLIENT_CHECKS_PASS", flush=True)
        return int(bool(failures))
    except (Cancelled, KeyboardInterrupt):
        print("FAIL gameplay suite: cancelled; see per-check disposal result", flush=True)
        return 1
    finally:
        for sig, handler in handlers.items():
            signal.signal(sig, handler)


if __name__ == "__main__":
    raise SystemExit(main())
