# Vertical backend contract

## Authority and wire layout

- Coordinates are integer **0.5 m cells** (volume **0.125 m³**); z is the
  feet/base layer and support is z − 1. Default bounds are x/y `0..24`
  (exclusive upper bounds), z **−16..=15** (inclusive).
- `world_geometry` has singleton ID 0. `terrain_chunk` uses edge 16,
  Euclidean negative chunk coordinates, and `x + 16*(y + 16*z)` local ordering.
  Each chunk always contains 4096 material IDs, including air padding outside
  the x/y bounds. Chunk IDs are durable allocated IDs, not coordinate encodings.
- Material registry: **air 0**, **soil 1**, **stone 2**. Density is kg/m³,
  strength Pa, conductivity W/(m·K), specific heat J/(kg·K). These are metadata,
  not a thermal/structural physics solver.
- `excavation_designation` uses the frozen fields with **no extra trailing
  progress field**. Normalized inclusive x/y, `bottom_z..bottom_z+height`,
  total original solid cells and completed cells. Job vectors and per-cell work
  progress live in private `excavation_jobs` rows, one vector per designation.
  Terrain is never represented by per-cell ECS/database entity rows.
- Tile fields append z/default 0, width/depth/default 1, clearance/default 4.
  Colonist fields append z/target_z/default 0, width/depth/default 1,
  clearance/default 4, step/default 1, and actual next-hop xyz/default 0.
  Item stacks append z/default 0. Persistence explicitly maps these to narrow
  internal `Spatial`/`Body` capabilities rather than expanding 2D movement inputs.
- New elevation-specific operational tiles get IDs above the existing maximum.
  Empty operational rows are retained, preventing ID reuse. Legacy stack/order
  keys remain `tile_id * 4 + resource_ordinal`.

## Operations and behavior

All frozen reducers are present and operator-authorized:
`designate_excavation`, `set_excavation_enabled`, `cancel_excavation`,
`build_tile_block_at`, `place_facility`, `set_tile_block_enabled_at`,
`set_block_work_order_at`. An optional `configure_colonist_body(id, width,
depth, clearance_height, max_step_height)` validates current clearance/support.
SpacetimeDB's canonical schema names rectangle arguments/fields **`x_0`, `y_0`,
`x_1`, `y_1`**, even though the Rust source uses `x0`, `y0`, `x1`, `y1`.
Old coordinate rectangles and zone-wide operations select **z=0 only**;
ID-addressed operations still address their explicit durable entity.

- Facilities are accessible **capability/room reservations**, not solid walls
  or blocking furniture. All dimensions must be positive, all footprint cells
  must have support, all volume cells must be air, and facility volumes cannot
  overlap. A block validates in memory before any cost/entity writes; costs are
  20 stored wood per footprint cell. Nothing spends pooled resources on failure.
- Navigation is deterministic cardinal BFS over supported positions, uses each
  actor's full footprint/height/maximum step, and checks the entire vertical
  sweep when stepping up/down. Next-hop fields publish the actual route hop.
  Decisions for needs, production, pickups and delivery reject unreachable or
  wrong-elevation facilities. Rooms remain traversable and actors do not block
  one another's navigation.
- Mining workers use finite solid-cell jobs instead of Mine facility production
  when geometry exists. An exposed cardinal work face is required, at supported
  reachable work positions. Reach is six cells above the feet, or one adjacent
  exposed floor cell below the feet to permit descent. Jobs are top-down and
  deterministic by priority, designation ID, top-down cell ordinal, route distance,
  work position. Work accumulates per cell; one completed solid cell produces
  one prototype stone resource unit on the work position, **not** pooled storage.
  Soil also uses this prototype stone yield; material metadata is retained in
  unfinished jobs, but soil-specific resources are not added to the wire enum.
- Removal revalidates protection of all actors' support/body volumes,
  facilities' support/reservation volumes and ground piles' support. Planning
  may move an acting miner away from its own support first; removal never happens
  while it is still standing on that cell. Completed jobs cannot yield twice;
  overlapping unfinished solid-cell designations are rejected even when paused.
  Exposed ceiling faces above the full body clearance are reachable as well as
  cardinal side faces. Reachable upper jobs outrank nearer lower jobs, preserving
  a base voxel needed as a step for a seven-cell column. Nine-cell excavations
  execute when an existing upper staircase supplies the necessary elevation.
- Ground piles follow existing cargo/hauling conservation, including dedicated
  haulers and partial finite piles. Disabling/canceling an intent stops extraction
  but retains already-produced goods. Cancellation discards unfinished effort.
- Transaction loads read chunk material arrays once into memory; only changed
  chunks are persisted. Revision increments once per changed chunk per loaded
  transaction, not once per individual removed voxel. Navigation/render queries
  derive from these arrays; floor/wall/ceiling labels are adjacency queries.
  Partial effort dirties only the affected private job vector; completion dirties
  that vector and its public count. Unchanged paused/completed intents are not
  rewritten by tick persistence.

## Explicit additive migration

SpacetimeDB 2.10 schema defaults append the fields; all new tables are additive.
When geometry is missing on a live load, install a flat volume: soil at z=−1,
stone at z=−16..−2, air at z=0..15. This preserves every old z=0 operational
tile and actor location, resource quantity, identity, work order and existing
environmental/dirty row. No hillside or work orders are imposed on old colonies.
Old Mine work orders remain as operator intent but **do not grant infinite
production**. Operators must designate actual reachable solid cells.
Saved interpolation is repaired on load (including paused/non-tick loads), and
changed hops are persisted atomically. Genuine `(0,0,0)` neighbours and equally
short saved routes are preserved. Additive default hops recover the valid legacy
x-first step and fractional progress without moving actors or changing goods.

