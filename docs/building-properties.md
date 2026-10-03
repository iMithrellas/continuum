# Construction and usage designation

`building` is authoritative construction. `tile` is authoritative operational
usage, retained as the compatibility adapter for needs, logistics and work
orders. A storage designation and a room can cover the same position in either
creation order. Neither authority owns or rewrites the other.

## Honest vertical slice

An **Insulated room envelope** is a constructed, traversable rectangular volume
with an authored thermal-resistance capability. It is not a placement of voxel
walls, an enclosure detector, a temperature or heat-transfer simulation, a
door/collider system, structural physics, or food spoilage. Existing terrain
remains material authority. This abstraction does not claim that insulation
changes any current colonist need or resource consumption.

The volume reserves supported, clear space when constructed. Its floor support
is protected from simulation excavation until demolition, even when no zone is
inside it. It does not introduce blocking cells or change navigation routes.

The pure `World::room_thermal_resistance_at(Cell)` query returns the property's
value inside the half-open XYZ envelope, or `None` outside it or when the property
is absent. Future food half-life may combine this construction capability with
independent storage usage; that feature is not implemented here. Only one
operational usage may occupy a volume in this slice; **building/zone overlap is
supported, simultaneous multiple zone usages are not**.

## Public interface

```text
BuildingKind = InsulatedRoom
building:
  id:u64 [primary key, auto_inc], kind:BuildingKind,
  x:i32, y:i32, z:i32, width:u16, depth:u16,
  clearance_height:u16, wood_cost:f32
building_thermal_property:
  building_id:u64 [primary key, references building.id],
  thermal_resistance_m2_k_per_w:f32
```

SpacetimeDB 2.10 canonicalizes the numeric unit token in SQL/schema output.
The Rust field above becomes **`thermal_resistance_m_2_k_per_w`** in SQL and the
generated `ContinuumBuildingThermalProperty` Godot row. Consume the generated
spelling; do not hand-edit generated code or treat missing properties as zero.

All reducers below require Operator (Admin inherits Operator) and return reducer
success/failure; clients discover allocated IDs through replication:

```text
construct_room(x0:i32, y0:i32, x1:i32, y1:i32, z:i32, clearance_height:u16)
demolish_building(building_id:u64)
designate_zone_at(x0:i32, y0:i32, x1:i32, y1:i32, z:i32, kind:TileKind)
clear_zone(tile_id:u32)
```

Rectangle endpoints are normalized and inclusive in XY, with one explicit feet
elevation. One intent covers at most **4096** footprint cells. Construction costs
**5 stored wood per cell** and writes a fixed **2.0 m²·K/W** resistance. Clients
cannot submit costs or properties. Minimum room height is four cells, recommended
height six. Bounds, full-volume air, full-footprint solid support, room overlap,
finite resources and total affordability are checked before writes. Database
transactions provide rollback on failure. Rooms may overlap zones, goods and
actors, but not another room volume. Demolition removes its capability rows,
without goods loss, zone edits or wood refund.

Designation is free for every non-Empty TileKind. It creates one-cell zones with
four-cell clearance, preserving durable Empty anchors. Existing same-kind
one-cell zones retain ID, clearance and enablement after geometry validation;
repeating an unchanged designation is a no-op. Conflicting kinds, vertically
intersecting reservations, and any intersecting legacy multi-cell reservation
are rejected atomically, including partial same-kind edits. Clear the conflicting
zone explicitly first. A legacy reservation with less than four clear cells
cannot be accepted as a valid standing designation.

`clear_zone` retains the Empty anchor and its ID, removes orders referencing that
anchor, and preserves ground stacks, cargo, stored resources and buildings.
Repeating clear is a no-op. A new producing designation does **not** create work
orders; use existing order reducers explicitly. Existing enablement reducers
continue to operate on Tile usage. Existing stack/work-order encoding
`tile_id * 4 + resource_ordinal` remains unchanged, and cleared Tile rows are
never deleted or reallocated.

`build_facility`, `place_facility`, `build_tile_block`, and `build_tile_block_at`
are **deprecated charged-usage compatibility APIs**, not physical construction.
They retain their historical behavior for old clients. New UI must use the two
independent construction/designation tools and inspect both layers.

## Explicit additive migration policy

- Only two tables, one new enum and four reducers are added. Existing public
  fields and enum ordinals are not changed.
- An upgraded database starts with no buildings/properties. Existing Sleep,
  Dining, Recreation and Storage rows are not fabricated into physical rooms.
- Publishing an upgrade does not reset or expand the physical world, overwrite
  terrain, repair actors through these new intent reducers, or reseed zoning.
- Use non-destructive publication (`--delete-data=never`), never `publish-fresh`
  for this additive change. No live deployment is performed by the test gate.
- An explicitly requested colony reset clears both new tables. Database-owned
  building IDs remain allocated by `auto_inc`, including after demolition/reset;
  identities are never derived from enum/list lengths.

## Cost and verification

Placement rejects area/cost failures before loading geometry. It reads material
chunks, but not colonists, navigation, ecology or excavation job vectors. Room
planning scans existing envelopes once then checks the bounded volume. Zone
planning is O(E + A log C) for existing Tile rows E, requested area A and material
chunks C; it does not rescan a growing output. Commits write only the requested
Tile delta or the two construction rows plus resource debit. No per-cell
building entities or per-tick property writes are added.

Live world loads add an O(B log B) capability mapping for B buildings/properties.
Point queries and mining support protection scan envelopes linearly; there is
no spatial index or claimed speedup. Large building counts require measurement
before extending the slice. Building placement itself never warms navigation.

```sh
just test
just fmt-check
just wasm
just test-gameplay-core
just test-vertical-terrain
CONTINUUM_BASELINE_WASM=/path/to/705a72c.wasm just test-building-properties
# Generate against the gate's exclusively owned schema server, not a live endpoint:
CONTINUUM_BASELINE_WASM=/path/to/705a72c.wasm just test-building-properties --generate-bindings
godot --headless --path client/godot --script res://tools/building_properties_bindings_test.gd
```

The integration gate owns its runtime, data directory, identity profiles and
database; publishes the baseline; produces real wood and an excavation fixture;
pauses and settles existing scheduler maintenance; snapshots 18 legacy tables;
then upgrades without deleting data. It verifies those snapshots exactly,
membership rejection, free usage, exact construction debit, overlap in both
creation orders, independent clear/demolition, IDs/orders/goods, failed-intent
rollback, actual scheduled excavation protection/release, restart and republish.
Evidence is written to ignored `backend/spacetimedb/target/building-properties-evidence.json`.

For an already owned development schema server, the underlying binding command is:

```sh
godot --headless --path client/godot --import
godot --headless --path client/godot --script res://tools/generate_bindings.gd -- \
  --stdb-host=http://127.0.0.1:PORT --stdb-db=DATABASE
godot --headless --path client/godot --import
```

Map size/generation and expansion are separate work. This change does not add
`expand_world_varied` or alter fresh-world dimensions.
