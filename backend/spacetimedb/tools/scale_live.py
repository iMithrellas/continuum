"""Scale/upgrade API assertions; invoked only inside profile_live's owned server."""
import io
import json
import subprocess
import tarfile
import urllib.request

BASELINE = "367c1343db5a71248c1906f95f2998907c847322"


def check_scale(cli, host, wasm, root, repo, wait):
    # Read an immutable fixture without checking out or editing another worktree.
    archive = subprocess.run(
        ["git", "archive", BASELINE, "backend/spacetimedb"], cwd=repo,
        capture_output=True, check=True,
    ).stdout
    with tarfile.open(fileobj=io.BytesIO(archive)) as source:
        source.extractall(root / "map-baseline", filter="data")
    old = root / "map-baseline/backend/spacetimedb"
    subprocess.run(["cargo", "build", "--manifest-path", str(old / "Cargo.toml"),
                    "--release", "--target", "wasm32-unknown-unknown"], check=True)
    db = "backend-scale-existing"

    def call(name, *args):
        return cli("call", "-s", host, "--", db, name,
                   *(json.dumps(x) if isinstance(x, bool) else str(x) for x in args))

    def rows(table):
        result = json.loads(cli("sql", "--format", "json", "-s", host, db,
                                "SELECT * FROM " + table))[0]
        names = [e["name"]["some"] for e in result["schema"]["elements"]]
        return sorted((dict(zip(names, row)) for row in result["rows"]),
                      key=lambda row: json.dumps(row, sort_keys=True))

    tables = ("config", "colony", "colonist", "tile", "terrain", "world_seed",
              "speed_control", "work_order", "item_stack", "excavation_designation",
              "excavation_jobs", "terrain_material", "event_log", "alert")

    def state():
        # Scheduled paused ticks still trim the bounded audit log. Let legitimate
        # preceding operator/speed audit entries settle before atomic snapshots;
        # do not misattribute that existing retention policy to a failed reducer.
        wait(lambda: len(rows("event_log")) <= 200)
        return {table: rows(table) for table in (*tables, "world_geometry", "terrain_chunk")}

    def unchanged(saved, label):
        current = state()
        changed = {table: {"old_count": len(saved[table]), "new_count": len(current[table]),
                           "differences": [(a, b) for a, b in zip(saved[table], current[table]) if a != b][:3]}
                   for table in saved if saved[table] != current[table]}
        assert not changed, (label, changed)

    def failed(name, *args, cli_root="cli", authorization=False):
        result = subprocess.run(
            [str(cli_path), "--root-dir", str(root / cli_root), "call", "-s", host,
             "--", db, name, *(json.dumps(x) if isinstance(x, bool) else str(x) for x in args)],
            capture_output=True, text=True, timeout=60,
        )
        assert result.returncode != 0, (name, args, "unexpected success")
        if authorization:
            error = (result.stdout + result.stderr).lower()
            assert any(word in error for word in ("admin", "not an authorized", "unauthorized", "permission")), result

    # The owner CLI is the one selected by the outer harness (not a shared token).
    from profile_live import CLI as cli_path
    cli("publish", "--yes", "-s", host, "-b",
        old / "target/wasm32-unknown-unknown/release/continuum_module.wasm", db)
    call("set_time_scale", 100000)
    wait(lambda: rows("colony")[0]["wood"] >= 160)
    call("set_time_scale", 0)
    call("place_facility", 0, 0, 0, '{"storage":{}}', 2, 2, 7)
    call("designate_excavation", 6, 6, 6, 6, -2, 2, 3)
    call("set_time_scale", 600)
    clock = rows("config")[0]["game_seconds"]
    wait(lambda: rows("config")[0]["game_seconds"] >= clock + 600)
    call("set_time_scale", 0)
    before = state()
    assert before["world_geometry"][0]["width"] == 24
    assert any(d["completed_cells"] for d in before["excavation_designation"])
    assert any(c["revision"] > 1 for c in before["terrain_chunk"])
    cli("publish", "--yes", "--delete-data=never", "-s", host, "-b", wasm, db)
    assert state() == before, "additive upgrade changed an existing 24 world"
    print("WASM_MAP_UPGRADE_PASS old_geometry_cells_jobs_ids_revisions_actors_goods_orders_clock_unchanged", flush=True)

    request = urllib.request.Request(host + "/v1/identity", method="POST")
    with urllib.request.urlopen(request, timeout=5) as response:
        viewer = json.load(response)
    subprocess.run([str(cli_path), "--root-dir", str(root / "scale-viewer"), "login",
                    "--token", viewer["token"]], capture_output=True, text=True, check=True)
    for operator in (False, True):
        if operator:
            call("set_operator", json.dumps(viewer["identity"]), True)
        saved = state()
        failed("expand_world", 128, 128, cli_root="scale-viewer", authorization=True)
        unchanged(saved, "authorization rejection changed state")
    for width, height in ((0, 128), (-1, 128), (128, 0), (257, 128),
                          (128, 257), (23, 128), (128, 23), (2147483647, 128)):
        saved = state()
        failed("expand_world", width, height)
        assert state() == saved, ("invalid expansion wrote state", width, height)

    def at(source, x, y, z):
        chunk = next(c for c in source if (c["chunk_x"], c["chunk_y"], c["chunk_z"]) == (x // 16, y // 16, z // 16))
        return chunk["materials"][x % 16 + 16 * (y % 16 + 16 * (z % 16))]

    # Exercise two growths: non-chunk-aligned former padding, then the default.
    for width, height in ((25, 31), (128, 128)):
        saved = state()
        old_width, old_height = saved["world_geometry"][0]["width"], saved["world_geometry"][0]["height"]
        call("expand_world", width, height)
        grown = state()
        assert all(grown[table] == saved[table] for table in tables)
        assert grown["world_geometry"][0] == dict(saved["world_geometry"][0], width=width, height=height)
        assert len(grown["terrain_chunk"]) == ((width + 15) // 16) * ((height + 15) // 16) * 2
        by_key = {(c["chunk_x"], c["chunk_y"], c["chunk_z"]): c for c in grown["terrain_chunk"]}
        for chunk in saved["terrain_chunk"]:
            new = by_key[(chunk["chunk_x"], chunk["chunk_y"], chunk["chunk_z"])]
            assert new["id"] == chunk["id"]
            assert new["revision"] == chunk["revision"] + (new["materials"] != chunk["materials"])
            for z in range(16):
                for y in range(16):
                    for x in range(16):
                        wx, wy = chunk["chunk_x"] * 16 + x, chunk["chunk_y"] * 16 + y
                        if wx < old_width and wy < old_height:
                            index = x + 16 * (y + 16 * z)
                            assert new["materials"][index] == chunk["materials"][index]
        # Sample both old/new chunk seams at every elevation, not only z=0.
        for x, y in ((old_width, 0), (0, old_height), (width - 1, height - 1), (24, 24)):
            if x >= width or y >= height:
                continue
            for z in range(-16, 16):
                expected = 1 if z == -1 else (2 if z < 0 else 0)
                assert at(grown["terrain_chunk"], x, y, z) == expected
        saved = state()
        call("expand_world", width, height)
        assert state() == saved, "equal-dimension retry was not idempotent"
    print("WASM_EXPANSION_PASS admin_only_invalid_requests_atomic_old_rows_and_cells_retained_padding_seeded_sparse", flush=True)

    # All rectangle reducers must use current authoritative bounds, including
    # legacy z=0 APIs. New operational IDs are allocated only for actual builds.
    original = rows("tile")
    old_max = max(t["id"] for t in original)
    call("build_tile_block", 126, 127, 127, 127, '{"farm":{}}')
    call("set_tile_block_enabled", 126, 127, 127, 127, False)
    call("set_block_work_order", 126, 127, 127, 127, '{"farming":{}}', 2, True)
    call("build_tile_block_at", 125, 126, 125, 126, 0, '{"dining":{}}')
    call("set_tile_block_enabled_at", 125, 126, 125, 126, 0, False)
    call("set_block_work_order_at", 126, 127, 127, 127, 0, '{"farming":{}}', 1, False)
    call("designate_excavation", 127, 126, 127, 126, -2, 2, 1)
    built = rows("tile")
    assert len(built) == len(original) + 3
    assert all(t in built for t in original)
    assert all(t["id"] > old_max for t in built if t not in original)
    for name, args in (
        ("build_tile_block", (128, 0, 128, 0, '{"farm":{}}')),
        ("build_tile_block_at", (0, 128, 0, 128, 0, '{"farm":{}}')),
        ("set_tile_block_enabled", (128, 0, 128, 0, False)),
        ("set_tile_block_enabled_at", (0, 128, 0, 128, 0, False)),
        ("set_block_work_order", (128, 0, 128, 0, '{"farming":{}}', 1, True)),
        ("set_block_work_order_at", (0, 128, 0, 128, 0, '{"farming":{}}', 1, True)),
        ("set_tile_block_enabled_at", (126, 127, 127, 127, 16, False)),
        ("set_block_work_order_at", (126, 127, 127, 127, -17, '{"farming":{}}', 1, True)),
        ("designate_excavation", (128, 0, 128, 0, -1, 1, 1)),
    ):
        saved = state()
        failed(name, *args)
        assert state() == saved, ("invalid rectangle wrote state", name)
    print("WASM_SCALE_RECTANGLES_PASS sparse_legacy_and_elevated_operations_ids_and_atomic_bounds", flush=True)
    # Previously the second disjoint rectangle rescanned every first-rectangle
    # cell for each new solid, a quadratic fuel risk now that bounds are larger.
    for x0, x1 in ((0, 63), (64, 127)):
        call("designate_excavation", x0, 0, x1, 127, -3, 1, 3)
        designation = max(rows("excavation_designation"), key=lambda d: d["id"])
        assert designation["total_cells"] == 8192
        call("set_excavation_enabled", designation["id"], False)
    saved = state()
    failed("designate_excavation", 63, 0, 64, 127, -3, 1, 3)
    unchanged(saved, "paused large-designation overlap changed state")
    print("WASM_LARGE_ADJACENT_DESIGNATIONS_PASS two_8192_cell_vectors_and_paused_overlap", flush=True)
    generation = rows("config")[0]["generation"]
    call("reset_colony")
    assert rows("world_geometry")[0]["width"] == rows("world_geometry")[0]["height"] == 128
    assert rows("config")[0]["generation"] == generation + 1
    assert len(rows("tile")) == len(rows("terrain")) == 576
    assert rows("excavation_designation")[0]["total_cells"] == 48
    print("WASM_EXPLICIT_RESET_PASS new_default_starter_and_finite_hillside", flush=True)
