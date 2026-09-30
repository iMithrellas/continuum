"""API assertions for test-vertical-terrain's exclusively owned database."""

import collections
import json
import os
import math
import subprocess
import time
import urllib.request

HOST = "http://127.0.0.1:" + os.environ["TERRAIN_TEST_PORT"]
DB = "continuum-terrain-test"
CLI = os.environ["TERRAIN_TEST_CLI"]
TMP = os.environ["TERRAIN_TEST_TMP"]
WASM = os.environ["TERRAIN_TEST_WASM"]


def cli(*args, viewer=False, fail=False):
    root = TMP + ("/viewer" if viewer else "/cli")
    result = subprocess.run(
        [CLI, "--root-dir", root, *(json.dumps(arg) if isinstance(arg, bool) else str(arg)
                                  for arg in args)],
        capture_output=True,
        text=True,
        timeout=60,
    )
    if fail:
        assert result.returncode != 0, (args, "unexpected success")
        if viewer:
            error = (result.stderr + result.stdout).lower()
            assert any(word in error for word in ("operator", "admin", "permission", "unauthorized",
                                                  "not an authorized", "not authorized")), (
                "viewer rejection was not an authorization check", args, error
            )
    else:
        assert result.returncode == 0, (args, result.stderr, result.stdout)
    return result.stdout


def call(name, *args, viewer=False, fail=False):
    # A negative elevation is a positional reducer argument, not a CLI option.
    return cli("call", "-s", HOST, "--", DB, name, *args, viewer=viewer, fail=fail)


def rows(query):
    result = json.loads(cli("sql", "--format", "json", "-s", HOST, DB, query))[0]
    names = [element["name"]["some"] for element in result["schema"]["elements"]]
    return sorted((dict(zip(names, row)) for row in result["rows"]),
                  key=lambda row: json.dumps(row, sort_keys=True))


