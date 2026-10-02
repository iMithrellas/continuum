# Simulation Composition

The simulation uses composed Rust data and explicit sequential systems. It does
not use an ECS framework, inheritance hierarchy, or runtime component registry.
SpacetimeDB remains the durable authority; an in-memory `World` is a transaction's
working state, not an independently authoritative cache.

## Boundaries

- `sim/components.rs`: colonist identity plus position, movement, needs,
  wellbeing, rest, work assignment, activity state, and cargo. New actor types
  should reuse applicable components rather than inherit from `Colonist`.
- `sim/world.rs`: world collections, pooled resources, deterministic queries,
  and ground stacks. Global policies and clock are world resources, not actor
  components.
- `sim/schedule.rs`: bounded time advancement, explicit system order, and events.
- `sim/decisions.rs`: goal selection and destination validation.
- `sim/movement.rs`, `sim/needs.rs`: behavior with narrow component inputs;
  these functions can operate without a colonist or database.
- `sim/logistics.rs`, `sim/work_orders.rs`: shared-resource work and hauling.
- `sim/definitions.rs`, `sim/tuning.rs`, `sim/seed.rs`: wire enums, tuning,
  and initial state respectively.
- `persistence.rs`: explicit mapping between internal components and the flat
  persisted/public tables. Component layout does not dictate the wire schema.
- `reducers/`: authorized player intents, grouped by responsibility. Reducers
  remain thin database-facing operations, not an alternative simulation loop.

## Behavioral Contracts

Each bounded interval advances the clock, derives hauling roles, and snapshots
need-facility availability. It then processes colonists in ascending durable ID:
decision and retargeting, transition events, one activity, needs accrual, then
mood/productivity. Colony smoothing runs last. This preserves the ordering used
by the original database-loaded simulation.

Earlier actors may consume or produce shared goods before later actors decide.
Do not change this into all-decisions/all-actions phases or parallel execution
as a mechanical refactor. That is a gameplay change requiring explicit conflict
resolution and new behavioral expectations.

Storage order is not scheduling order. Indices are resolved locally for one
`step`; never persist them, put them in events, or retain them across a structural
change. Colonist IDs are unique. Future spawn/despawn commands must apply at a
step boundary, since the schedule retains indices during its substeps. Floating
aggregate accumulation also follows ID order.

Existing stack IDs use the persisted `tile_id * 4 + resource_ordinal` encoding.
Work orders currently reuse those keys. The stride is not derived from the
resource-list length. Adding resources or multiple jobs with the same output
requires an explicit collision-free identity extension/migration; do not change
existing IDs to match a new storage layout. Runtime ECS handles, if introduced,
must remain distinct from durable IDs.

Terrain and operational tile kinds remain separate. Atomic material blocks use
chunked arrays, not per-cell actors or a tile inheritance hierarchy. Entity
footprints and standing clearance are capabilities checked against that
geometry. Navigation, surface visibility, and enclosure roles are derived data;
they must not rewrite authoritative material geometry. See
[Vertical Terrain](vertical-terrain.md) for coordinate and rendering conventions.
Operational kinds remain a prototype limitation, not a taxonomy of materials
or a substitute for geometry suitability queries.

## Walking units

Cells have a `CELL_EDGE_METERS` edge of 0.5 metres. The default is ordinary
walking at 1.4 metres per **in-game second**, or 2.8 flat cells/second
(10,080 cells/in-game hour). `Tuning::move_tiles_per_hour` remains available
for existing overrides; it denotes the equivalent flat-cell rate, not a
fixed cost for slopes. Live navigation still chooses the same supported BFS
route, but travel charges each validated hop's Euclidean 3D length: a
0.5-metre horizontal hop with a 0.5-metre rise costs about 0.707 metres.
Persisted movement progress remains the fraction of the current validated
next hop in `[0, 1)`; unspent distance carries between differently sized hops
and is discarded on arrival or a blocked route.

The authoritative simulation duration controls all travel. At the current
baseline time scale of six in-game seconds per real second, one real second
of uninterrupted walking covers 8.4 metres; a 6x multiplier covers 50.4
metres. Pausing supplies no elapsed simulation time and causes no travel.
This higher default is an intentional gameplay correction, not a schema,
navigation, physics, or scheduling change. The historical golden trace pins
its original 40-cell/hour input without changing any fingerprint.

## Verification

Run `just test`, `just fmt-check`, and `just wasm` for simulation changes.
`sim/contracts.rs` contains a pre-composition trace over both hauling modes,
both meal policies, mixed step sizes, and recreation loss/recovery. Its golden
fingerprints cover explicit state fields and event ordering; they are regression
fixtures for the current numerical implementation, not a cross-platform replay
format. Do not regenerate them merely to make a refactor pass.

Additional tests cover storage-order independence, legacy keys, standalone
components, and every colonist persistence field (including empty cargo). The
existing hauling conservation and long-running failure/recovery tests remain.
The original internal composition refactor did not require a schema migration.
Vertical-terrain changes extend the public schema and require matching generated
client bindings; deployment must follow their explicit migration policy.
