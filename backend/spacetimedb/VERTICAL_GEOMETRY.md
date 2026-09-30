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
  deterministic by priority, route distance, designation ID, cell ordinal,
  work position. Work accumulates per cell; one completed solid cell produces
  one prototype stone resource unit on the work position, **not** pooled storage.
  Soil also uses this prototype stone yield; material metadata is retained in
  unfinished jobs, but soil-specific resources are not added to the wire enum.
- Removal revalidates protection of all actors' support/body volumes,
  facilities' support/reservation volumes and ground piles' support. Planning
  may move an acting miner away from its own support first; removal never happens
  while it is still standing on that cell. Completed jobs cannot yield twice;
  overlapping unfinished solid-cell designations are rejected even when paused.
- Ground piles follow existing cargo/hauling conservation, including dedicated
  haulers and partial finite piles. Disabling/canceling an intent stops extraction
  but retains already-produced goods. Cancellation discards unfinished effort.
- Transaction loads read chunk material arrays once into memory; only changed
  chunks are persisted. Revision increments once per changed chunk per loaded
  transaction, not once per individual removed voxel. Navigation/render queries
  derive from these arrays; floor/wall/ceiling labels are adjacency queries.

## Explicit additive migration

SpacetimeDB 2.10 schema defaults append the fields; all new tables are additive.
When geometry is missing on a live load, install a flat volume: soil at z=−1,
stone at z=−16..−2, air at z=0..15. This preserves every old z=0 operational
tile and actor location, resource quantity, identity, work order and existing
environmental/dirty row. No hillside or work orders are imposed on old colonies.
Old Mine work orders remain as operator intent but **do not grant infinite
production**. Operators must designate actual reachable solid cells.

Fresh init/explicit reset adds a finite hillside at x=22..23, y=8..11,
z=0..5 and a six-cell-high 48-cell designation reachable from the seeded mine
side. Existing seeded facilities remain clear and supported. Reset is an
explicit destructive operation, not an additive migration. No running/shared
database was published, reset or otherwise mutated during implementation.

## Deliberate limitations

- No collapse, gravity, heat flow, construction-material physics, diagonal
  travel, ladders, jumping, dynamic actor blockers or blocking furniture.
- Excavation does not invent stairs or reserve an escape route. A sheer pit can
  lose its supported route to storage; goods then remain on their real elevation
  and protected support jobs pause rather than teleporting actors or resources.
  Designate a staircase/access corridor separately. Occupied support can also
  keep a job blocked until the occupant moves.
- BFS is a derived in-memory query, not a persisted navmesh. This is appropriate
  for the 24×24×32 prototype; larger worlds will need revision-keyed route caches.
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
Disposable database integration/publish gates were not run.