def wait_until(test, message, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if test():
            return
        time.sleep(0.2)
    raise AssertionError(message)


def healthy():
    try:
        with urllib.request.urlopen(HOST + "/v1/ping", timeout=1) as response:
            return response.status == 200
    except OSError:
        return False


wait_until(healthy, "private server did not start")
baseline = os.environ.get("CONTINUUM_BASELINE_WASM")
cli("publish", "--yes", "-s", HOST, "-b", baseline or WASM, DB)
call("set_time_scale", 0)
if baseline:
    snapshots = {
        query: rows(query)
        for query in (
            "SELECT id, x, y, kind, enabled FROM tile",
            "SELECT food, wood, stone, meat FROM colony",
            "SELECT * FROM work_order",
            "SELECT * FROM world_seed",
        )
    }
    cli("publish", "--yes", "--delete-data=never", "-s", HOST, "-b", WASM, DB)


def initialized():
    geometry_rows = rows("SELECT * FROM world_geometry")
    if not geometry_rows:
        return False
    bounds = geometry_rows[0]
    expected = math.ceil(bounds["width"] / 16) * math.ceil(bounds["height"] / 16) * (
        bounds["max_z"] // 16 - bounds["min_z"] // 16 + 1
    )
    chunk_rows = rows("SELECT * FROM terrain_chunk")
    bodies = rows("SELECT * FROM colonist")
    return (len(chunk_rows) == expected
            and all(len(chunk["materials"]) == 4096 for chunk in chunk_rows)
            and {0, 1, 2} <= {material["id"] for material in rows("SELECT * FROM terrain_material")}
            and len(bodies) == 8
            and all(body["clearance_height"] == 4 and "next_z" in body for body in bodies))


wait_until(initialized, "complete physical world not initialized")
if baseline:
    for query, previous in snapshots.items():
        assert rows(query) == previous, ("migration changed legacy state", query)
    print("TERRAIN_MIGRATION_PASS")

geometry = rows("SELECT * FROM world_geometry")[0]
assert geometry["width"] == geometry["height"] == (24 if baseline else 128)
assert geometry["min_z"] == -16 and geometry["max_z"] >= 15
materials = {row["id"]: row for row in rows("SELECT * FROM terrain_material")}
assert {0, 1, 2} <= materials.keys()
assert not materials[0]["opaque"]
for material in materials.values():
    if material["id"]:
        for property_name in ("density", "strength", "thermal_conductivity", "specific_heat_capacity"):
            assert material[property_name] > 0, (material["name"], property_name)


def chunks():
    result = {}
    for row in rows("SELECT * FROM terrain_chunk"):
        assert len(row["materials"]) == 4096
        assert set(row["materials"]) <= materials.keys()
        result[(row["chunk_x"], row["chunk_y"], row["chunk_z"])] = row
    return result


terrain = chunks()
assert any(key[2] < 0 for key in terrain)


def material_at(position, source=None):
    x, y, z = position
    if not (0 <= x < geometry["width"] and 0 <= y < geometry["height"]
            and geometry["min_z"] <= z <= geometry["max_z"]):
        return None
    chunk = (terrain if source is None else source).get((x // 16, y // 16, z // 16))
    if chunk is None:
        return None
    return chunk["materials"][(x % 16) + 16 * ((y % 16) + 16 * (z % 16))]


def can_stand(position):
    x, y, z = position
    return material_at((x, y, z - 1)) not in (None, 0) and all(
        material_at((x, y, z + dz)) == 0 for dz in range(4)
    )


colonists = rows("SELECT * FROM colonist")
assert len(colonists) == 8
for colonist in colonists:
    assert colonist["body_width"] == colonist["body_depth"] == 1
    assert colonist["clearance_height"] == 4
    assert can_stand((colonist["x"], colonist["y"], colonist["z"]))


def total_stone():
    return (rows("SELECT stone FROM colony")[0]["stone"]
            + sum(stack["amount"] for stack in rows("SELECT * FROM item_stack")
                  if stack["kind"][0] == 2)
            + sum(body["carried_amount"] for body in rows("SELECT * FROM colonist")
                  if body["carried_kind"][0] == 2))

# A new token is a genuine viewer, rather than an accidentally misnamed reducer.
request = urllib.request.Request(HOST + "/v1/identity", method="POST")
with urllib.request.urlopen(request, timeout=5) as response:
    viewer = json.load(response)
cli("login", "--token", viewer["token"], viewer=True)
for name, args in (
    ("designate_excavation", (0, 0, 0, 0, -1, 1, 1)),
    ("set_excavation_enabled", (1, False)),
    ("cancel_excavation", (1,)),
    ("build_tile_block_at", (0, 0, 0, 0, 0, '{"farm":{}}')),
    ("place_facility", (0, 0, 0, '{"storage":{}}', 2, 2, 7)),
    ("set_tile_block_enabled_at", (0, 0, 0, 0, 0, False)),
    ("set_block_work_order_at", (0, 0, 0, 0, 0, '{"mining":{}}', 1, True)),
    ("configure_colonist_body", (colonists[0]["id"], 1, 1, 4, 1)),
):
    call(name, *args, viewer=True, fail=True)

# The same genuine identity can operate after an explicit administrator grant,
# but still cannot change administrator-only simulation speed.
call("set_operator", json.dumps(viewer["identity"]), True)
call("set_time_scale", 0, viewer=True, fail=True)
body_id = colonists[0]["id"]
call("configure_colonist_body", body_id, 2, 1, 6, 1, viewer=True)
configured = next(body for body in rows("SELECT * FROM colonist") if body["id"] == body_id)
assert configured["body_width"] == 2 and configured["clearance_height"] == 6
call("configure_colonist_body", body_id, 1, 1, 4, 1, viewer=True)
call("designate_excavation", 0, 0, 0, 0, -1, 1, 1, viewer=True)
operator_job = max(rows("SELECT * FROM excavation_designation"), key=lambda row: row["id"])
call("set_excavation_enabled", operator_job["id"], False, viewer=True)
call("set_excavation_enabled", operator_job["id"], True, viewer=True)
call("cancel_excavation", operator_job["id"], viewer=True)
assert not any(row["id"] == operator_job["id"] for row in rows("SELECT * FROM excavation_designation"))

# Freeze seeded excavation, then isolate one reachable solid block. An additive
# upgrade is flat; its exposed soil floor is a valid finite mining target too.
for designation in rows("SELECT * FROM excavation_designation"):
    call("set_excavation_enabled", designation["id"], False)
reachable = set()
queue = collections.deque()
miners = [body for body in colonists if body["work"][0] == 2]
assert miners, "no seeded mining workers"
max_step = min(body["max_step_height"] for body in miners)
for colonist in miners:
    position = (colonist["x"], colonist["y"], colonist["z"])
    if can_stand(position):
        reachable.add(position)
        queue.append(position)
while queue:
    x, y, z = queue.popleft()
    for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1)):
        for dz in range(-max_step, max_step + 1):
            neighbour = (x + dx, y + dy, z + dz)
            # Lift before moving up, or move across before lowering down.
            swept = can_stand(neighbour)
            if dz > 0:
                swept = swept and all(material_at((x, y, z + layer)) == 0
                                      for layer in range(4, 4 + dz))
            elif dz < 0:
                swept = swept and all(material_at((x + dx, y + dy, z + layer)) == 0
                                      for layer in range(4))
            if neighbour not in reachable and swept:
                reachable.add(neighbour)
                queue.append(neighbour)

occupied = set()
for tile in rows("SELECT * FROM tile"):
    if tile["kind"][0] == 0:  # TileKind::Empty
        continue
    for dx in range(tile["width"]):
        for dy in range(tile["depth"]):
            for dz in range(tile["clearance_height"]):
                occupied.add((tile["x"] + dx, tile["y"] + dy, tile["z"] + dz))
            occupied.add((tile["x"] + dx, tile["y"] + dy, tile["z"] - 1))
for stack in rows("SELECT * FROM item_stack"):
    occupied.add((stack["x"], stack["y"], stack["z"] - 1))
for body in colonists:
    occupied.add((body["x"], body["y"], body["z"] - 1))
target = None
for x, y, z in sorted(reachable):
    for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1)):
        for layer in (z, z - 1):
            candidate = (x + dx, y + dy, layer)
            if material_at(candidate) in (1, 2) and candidate not in occupied:
                target = candidate
                break
        if target:
            break
    if target:
        break
