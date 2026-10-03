#!/usr/bin/env python3
"""Authoritative owned-server bootstrap gate, reusable from Python or shell.

SQL callbacks receive (statement, remaining_seconds) and return CLI JSON text.
Shell usage: python3 world_ready.py --timeout 300 -- COMMAND SQL_OPTIONS DB
Add --starter-origin to print authoritative "X Y" after readiness (legacy: 0 0).
The SQL statement is appended to COMMAND; no login/publish/reset is performed.
"""
import argparse
import json
import math
import os
import signal
import subprocess
import sys
import time

PHASES = ("Preparing", "Terrain", "Overview", "Validating", "Founding", "Ready", "Failed")


class WorldReadyError(RuntimeError):
    """Malformed state, SQL/transport failure, or generation error field."""


class WorldGenerationFailed(WorldReadyError):
    """The server explicitly entered Failed (not a polling timeout)."""


class WorldReadyTimeout(WorldReadyError):
    """The bounded bootstrap deadline expired."""


def decode_rows(raw):
    """Decode actual CLI SATS SQL JSON, including the schema's column names."""
    result = json.loads(raw)
    if not isinstance(result, list) or len(result) != 1:
        raise ValueError("expected one SQL result")
    entry = result[0]
    names = [field["name"]["some"] for field in entry["schema"]["elements"]]
    if len(set(names)) != len(names) or any(len(row) != len(names) for row in entry["rows"]):
        raise ValueError("invalid SQL row shape")
    return [dict(zip(names, row)) for row in entry["rows"]]


def wait_world_ready(sql, timeout=300, poll_interval=0.25, *,
                     clock=time.monotonic, sleep=time.sleep, report=None):
    """Wait for Ready+ready+founded colony, or an initialized legacy colony.

    Capability is positively queried from st_table, never inferred from query
    exceptions. A missing generation row only qualifies for legacy if colony id=0
    exists. Any generation row takes precedence over that legacy condition.
    Callbacks MUST honor their remaining-time argument to bound external IO.
    """
    if not math.isfinite(timeout) or timeout <= 0 or not math.isfinite(poll_interval) or poll_interval <= 0:
        raise ValueError("timeout and poll interval must be finite and positive")
    deadline = clock() + timeout
    last = "capability pending"

    def remaining():
        left = deadline - clock()
        if left <= 0:
            raise WorldReadyTimeout("world readiness deadline exceeded; " + last)
        return left

    def query(statement):
        budget = remaining()
        try:
            rows = decode_rows(sql(statement, budget))
        except Exception:
            # Never retain arbitrary command output/argv (possibly credentials).
            if clock() >= deadline:
                raise WorldReadyTimeout("world readiness deadline exceeded; " + last) from None
            raise WorldReadyError("world readiness SQL/schema error; " + last) from None
        remaining()
        return rows

    def announce(message):
        nonlocal last
        if message != last and report:
            report(message)
        last = message

    catalog = query("SELECT table_name FROM st_table")
    if any(not isinstance(row.get("table_name"), str) for row in catalog):
        raise WorldReadyError("invalid table capability response")
    tables = {row["table_name"] for row in catalog}
    if "colony" not in tables:
        raise WorldReadyError("world readiness schema lacks colony table")
    has_generation = "world_generation" in tables
    while True:
        generation = query("SELECT * FROM world_generation WHERE id = 0") if has_generation else []
        if len(generation) > 1:
            raise WorldReadyError("multiple generation singleton rows")
        if generation:
            row = generation[0]
            try:
                phase = row["phase"]
                ordinal = phase[0]
                if not isinstance(phase, list) or len(phase) != 2 or type(ordinal) is not int or not 0 <= ordinal < len(PHASES):
                    raise ValueError()
                if type(row["ready"]) is not bool or not isinstance(row["error"], str):
                    raise ValueError()
                counts = [row[key] for key in ("completed_chunks", "total_chunks", "completed_units", "total_units")]
                if any(type(count) is not int or count < 0 for count in counts):
                    raise ValueError()
            except (KeyError, TypeError, IndexError, ValueError):
                raise WorldReadyError("invalid world_generation state") from None
            announce(f"phase={PHASES[ordinal]} chunks={counts[0]}/{counts[1]} units={counts[2]}/{counts[3]} ready={row['ready']}")
            if ordinal == 6:
                raise WorldGenerationFailed("world generation Failed; " + last)
            if row["error"]:
                raise WorldReadyError("world generation error field is nonempty; " + last)
            if row["ready"] and ordinal != 5:
                raise WorldReadyError("world generation ready flag contradicts phase; " + last)
            if ordinal == 5 and row["ready"]:
                colony = query("SELECT id FROM colony WHERE id = 0")
                if colony == [{"id": 0}]:
                    return "Ready"
                announce(last + "; founding colony missing")
        else:
            colony = query("SELECT id FROM colony WHERE id = 0")
            if colony == [{"id": 0}]:
                announce("legacy initialized colony (generation " + ("row" if has_generation else "table") + " absent)")
                return "Legacy"
            announce("generation " + ("row" if has_generation else "table") + " missing; colony uninitialized")
        sleep(min(poll_interval, remaining()))


def world_starter_origin(sql, timeout=300, poll_interval=0.25, **kwargs):
    """Wait for playable state and return its authoritative starter XY.

    Reuse the exact generation row that satisfied readiness, not a separately
    queried or computed width-based origin. Only initialized legacy state can
    return (0, 0) without a generation row/table; errors never imply legacy.
    """
    generation = []

    def capture(statement, budget):
        nonlocal generation
        raw = sql(statement, budget)
        if statement == "SELECT * FROM world_generation WHERE id = 0":
            generation = decode_rows(raw)
        return raw

    mode = wait_world_ready(capture, timeout, poll_interval, **kwargs)
    if mode == "Legacy":
        return (0, 0)
    try:
        origin = (generation[0]["starter_x"], generation[0]["starter_y"])
        if any(type(value) is not int or value < 0 for value in origin):
            raise ValueError()
    except (KeyError, IndexError, ValueError):
        raise WorldReadyError("invalid or missing authoritative starter origin") from None
    return origin


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=float, default=300)
    parser.add_argument("--poll-interval", type=float, default=0.25)
    parser.add_argument("--starter-origin", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a SQL command prefix is required")

    def sql(statement, budget):
        process = subprocess.Popen([*command, statement], stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            stdout, _ = process.communicate(timeout=budget)
        except BaseException:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                process.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                process.stdout.close()
                process.stderr.close()
            raise
        if process.returncode:
            raise WorldReadyError("SQL command failed")
        return stdout

    try:
        wait = world_starter_origin if args.starter_origin else wait_world_ready
        value = wait(sql, args.timeout, args.poll_interval,
                     report=lambda message: print("WORLD_READY: " + message, file=sys.stderr, flush=True))
        if args.starter_origin:
            print(*value)
    except (WorldReadyError, ValueError) as error:
        print("WORLD_READY: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
