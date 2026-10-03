"""Actual-WASM bulk intent gate; runs only in profile_live's owned private server.

The affordable fixture changes ONLY an immutable baseline's founding wood in an
ignored temporary directory inside this worktree. Publish that private fixture,
then upgrade without deleting data to the unmodified production artifact. No
cheat reducer, production seed change, shared database or other worktree edit.
"""
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import time
import urllib.request

BASELINE = "e4eb1202b6ab7353f43d7c25cd1e0f8c10c8dbf8"


def check_construction(cli, host, wasm, root, module, wait, cpu_seconds):
    from profile_live import CLI

    def call(db, name, *args, expected=None, viewer=False):
        argv = [CLI, "--root-dir", str(root / ("construction-viewer" if viewer else "cli")),
                "call", "-s", host, "--", db, name,
                *(json.dumps(x) if isinstance(x, bool) else str(x) for x in args)]
        cpu_before = cpu_seconds()
        started = time.monotonic()
        result = subprocess.run(argv, capture_output=True, text=True, timeout=10)
        elapsed = time.monotonic() - started
        cpu = cpu_seconds() - cpu_before
        error = result.stdout + result.stderr
        if expected is None:
            assert result.returncode == 0, (argv, error)
        else:
            assert result.returncode != 0 and expected in error, (argv, expected, error)
            assert elapsed < 1.0, ("negative bulk intent exceeded 1s including CLI startup", argv, elapsed)
        return elapsed, cpu

    def rows(db, table):
        result = json.loads(cli("sql", "--format", "json", "-s", host, db,
                                "SELECT * FROM " + table))[0]
        names = [e["name"]["some"] for e in result["schema"]["elements"]]
        return [dict(zip(names, row)) for row in result["rows"]]

    def settle(db):
        # Paused scheduled ticks retain their existing terrain backfill/repair and
        # audit retention policy; finish that before immutable intent snapshots.
        wait(lambda: len(rows(db, "terrain")) == len(rows(db, "tile"))
             and all(c["next_x"] != 0 or c["next_y"] != 0 for c in rows(db, "colonist"))
             and len(rows(db, "event_log")) <= 200)

    tables = ("config", "colony", "colonist", "tile", "terrain", "world_seed",
              "speed_control", "work_order", "item_stack", "excavation_designation",
              "excavation_jobs", "terrain_material", "world_geometry", "terrain_chunk",
              "event_log", "alert", "membership")

    def snapshot(db):
        settle(db)
        return {table: hashlib.sha256(json.dumps(sorted(rows(db, table),
                    key=lambda row: json.dumps(row, sort_keys=True)), sort_keys=True).encode()).hexdigest()
                for table in tables}

    def negative(db, name, last, expected):
        saved = snapshot(db)
        args = (24, 24, last, last)
        if name.endswith("_at"):
            args += (0,)
        elapsed, cpu = call(db, name, *args, '{"farm":{}}', expected=expected)
        assert snapshot(db) == saved, ("failed intent changed colony state", db, name, last)
        cells = (last - 23) ** 2
        print(f"WASM_CONSTRUCTION_NEGATIVE_PASS db={db} reducer={name} cells={cells} wall={elapsed*1000:.3f}ms server_cpu={cpu*1000:.3f}ms error={expected!r}", flush=True)

    db = "construction-zero"
    cli("publish", "--yes", "-s", host, "-b", wasm, db)
    call(db, "set_time_scale", 0)
    settle(db)
    assert rows(db, "colony")[0]["wood"] == 0
    for name in ("build_tile_block", "build_tile_block_at"):
        negative(db, name, 87, "building requires 81920 stored wood")
        negative(db, name, 127, "building requires 216320 stored wood")
    call(db, "expand_world", 256, 256)
    for name in ("build_tile_block", "build_tile_block_at"):
        negative(db, name, 255, "building requires 1076480 stored wood")

    with tempfile.TemporaryDirectory(prefix="construction-fixture-", dir=module / "target") as fixture:
        fixture = Path(fixture)
        archive = subprocess.run(["git", "archive", BASELINE, "backend/spacetimedb"],
                                 cwd=module.parents[1], capture_output=True, check=True).stdout
        with tarfile.open(fileobj=io.BytesIO(archive)) as source:
            source.extractall(fixture, filter="data")
        baseline = fixture / "backend/spacetimedb"
        seed = baseline / "src/sim/seed.rs"
        text = seed.read_text()
        assert text.count("wood: 0.0,") == 1
        seed.write_text(text.replace("wood: 0.0,", "wood: 1_500_000.0,"))
        subprocess.run(["cargo", "build", "--manifest-path", str(baseline / "Cargo.toml"),
                        "--release", "--target", "wasm32-unknown-unknown"], check=True)
        db = "construction-funded"
        cli("publish", "--yes", "-s", host, "-b",
            baseline / "target/wasm32-unknown-unknown/release/continuum_module.wasm", db)
        call(db, "set_time_scale", 0)
        saved = snapshot(db)
        assert rows(db, "colony")[0]["wood"] == 1_500_000.0
        cli("publish", "--yes", "--delete-data=never", "-s", host, "-b", wasm, db)
        assert snapshot(db) == saved, "funded upgrade changed persistent state"
    print("WASM_CONSTRUCTION_FUNDED_UPGRADE_PASS baseline=ccc4666 founding_wood=1500000 production_artifact_unchanged", flush=True)

    for name in ("build_tile_block", "build_tile_block_at"):
        negative(db, name, 127, "at most 4096 cells (requested 10816)")
    call(db, "expand_world", 256, 256)
    for name in ("build_tile_block", "build_tile_block_at"):
        negative(db, name, 255, "at most 4096 cells (requested 53824)")
    for name in ("build_tile_block", "build_tile_block_at"):
        saved = snapshot(db)
        args = (22, 0, 22, 8) + ((0,) if name.endswith("_at") else ())
        call(db, name, *args, '{"farm":{}}',
             expected="full clearance and solid support")
        assert snapshot(db) == saved, ("late geometry failure wrote a prefix", name)
    print("WASM_CONSTRUCTION_LATE_GEOMETRY_ROLLBACK_PASS both_block_reducers_last_cell_obstructed", flush=True)
    saved = snapshot(db)
    call(db, "build_tile_block_at", 24, 0, 40, 240, 0, '{"farm":{}}',
         expected="at most 4096 cells (requested 4097)")
    assert snapshot(db) == saved

    request = urllib.request.Request(host + "/v1/identity", method="POST")
    with urllib.request.urlopen(request, timeout=5) as response:
        viewer = json.load(response)
    subprocess.run([CLI, "--root-dir", str(root / "construction-viewer"), "login",
                    "--token", viewer["token"]], capture_output=True, text=True, check=True)
    call(db, "set_operator", json.dumps(viewer["identity"]), False)
    saved = snapshot(db)
    for name in ("build_tile_block", "build_tile_block_at"):
        args = (24, 24, 87, 87) + ((0,) if name.endswith("_at") else ())
        call(db, name, *args, '{"farm":{}}', expected="caller lacks the required colony role", viewer=True)
        assert snapshot(db) == saved
    call(db, "set_operator", json.dumps(viewer["identity"]), True)
    before = rows(db, "tile")
    saved = snapshot(db)
    wood = rows(db, "colony")[0]["wood"]
    elapsed, cpu = call(db, "build_tile_block_at", 24, 24, 87, 87, 0, '{"farm":{}}', viewer=True)
    assert elapsed < 2.0, ("maximum valid construction exceeded 2s including CLI startup", elapsed)
    after = rows(db, "tile")
    old = {t["id"]: t for t in before}
    assert all(t == old[t["id"]] for t in after if t["id"] in old)
    added = sorted((t for t in after if t["id"] not in old), key=lambda t: t["id"])
    assert len(added) == 4096 and [t["id"] for t in added] == list(range(577, 4673))
    assert rows(db, "colony")[0]["wood"] == wood - 81920
    current = snapshot(db)
    for table in ("config", "colonist", "work_order", "item_stack", "excavation_designation",
                  "excavation_jobs", "world_geometry", "terrain_chunk", "world_seed"):
        assert current[table] == saved[table], ("build changed unrelated state", table)
    print(f"WASM_CONSTRUCTION_MAXIMUM_PASS cells=4096 ids=577..4672 exact_cost=81920 wall={elapsed*1000:.3f}ms server_cpu={cpu*1000:.3f}ms", flush=True)
    for name in ("build_tile_block", "build_tile_block_at"):
        negative(db, name, 255, "at most 4096 cells (requested 53824)")
    before = {t["id"]: t for t in rows(db, "tile")}
    wood = rows(db, "colony")[0]["wood"]
    elapsed, cpu = call(db, "build_tile_block", 88, 88, 111, 111, '{"farm":{}}', viewer=True)
    after = rows(db, "tile")
    assert all(t == before[t["id"]] for t in after if t["id"] in before)
    added = sorted((t for t in after if t["id"] not in before), key=lambda t: t["id"])
    assert len(added) == 576 and [t["id"] for t in added] == list(range(4673, 5249))
    assert rows(db, "colony")[0]["wood"] == wood - 11520
    print(f"WASM_CONSTRUCTION_LEGACY_576_PASS ids=4673..5248 exact_cost=11520 wall={elapsed*1000:.3f}ms server_cpu={cpu*1000:.3f}ms", flush=True)

    call(db, "place_facility", 150, 86, 0, '{"dining":{}}', 2, 2, 7)
    for name in ("build_tile_block", "build_tile_block_at"):
        saved = snapshot(db)
        args = (151, 87, 152, 88) + ((0,) if name.endswith("_at") else ())
        call(db, name, *args, '{"farm":{}}', expected="facility volumes overlap")
        assert snapshot(db) == saved, ("footprint conflict changed colony", name)
    print("WASM_CONSTRUCTION_FOOTPRINT_ROLLBACK_PASS outside_anchor_interior_overlap_both_block_reducers", flush=True)
    print("WASM_CONSTRUCTION_GATE_PASS atomic_cap_fast_cost_checks_permissions_bounded_maximum_and_placement_rollback", flush=True)
