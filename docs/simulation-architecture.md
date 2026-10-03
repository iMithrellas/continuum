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
- `sim/intents.rs`: owned goal-decision inputs, pure batch proposals, and
  read-set validation before ordered commit.
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
The portable one-worker path gathers owned inputs and immediately evaluates the
pure goal decision once at each actor's ascending-ID turn. It does not allocate
an upfront batch or immediately regather unchanged inputs. Optional native
speculation is not an authoritative decision or resource reservation: at each
actor's turn a single ordered gather validates its assumptions and recomputes
the goal if any input differs, before events or destination changes.
Destination selection, retargeting, events, activity, needs and wellbeing still
commit together, serially. This is **not** all-decisions/all-actions semantics.

## Goal proposal seam and parallelism limits

Inputs contain the durable actor ID, activity/goal, needs, rest, and derived
labour/availability query results. They contain no world, navigation cache, row
indices, database handles or I/O. Query-result equality is sufficient for this
pure decision: different shared state yielding the same results cannot change
its output. Actor identity is checked at validation; indices stay local to the
schedule. The tuning is immutable for the entire step.

World gathering remains serial, including navigation's `RefCell` cache, and
occurs **only** at the actor's authoritative turn. It sees earlier pickups,
production, deposits, actor-goal changes affecting partial-pile release, and
mining geometry changes. Destinations are never speculated, so a changed
winning pile or work destination is observed even when the goal stays the same.
No World fields, revision counters, schema or persisted identity changes are
required, and no full world is cloned per actor.

The historical interval-start food snapshot is deliberately retained. If food
starts available, later actors can still choose Eat after it is exhausted; their
ordered eating action obtains only remaining stock, including earlier deposits.
If food starts empty, a deposit does not enable an Eat goal until the next bounded
interval. Refreshing this snapshot would be a gameplay change, not validation.

The default executor is portable and single-threaded. Opt-in Cargo feature
`native-parallel-intents` evaluates query-free owned goal proposals on at most
eight scoped native workers, restoring input order when joining. These provisional
inputs copy actor components, assume no labour and use interval availability
without live reachability filtering. The ordered gather validates all of those
assumptions; mismatches recompute the pure goal decision. WASM always evaluates
serially even with the feature enabled; SpacetimeDB WASM is not claimed to run
threads. The production schedule uses this executor, not a separate toy path.
Native speculation never calls a world/navigation query. Lazy navigation searches
currently resume exact canonical BFS until the requested target (not a per-query
budget), but upfront gathering can still evict other actors' cached routes because
actor/body caches are bounded. Restricting speculation to component copies avoids
both query-budget and cache-eviction effects, without cloning navigation or World.

The current goal function is cheap, and many speculative assumptions require
recomputation. Thread startup and snapshot allocation can cost more than parallel
planning saves. Population measurements found the original double-gather portable
pipeline slower; the single-gather default removes that overhead. This is a
correct plan/validate/commit extension seam, **not a performance claim** or
parallel navigation/action implementation. Extending proposals with destinations
or other reads requires extending their full validated read set first.

### Bounded population follow-up measurement

The existing native `population_profile` example compared integrated `bc506de`
(upfront gathering plus ordered regathering) with the single-gather follow-up:
`cargo run --release --manifest-path backend/spacetimedb/Cargo.toml --example
population_profile -- 3 12,48,128 12 120`. This uses opt-level=z, 12 warmup and
120 measured 60-game-second intervals per repeat (360 samples per scenario),
fixed flat 24x24 geometry, and excludes setup/validation/persistence. Repeating
with `--features native-parallel-intents` measures the query-free speculation
path. These are shared-host native observations, not WASM budgets or speedup
guarantees; host scheduling particularly affects thread startup/tail latency.

| Population / policy | Integrated p50 ms | Single-gather p50 ms | Native speculative p50 ms |
| --- | ---: | ---: | ---: |
| 12 / SelfHaul | 1.221 | 0.703 | 1.680 |
| 12 / DedicatedHaulers | 1.013 | 0.572 | 0.916 |
| 48 / SelfHaul | 6.056 | 3.417 | 5.063 |
| 48 / DedicatedHaulers | 4.513 | 2.478 | 4.258 |
| 128 / SelfHaul | 18.434 | 10.189 | 14.370 |
| 128 / DedicatedHaulers | 14.302 | 7.895 | 10.845 |

All three runs retained identical per-scenario world checksums, event counts,
activity counts and resource results. At population 128, cumulative searches
dropped from 25,886 to 13,082 (SelfHaul) and 25,816 to 13,012 (DedicatedHaulers).
The native speculative and single-gather paths also had identical navigation
graph/search/route counters. The optimized default removes the measured regression;
the threaded prototype still offers no measured speedup.

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

Construction envelopes and thermal properties are independent of operational
Tile usage. Pure `sim/buildings.rs` capabilities/query and `sim/designations.rs`
bounded usage planning preserve that separation; persisted recipe/property rows
are mapped explicitly and never inferred from Tile kinds. Envelopes protect
their support without changing navigation or claiming voxel walls/temperature
simulation. See [Building Properties](building-properties.md) for the public API,
prototype limitations, performance costs and explicit additive migration policy.

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
components, and every colonist persistence field (including empty cargo).
`sim/intent_tests.rs` scenarios cover contended food/piles, same-interval
production and deposits, mining geometry changes, row permutations, event
equality and executor sizes. Pure proposals also have submission-order parity.
Tests count exactly one gather per actor per bounded interval, and check that
native speculation cannot warm navigation or change cache-work counters under
actor/body cache pressure with saved alternate hops and fractional travel.
Run `cargo test --manifest-path backend/spacetimedb/Cargo.toml --features
native-parallel-intents` to exercise real native worker-count parity as well as
the original unmodified golden traces.
The existing hauling conservation and long-running failure/recovery tests remain.
The original internal composition refactor did not require a schema migration.
Vertical-terrain changes extend the public schema and require matching generated
client bindings; deployment must follow their explicit migration policy.
