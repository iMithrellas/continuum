#!/usr/bin/env python3
"""Real reducer/persistence/authorization contracts in an owned disposable server.

Run after `just wasm`. Never connects to the user's colony or changes client files.
"""
import json
import os
import pathlib
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from world_ready import WorldReadyError, wait_world_ready

ROOT = pathlib.Path(__file__).resolve().parents[2]
NAME = "continuum-production-it-" + uuid.uuid4().hex[:12]
DB = "production-test"
OWNER = uuid.uuid4().hex
HOST = None
COMMAND_TIMEOUT = 45
AUTH_ERROR = "caller lacks the required colony role"
VALIDATION_ERROR = "Production target must be finite and in (0, 1000000]"


class GateFailure(Exception):
    """Only fixed, secret-free diagnostics cross the gate's reporting boundary."""


class GateInterrupted(GateFailure):
    pass


def interrupted(signum, _frame):
    raise GateInterrupted("interrupted by signal " + str(signum))


def stop_process(process):
    """Bounded group disposal also kills children of a stalled Docker client."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.communicate(timeout=2)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        process.communicate(timeout=2)
    except subprocess.TimeoutExpired:
        raise GateFailure("subprocess disposal failed") from None


def command(args, timeout=COMMAND_TIMEOUT):
    """Never report argv, captured output, or exception strings: they can contain tokens."""
    try:
        process = subprocess.Popen(args, text=True, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True)
    except OSError:
        raise GateFailure("subprocess launch failed") from None
    try:
        stdout, _stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        stop_process(process)
        raise GateFailure("subprocess timed out") from None
    except BaseException:
        stop_process(process)
        raise
    if process.returncode:
        raise GateFailure("subprocess returned nonzero")
    return stdout


def docker(*args):
    return command(["docker", *args])


def cleanup():
    """Resolve only our random name, verify its nonce label, remove its exact ID.

    Inventory errors are not interpreted as absence. A lost create response is
    safe: the name/nonce pair was chosen before creation. Never remove by port,
    image, prefix or an unverified container name.
    """
    ids = docker("container", "ls", "-aq", "--no-trunc", "--filter", "name=^/" + NAME + "$").split()
    if not ids:
        return
    if len(ids) != 1:
        raise GateFailure("owned container inventory ambiguous")
    cid = ids[0]
    info = json.loads(docker("inspect", cid))[0]
    if info["Name"] != "/" + NAME or info["Config"]["Labels"].get("continuum.production-owner") != OWNER:
        raise GateFailure("container ownership verification failed")
    docker("rm", "-f", cid)
    if docker("container", "ls", "-aq", "--no-trunc", "--filter", "id=" + cid).strip():
        raise GateFailure("owned container disposal not verified")


def cli(*args):
    return docker("exec", NAME, "spacetime", "--root-dir", "/tmp/production-cli", *args)


def call(name, *args):
    return cli("call", "-s", "http://127.0.0.1:3000", "--", DB, name,
               *(json.dumps(arg) for arg in args))


def rows(table):
    result = json.loads(cli("sql", "--format", "json", "-s", "http://127.0.0.1:3000",
                           DB, "SELECT * FROM " + table))[0]
    names = [element["name"]["some"] for element in result["schema"]["elements"]]
    return sorted((dict(zip(names, row)) for row in result["rows"]),
                  key=lambda row: json.dumps(row, sort_keys=True))


def wait_ready():
    try:
        wait_world_ready(
            lambda statement, budget: command([
                "docker", "exec", NAME, "spacetime", "--root-dir", "/tmp/production-cli",
                "sql", "--format", "json", "-s", "http://127.0.0.1:3000", DB, statement],
                timeout=min(COMMAND_TIMEOUT, budget)),
            report=lambda message: print("WORLD_READY: " + message, flush=True))
    except WorldReadyError as error:
        raise GateFailure(str(error)) from None


def request(path, data=None, token=None, timeout=30):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(HOST + path, data=data, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return response.read()


def rejection_matches(status, body, expected):
    """A transport/parser/trap failure is never evidence of reducer validation."""
    return status == 530 and body.strip() == expected


def require_audit(before, after, message):
    """An earlier grant mentioning the same caller cannot satisfy a policy audit."""
    ids = {event["id"] for event in before}
    delta = [event for event in after if event["id"] not in ids]
    if len(delta) != 1 or delta[0]["message"] != message:
        raise GateFailure("policy audit delta did not match exact action/resource/caller")


def user_call(token, name, *args, expected_error=None):
    try:
        request(f"/v1/database/{DB}/call/{name}", json.dumps(args).encode(), token)
    except urllib.error.HTTPError as error:
        body = error.read().decode()
        if not expected_error or not rejection_matches(error.code, body, expected_error):
            raise GateFailure("unexpected reducer rejection class") from None
        return
    if expected_error:
        raise GateFailure("reducer unexpectedly accepted rejected operation")


def run_gate():
    global HOST
    baseline = os.environ.get("CONTINUUM_BASELINE_WASM")
    mounts = ["-v", f"{pathlib.Path(baseline).resolve()}:/baseline.wasm:ro"] if baseline else []
    docker("create", "--name", NAME, "--label", "continuum.production-owner=" + OWNER,
           "-p", "127.0.0.1::3000",
           "-v", f"{ROOT / 'backend/spacetimedb/target/wasm32-unknown-unknown/release'}:/module:ro",
           *mounts,
           "clockworklabs/spacetime:v2.10.0", "start", "--listen-addr", "0.0.0.0:3000")
    docker("start", NAME)
    port = docker("port", NAME, "3000/tcp").strip().rsplit(":", 1)[1]
    HOST = "http://127.0.0.1:" + port
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        try:
            request("/v1/ping", timeout=1)
            break
        except (OSError, urllib.error.HTTPError):
            time.sleep(0.1)
    else:
        raise GateFailure("private server readiness deadline exceeded")
    cli("publish", "--yes", "-s", "http://127.0.0.1:3000", "-b",
        "/baseline.wasm" if baseline else "/module/continuum_module.wasm", DB)
    wait_ready()
    call("set_time_scale", 0)
    if baseline:
        old_operator = json.loads(request("/v1/identity", b""))
        call("set_operator", old_operator["identity"], True)
        legacy = {name: rows(name) for name in ("membership", "config", "colony", "work_order", "tile", "colonist", "item_stack")}
        cli("publish", "--yes", "--delete-data=never", "-s", "http://127.0.0.1:3000",
            "-b", "/module/continuum_module.wasm", DB)
        wait_ready()
        assert legacy == {name: rows(name) for name in legacy}, "additive migration changed existing save"
    assert rows("production_policy") == []
    # SQL encodes Identity as its one-field hex product; audit uses bare hex.
    admin = next(row for row in rows("membership") if row["role"][0] == 0)["identity"][0].removeprefix("0x")
    identity = json.loads(request("/v1/identity", b""))
    token = identity["token"]
    user_call(token, "set_production_policy", {"stone": []}, 7)
    user_call(token, "remove_production_policy", {"stone": []})
    user_call(token, "set_meal_policy", {"rationed": []})
    user_call(token, "set_meal_policy", {"normal": []})
    user_call(token, "set_haul_policy", {"dedicatedHaulers": []})
    user_call(token, "set_haul_policy", {"selfHaul": []})
    forest = next(row for row in rows("tile") if row["kind"][0] == 2)
    user_call(token, "set_work_order", forest["id"], {"logging": []}, 3, True)
    user_call(token, "set_tile_enabled", forest["id"], False)
    user_call(token, "set_tile_enabled", forest["id"], True)
    user_call(token, "set_time_scale", 0, expected_error=AUTH_ERROR)
    user_call(token, "reset_colony", expected_error=AUTH_ERROR)
    user_call(token, "expand_world", 25, 25, expected_error=AUTH_ERROR)
    user_call(token, "set_operator", ["0x" + identity["identity"]], True, expected_error=AUTH_ERROR)
    user_call(token, "grant_admin", ["0x" + identity["identity"]], expected_error=AUTH_ERROR)
    call("set_operator", identity["identity"], False)
    before = {name: rows(name) for name in ("production_policy", "work_order", "event_log")}
    for reducer, args in (("set_production_policy", ({"wood": []}, 10)),
                          ("remove_production_policy", ({"wood": []},))):
        user_call(token, reducer, *args, expected_error=AUTH_ERROR)
    assert before == {name: rows(name) for name in before}
    call("set_operator", identity["identity"], True)
    orders = rows("work_order")
    clock = rows("config")
    events = rows("event_log")
    user_call(token, "set_production_policy", {"wood": []}, 10)
    require_audit(events, rows("event_log"),
                  f"Production policy Wood target set to 10 by operator {identity['identity']}.")
    events = rows("event_log")
    call("set_production_policy", {"meat": []}, 20)
    require_audit(events, rows("event_log"),
                  f"Production policy Meat target set to 20 by operator {admin}.")
    saved = rows("production_policy")
    assert len(saved) == 2
    events = rows("event_log")
    user_call(token, "set_production_policy", {"wood": []}, 10)
    user_call(token, "remove_production_policy", {"stone": []})
    assert rows("event_log") == events
    for invalid in (0, -1, 1_000_001):
        user_call(token, "set_production_policy", {"wood": []}, invalid, expected_error=VALIDATION_ERROR)
        assert rows("production_policy") == saved
        assert rows("event_log") == events
    assert rows("work_order") == orders
    assert rows("config") == clock
    cli("publish", "--yes", "--delete-data=never", "-s", "http://127.0.0.1:3000",
        "-b", "/module/continuum_module.wasm", DB)
    wait_ready()
    assert rows("production_policy") == saved
    call("set_time_scale", 1)
    for attempt in range(100):
        if rows("config")[0]["game_seconds"] > clock[0]["game_seconds"]:
            break
        time.sleep(0.1)
    else:
        raise AssertionError("scheduled load/save did not advance")
    call("set_time_scale", 0)
    assert rows("production_policy") == saved, "tick overwrote policy intent"
    assert rows("work_order") == orders, "tick overwrote order enablement"
    events = rows("event_log")
    user_call(token, "remove_production_policy", {"wood": []})
    require_audit(events, rows("event_log"),
                  f"Production policy Wood removed by operator {identity['identity']}.")
    assert len(rows("production_policy")) == 1
    events = rows("event_log")
    user_call(token, "remove_production_policy", {"wood": []})
    assert rows("event_log") == events
    call("set_operator", identity["identity"], False)
    assert next(row for row in rows("membership")
                if row["identity"][0].removeprefix("0x") == identity["identity"])["role"][0] == 2
    before = {name: rows(name) for name in ("production_policy", "work_order", "event_log", "config")}
    call("set_operator", identity["identity"], False)
    user_call(token, "remove_production_policy", {"meat": []}, expected_error=AUTH_ERROR)
    user_call(token, "build_facility", forest["id"], {"recreation": []}, expected_error=AUTH_ERROR)
    user_call(token, "set_meal_policy", {"rationed": []}, expected_error=AUTH_ERROR)
    user_call(token, "set_work_order", forest["id"], {"logging": []}, 1, False, expected_error=AUTH_ERROR)
    user_call(token, "set_tile_enabled", forest["id"], False, expected_error=AUTH_ERROR)
    assert before == {name: rows(name) for name in before}
    memberships = rows("membership")
    cli("publish", "--yes", "--delete-data=never", "-s", "http://127.0.0.1:3000",
        "-b", "/module/continuum_module.wasm", DB)
    wait_ready()
    assert rows("membership") == memberships
    user_call(token, "remove_production_policy", {"meat": []}, expected_error=AUTH_ERROR)
    call("reset_colony")
    wait_ready()
    assert rows("production_policy") == []
    return bool(baseline)


def main():
    """Both gameplay success and verified cleanup are necessary for PASS.

    SIGINT/SIGTERM unwind active commands into finally. Repeated signals are
    ignored only during bounded cleanup, then original handlers are restored.
    No raw exception strings or command/output data are retained on failure.
    """
    handlers = {sig: signal.signal(sig, interrupted) for sig in (signal.SIGINT, signal.SIGTERM)}
    result = 1
    migration = False
    try:
        migration = run_gate()
        result = 0
    except GateFailure as error:
        print("FAIL: " + str(error), file=sys.stderr)
    except BaseException:
        print("FAIL: production contract execution failed", file=sys.stderr)
    finally:
        for sig in handlers:
            signal.signal(sig, signal.SIG_IGN)
        try:
            cleanup()
        except BaseException:
            print("FAIL: owned container cleanup failed; disposal unverified", file=sys.stderr)
            result = 1
        finally:
            for sig, handler in handlers.items():
                signal.signal(sig, handler)
    if result == 0:
        print("PASS: production policy authorization, atomic validation, exact audits, idempotence, persistence, reset and verified cleanup"
              + (", additive migration preserves seven legacy table snapshots including Admin/Operator membership" if migration else ""))
    return result


if __name__ == "__main__":
    sys.exit(main())