assert target is not None, "seed contains no reachable material excavation face"
x, y, z = target
stone_before = total_stone()
call("designate_excavation", x, y, x, y, z, 1, 1)
designation = max(rows("SELECT * FROM excavation_designation"), key=lambda row: row["id"])
assert designation["height"] == designation["total_cells"] == 1
call("set_time_scale", 600)
wait_until(lambda: material_at(target, chunks()) == 0, "miners did not excavate reachable block", 45)
call("set_time_scale", 0)
completed = next(row for row in rows("SELECT * FROM excavation_designation")
                 if row["id"] == designation["id"])
assert completed["completed_cells"] == 1
assert abs(total_stone() - stone_before - 1.0) < 0.002, "mining yield is not one material block"
assert sum(row["revision"] for row in chunks().values()) > sum(
    row["revision"] for row in terrain.values()
)

# An exhausted mine marker cannot continue generating stone while haulers move it.
stone_after = total_stone()
time_before = rows("SELECT game_seconds FROM config")[0]["game_seconds"]
call("set_time_scale", 600)
wait_until(lambda: rows("SELECT game_seconds FROM config")[0]["game_seconds"]
           >= time_before + 1800, "simulation did not advance after excavation")
call("set_time_scale", 0)
assert abs(total_stone() - stone_after) < 0.002, "exhausted mine produced more stone"

# Build one multi-cell, tall facility, testing positive permission, full-volume
# placement and a single atomic footprint-sized charge in the real module.
if rows("SELECT wood FROM colony")[0]["wood"] < 80:
    # Wood grows at six units per worker-hour and must be hauled; do not assume
    # a few simulated hours provide the four-cell footprint's entire build cost.
    call("set_time_scale", 3600)
    wait_until(lambda: rows("SELECT wood FROM colony")[0]["wood"] >= 80,
               "loggers did not supply the facility build", 120)
    call("set_time_scale", 0)
current = chunks()
facilities = [tile for tile in rows("SELECT * FROM tile") if tile["kind"][0] != 0]
placement_bodies = rows("SELECT * FROM colonist")


def facility_site(px, py):
    if not all(material_at((px + dx, py + dy, -1), current) in (1, 2)
               and all(material_at((px + dx, py + dy, dz), current) == 0 for dz in range(7))
               for dx in range(2) for dy in range(2)):
        return False
    for tile in facilities:
        if (px < tile["x"] + tile["width"] and px + 2 > tile["x"]
                and py < tile["y"] + tile["depth"] and py + 2 > tile["y"]
                and 0 < tile["z"] + tile["clearance_height"] and 7 > tile["z"]):
            return False
    return not any(px <= body["x"] < px + 2 and py <= body["y"] < py + 2
                   and body["z"] < 7 for body in placement_bodies)


site = next((px, py) for px in range(geometry["width"] - 1)
            for py in range(geometry["height"] - 1) if facility_site(px, py))
wood_before = rows("SELECT wood FROM colony")[0]["wood"]
call("place_facility", *site, 0, '{"storage":{}}', 2, 2, 7, viewer=True)
built = next(tile for tile in rows("SELECT * FROM tile")
             if tile["kind"][0] != 0 and (tile["x"], tile["y"], tile["z"]) == (*site, 0))
assert (built["width"], built["depth"], built["clearance_height"]) == (2, 2, 7)
assert abs(wood_before - rows("SELECT wood FROM colony")[0]["wood"] - 80) < 0.002

# Invalid intent must be rejected without changing geometry, resources or intent.
before = {name: rows("SELECT * FROM " + name) for name in
          ("terrain_chunk", "excavation_designation", "colony", "tile",
           "work_order", "item_stack", "event_log")}
call("designate_excavation", x, y, x, y, z, 1, 1, fail=True)
for args in ((0, 0, 0, 0, 0, 0, 1), (0, 0, 0, 0, 0, 65535, 1),
             (2147483647, 0, 2147483647, 0, 0, 6, 1)):
    call("designate_excavation", *args, fail=True)
current = chunks()
unsupported = next((px, py, pz) for px in range(geometry["width"])
                   for py in range(geometry["height"])
                   for pz in range(geometry["min_z"] + 1, geometry["max_z"] - 3)
                   if material_at((px, py, pz - 1), current) == 0)
call("place_facility", *unsupported, '{"storage":{}}', 1, 1, 4, fail=True)
call("place_facility", 0, 0, 0, '{"storage":{}}', 0, 1, 4, fail=True)
call("place_facility", site[0] + 1, site[1], 0, '{"storage":{}}', 1, 1, 4, fail=True)
for name, previous in before.items():
    assert rows("SELECT * FROM " + name) == previous, ("failed intent mutated state", name)
call("set_operator", json.dumps(viewer["identity"]), False)
print("VERTICAL_TERRAIN_API_PASS")
