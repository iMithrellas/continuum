#!/usr/bin/env python3
"""Own a disposable native server; prove additive construction/usage contracts.

CONTINUUM_BASELINE_WASM enables the non-destructive upgrade gate.
--generate-bindings regenerates only against this private published schema.
No live endpoint, existing runtime, database reset or shared native assets are used.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / "backend/spacetimedb/target"
NATIVE = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "Continuum/native/spacetimedb/2.10.0"
CLI = os.environ.get("SPACETIME_CLI", str(NATIVE / "spacetimedb-cli"))
RUNTIME = os.environ.get("SPACETIME_RUNTIME", str(NATIVE / "spacetimedb-standalone"))
WASM = TARGET / "wasm32-unknown-unknown/release/continuum_module.wasm"
DB = "continuum-building-properties-test"
TABLES = ("config", "colony", "world_seed", "tile", "terrain", "colonist",
          "work_order", "item_stack", "world_geometry", "terrain_chunk",
          "terrain_material", "excavation_designation", "excavation_jobs",
          "production_policy", "membership", "speed_control", "alert", "event_log")


def wait_until(predicate, message, timeout=120):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.2)
    raise AssertionError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--generate-bindings", action="store_true")
    args = parser.parse_args()
    baseline = os.environ.get("CONTINUUM_BASELINE_WASM")
    assert WASM.is_file(), "run just wasm first"
    assert Path(CLI).is_file() and Path(RUNTIME).is_file(), "set SPACETIME_CLI / SPACETIME_RUNTIME"
    TARGET.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="building-integration-", dir=TARGET) as temporary:
        tmp = Path(temporary)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        host = f"http://127.0.0.1:{port}"
        server = None
        logfile = (tmp / "server.log").open("w")

        def start():
            nonlocal server
            server = subprocess.Popen([
                RUNTIME, "start", "--listen-addr", f"127.0.0.1:{port}",
                "--data-dir", str(tmp / "data"), "--jwt-pub-key-path", str(tmp / "id.pub"),
                "--jwt-priv-key-path", str(tmp / "id"), "--non-interactive",
            ], stdout=logfile, stderr=subprocess.STDOUT)

            def healthy():
                if server.poll() is not None:
                    raise AssertionError("private runtime exited")
                try:
                    with urllib.request.urlopen(host + "/v1/ping", timeout=1) as response:
                        return response.status == 200
                except OSError:
                    return False
            wait_until(healthy, "private runtime did not start", 30)

        def stop():
            if server and server.poll() is None:
                server.terminate()
                try:
                    server.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait(timeout=10)

        def cli(*values, user="admin", fail=False):
            result = subprocess.run([CLI, "--root-dir", str(tmp / user), *map(str, values)],
                                    capture_output=True, text=True, timeout=90)
            if fail:
                assert result.returncode != 0, (values, "unexpected success")
                if user == "viewer":
                    assert "caller lacks the required colony role" in (result.stdout + result.stderr).lower()
            else:
                assert result.returncode == 0, (values, result.stdout, result.stderr)
            return result.stdout

        def call(name, *values, **options):
            values = [json.dumps(v) if isinstance(v, (dict, bool)) else v for v in values]
            return cli("call", "-s", host, "--", DB, name, *values, **options)

        def rows(query):
            result = json.loads(cli("sql", "--format", "json", "-s", host, DB, query))[0]
            names = [column["name"]["some"] for column in result["schema"]["elements"]]
            return sorted((dict(zip(names, row)) for row in result["rows"]),
                          key=lambda row: json.dumps(row, sort_keys=True))

        def table(name):
            return rows("SELECT * FROM " + name)

        def snapshot(names=TABLES):
            return {name: table(name) for name in names}

        def wood():
            return table("colony")[0]["wood"]

        def settle_paused():
            # Historical tick maintenance trims pause events and lazily backfills
            # ecology for mining-created anchors, even at time_scale=0.
            wait_until(lambda: len(table("event_log")) <= 200
                       and {t["id"] for t in table("tile")} <= {t["tile_id"] for t in table("terrain")},
                       "paused scheduler maintenance did not settle")

        def tile_at(x, y, z=0):
            return next(t for t in table("tile") if (t["x"], t["y"], t["z"]) == (x, y, z))

        usage = lambda name: {name: {}}
        all_tables = TABLES + ("building", "building_thermal_property")
        try:
            start()
            cli("publish", "--yes", "-s", host, "-b", baseline or WASM, DB)
            call("set_time_scale", 0)
            identities = {}
            for user in ("viewer", "operator"):
                request = urllib.request.Request(host + "/v1/identity", method="POST")
                with urllib.request.urlopen(request, timeout=5) as response:
                    identity = json.load(response)
                identities[user] = identity["identity"]
                cli("login", "--token", identity["token"], user=user)
                call("set_operator", json.dumps(identity["identity"]), user == "operator")
            call("designate_excavation", 9, 0, 9, 0, -1, 1, 1)
            hole = max(table("excavation_designation"), key=lambda d: d["id"])
            call("set_time_scale", 3600)
            wait_until(lambda: wood() >= 180 and next(d for d in table("excavation_designation")
                                                     if d["id"] == hole["id"])["completed_cells"] == 1,
                       "workers did not supply wood and excavate the fixture")
            call("set_time_scale", 0)
            # Pause itself logs an event after the last tick's trim. Wait for the
            # existing scheduler's maintenance before comparing migration rows.
            settle_paused()
            before_upgrade = snapshot()
            if baseline:
                cli("publish", "--yes", "--delete-data=never", "-s", host, "-b", WASM, DB)
                after_upgrade = snapshot()
                assert after_upgrade == before_upgrade, (
                    "upgrade rewrote existing state", {
                        t: (before_upgrade[t][:2], after_upgrade[t][:2], len(before_upgrade[t]), len(after_upgrade[t]))
                        for t in TABLES if before_upgrade[t] != after_upgrade[t]})
                assert not table("building") and not table("building_thermal_property")
                print("BUILDING_ADDITIVE_MIGRATION_PASS: 18 legacy table snapshots identical")

            before = snapshot(all_tables)
            for name, values in (
                ("construct_room", (0, 0, 1, 1, 0, 6)),
                ("demolish_building", (1,)),
                ("designate_zone_at", (0, 0, 1, 1, 0, usage("storage"))),
                ("clear_zone", (1,)),
            ):
                call(name, *values, user="viewer", fail=True)
            assert snapshot(all_tables) == before

            before = snapshot()
            stored = wood()
            call("construct_room", 1, 1, 0, 0, 0, 6, user="operator")
            first = table("building")[0]
            assert (first["x"], first["y"], first["width"], first["depth"], first["wood_cost"]) == (0, 0, 2, 2, 20)
            assert wood() == stored - 20
            assert table("building_thermal_property") == [{
                # SpacetimeDB SQL canonicalizes the numeric unit token m2 to m_2.
                "building_id": first["id"], "thermal_resistance_m_2_k_per_w": 2.0}], table("building_thermal_property")
            after = snapshot()
            assert all(after[t] == before[t] for t in TABLES if t != "colony")
            expected_colony = dict(before["colony"][0], wood=stored - 20)
            assert after["colony"] == [expected_colony]
            before = snapshot(all_tables)
            call("designate_zone_at", 0, 0, 1, 1, 0, usage("storage"), user="operator")
            after = snapshot(all_tables)
            assert all(after[t] == before[t] for t in all_tables if t != "tile")
            for y in range(2):
                for x in range(2):
                    assert tile_at(x, y)["kind"][0] == 3
                    assert tile_at(x, y)["id"] == 1 + x + 24 * y
            before = snapshot(all_tables)
            call("set_tile_enabled", 1, False)
            before = snapshot(all_tables)
            call("designate_zone_at", 0, 0, 1, 1, 0, usage("storage"))
            assert snapshot(all_tables) == before, "idempotent designation changed enablement"

            call("designate_zone_at", 2, 0, 3, 1, 0, usage("storage"))
            call("construct_room", 2, 0, 3, 1, 0, 6)
            second = max(table("building"), key=lambda b: b["id"])
            before = snapshot(all_tables)
            call("clear_zone", tile_at(2, 0)["id"])
            after = snapshot(all_tables)
            assert all(after[t] == before[t] for t in all_tables if t != "tile")
            assert tile_at(2, 0)["kind"][0] == 0
            before = snapshot(all_tables)
            call("clear_zone", tile_at(2, 0)["id"])
            assert snapshot(all_tables) == before
            call("demolish_building", second["id"])
            assert table("tile") == before["tile"] and wood() == before["colony"][0]["wood"]
            assert all(p["building_id"] != second["id"] for p in table("building_thermal_property"))
            call("construct_room", 2, 0, 3, 1, 0, 6)
            assert max(b["id"] for b in table("building")) > second["id"]

            forest = next(t for t in table("tile") if t["kind"][0] == 2
                          and any(s["tile_id"] == t["id"] for s in table("item_stack")))
            before = snapshot(all_tables)
            call("clear_zone", forest["id"])
            after = snapshot(all_tables)
            assert all(after[t] == before[t] for t in all_tables if t not in ("tile", "work_order"))
            assert not any(o["tile_id"] == forest["id"] for o in table("work_order"))
            assert tile_at(forest["x"], forest["y"])["id"] == forest["id"]
            call("designate_zone_at", forest["x"], forest["y"], forest["x"], forest["y"], 0, usage("forest"))
            assert table("item_stack") == before["item_stack"]

            call("place_facility", 4, 0, 0, usage("storage"), 2, 2, 6)
            before = snapshot(all_tables)
            rejected = [
                ("construct_room", (0, 0, 1, 1, 0, 6)),
                ("construct_room", (0, 0, 100, 100, 0, 6)),
                ("construct_room", (6, 0, 15, 7, 0, 6)),
                ("construct_room", (-1, 0, 0, 0, 0, 6)),
                ("construct_room", (6, 0, 6, 0, 0, 3)),
                ("construct_room", (6, 0, 6, 0, 0, 65535)),
                ("construct_room", (6, 0, 6, 0, 13, 4)),
                ("construct_room", (6, 0, 6, 0, -16, 4)),
                ("construct_room", (8, 0, 9, 0, 0, 6)),
                ("designate_zone_at", (5, 1, 5, 1, 0, usage("storage"))),
                ("designate_zone_at", (5, 1, 5, 1, 4, usage("farm"))),
                ("designate_zone_at", (0, 0, 1, 1, 0, usage("farm"))),
                ("designate_zone_at", (8, 0, 9, 0, 0, usage("storage"))),
                ("designate_zone_at", (6, 0, 6, 0, 0, usage("empty"))),
                ("designate_zone_at", (6, 0, 6, 0, 2147483647, usage("storage"))),
                ("designate_zone_at", (0, 0, 100, 100, 0, usage("storage"))),
                ("clear_zone", (4294967295,)),
                ("demolish_building", (18446744073709551615,)),
            ]
            for name, values in rejected:
                call(name, *values, fail=True)
            assert snapshot(all_tables) == before, "failed intents committed partial writes"

            call("construct_room", 6, 0, 6, 0, 0, 6)
            support_room = max(table("building"), key=lambda b: b["id"])
            call("designate_excavation", 6, 0, 6, 0, -1, 1, 1)
            excavation = max(table("excavation_designation"), key=lambda d: d["id"])
            started = table("config")[0]["game_seconds"]
            call("set_time_scale", 600)
            wait_until(lambda: table("config")[0]["game_seconds"] >= started + 2400,
                       "simulation did not advance for support protection")
            call("set_time_scale", 0)
            assert next(d for d in table("excavation_designation") if d["id"] == excavation["id"])["completed_cells"] == 0
            call("demolish_building", support_room["id"])
            call("set_time_scale", 600)
            wait_until(lambda: next(d for d in table("excavation_designation")
                                   if d["id"] == excavation["id"])["completed_cells"] == 1,
                       "demolition did not release protected support", 60)
            call("set_time_scale", 0)

            settle_paused()
            durable = snapshot(all_tables)
            stop()
            start()
            restored = snapshot(all_tables)
            assert restored == durable, ("restart lost capabilities or legacy state",
                                         [t for t in all_tables if restored[t] != durable[t]])
            cli("publish", "--yes", "--delete-data=never", "-s", host, "-b", WASM, DB)
            assert snapshot(all_tables) == durable, "republish rewrote state"
            if args.generate_bindings:
                godot = os.environ.get("GODOT", "godot")
                for command in (
                    [godot, "--headless", "--path", "client/godot", "--import"],
                    [godot, "--headless", "--path", "client/godot", "--script",
                     "res://tools/generate_bindings.gd", "--", "--stdb-host=" + host, "--stdb-db=" + DB],
                    [godot, "--headless", "--path", "client/godot", "--import"],
                    [godot, "--headless", "--path", "client/godot", "--script",
                     "res://tools/building_properties_bindings_test.gd"],
                ):
                    subprocess.run(command, cwd=ROOT, check=True, timeout=180)
            evidence = {"baseline_upgrade": bool(baseline), "legacy_tables_preserved": len(TABLES),
                        "rejected_intents": len(rejected) + 4, "restart_and_republish": True,
                        "cost_per_cell": 5, "room_resistance": 2, "bindings_generated": args.generate_bindings}
            (TARGET / "building-properties-evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
            print("BUILDING_PROPERTIES_PASS:", json.dumps(evidence, sort_keys=True))
        except Exception:
            logfile.flush()
            print((tmp / "server.log").read_text()[-12000:])
            raise
        finally:
            stop()
            logfile.close()


if __name__ == "__main__":
    main()