Fresh init/explicit reset adds a finite hillside at x=22..23, y=8..11,
z=0..5 and a six-cell-high 48-cell designation reachable from the seeded mine
side. Existing seeded facilities remain clear and supported. Reset is an
explicit destructive operation, not an additive migration. No existing/shared
database was published, reset or otherwise mutated during implementation.

## Deliberate limitations

- No collapse, gravity, heat flow, construction-material physics, diagonal
  travel, ladders, jumping, dynamic actor blockers or blocking furniture.
- Excavation does not invent stairs or reserve an escape route. A sheer pit can
  lose its supported route to storage; goods then remain on their real elevation
  and protected support jobs pause rather than teleporting actors or resources.
  Designate a staircase/access corridor separately. Occupied support can also
  keep a job blocked until the occupant moves.
- Sparse supported-position graphs, actor-local BFS trees and planned routes are
  derived transaction-local caches, separate from authoritative material arrays.
  At most eight body graphs and 32 actor searches/routes are retained; coordinate
  origins do not accumulate unbounded cache entries. Every actual voxel write
  advances an internal invalidation epoch, including repeated writes in one chunk
  whose public revision increments only once. Dynamic reservations/goods are
  re-evaluated in actor order and are never cached as terrain.
- This change does not regenerate Godot bindings or edit the client.

## Verification

`sim/tests.rs` and `sim/contracts.rs` retain the historical flat fixture via
`new_world()` with no geometry. Their original golden fingerprints are unchanged;
the trace projects the historical tile/stack fields so added wire fields do not
change its Debug encoding. Live persistence always loads `Some(Geometry)`.

Separate `geometry/tests.rs` and `vertical/tests.rs` cover chunk indexing,
negative z, boundary checks, full footprints, arbitrary-height designations,
support, swept clearance, BFS next hops, inaccessible jobs, finite resource
conservation, pause/cancel, contention, descending excavations, hauling,
placement and dynamic IDs. Persistence tests cover all appended actor fields,
tile/stack roundtrips, chunk arrays/revision/origins, public designation fields,
private per-cell progress and SI material metadata via BSATN roundtrips.

Required gates: `just test`, `just fmt-check`, `just wasm` from the worktree root.
Disposable database integration/publish gates were added and run for the reviewer
blocker fixes below; they never target an existing server or user database.

## Reviewer-blocker regressions and profiling

The follow-up fixes add paused migration/roundtrip tests; actual seven-cell,
2×2×7 room and nine-cell upper-access execution; body-reconfiguration execution;
same-chunk/two-write cache invalidation; bounded cache storage; cached-versus-
reference BFS equivalence; dirty intent write plans; and 9216-cell/8640-cell
designation stress cases. The original golden values remain unchanged.

Repeatable native harness (links this actual module, release `opt-level=z`):

```sh
cargo run --release --manifest-path backend/spacetimedb/Cargo.toml \
  --example geometry_profile -- 5
```

Fresh physical-world simulation, five-sample native medians (milliseconds):

| Requested game seconds | Native median | Native max |
|---:|---:|---:|
| 6 | 1.817 | 1.911 |
| 60 | 1.703 | 1.794 |
| 600 | 4.282 | 4.583 |
| 3600 | 23.033 | 24.264 |
| 100000 | 401.268 | 416.591 |

A cold `mining_job` over a valid 9216-solid-cell designation takes median
1.283 ms; a completely buried 8640-cell designation returns no job in 3.072 ms.
Mining inverts target-face/footprint/reach constraints and stops at the first
eligible top-down cell, rather than multiplying every job by every reachable
position. Multiple decisions share actor BFS; travel consumes a retained route
instead of rebuilding BFS for every hop. No batching of actors, timestep changes
or silent truncation of elapsed game time is used.

Actual SpacetimeDB 2.10 native-server **WASM** gate (owned disposable server, DB,
identity and files; never an existing/shared database):

```sh
python3 backend/spacetimedb/tools/profile_live.py --migration
# Also optionally run the parent's unchanged read-only gate file:
python3 backend/spacetimedb/tools/profile_live.py --migration \
  --parent-gate /path/to/scripts/internal/vertical-terrain-check.py
```

The gate passed exact game-clock advancement at **6, 60, 600, 3600 and 100000**
and a 9216-cell stress tick, with no runtime/fuel traps. Observed cold wall time
through one scheduled tick was about 1.00 s at 6/60/3600, 0.89 s at 600 and
1.67 s at 100000; these figures include scheduler waiting and CLI/SQL polling,
not just reducer CPU. The gate also sustains three further 100000-second ticks.
The parent API gate passed real Viewer/Operator authorization, body configuration,
2×2×7 placement, finite extraction/conservation and wood supply at speed 3600.
The migration gate builds the immutable pre-vertical fixture (`4661289`, the
parent of `9d3a30d`), pauses
real nonzero-position fractional travellers, upgrades the actual database and
verifies their legacy fields, valid hops, resources, orders and clock unchanged.

No client, generated binding, main/orchestrator tree or user database was changed.
Independent review remains required before parent integration.
