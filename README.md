# Continuum

Continuum is a persistent multiplayer colony simulation. The authoritative Rust
simulation runs as a SpacetimeDB module and keeps advancing while no clients are
connected. Godot subscribes directly to the database over WebSockets and sends
intent-level reducer calls; there is no separate REST server.

This vertical slice contains a 24x24 colony and eight autonomous colonists, with
two workers each in farming, logging, mining, and hunting. Production, ground
items, hauling, and shared storage sit alongside food consumption, sleep,
recreation, mood, fatigue, productivity, alerts, and an event log. The recoverable
systemic failure chain remains:

`no recreation -> low mood -> poor sleep -> fatigue -> low productivity -> food shortage`

## Jobs And Hauling

Workers produce resources on their work tile, not directly into storage:

| Job | Work Zone | Output | Units Per Carried Stack |
| --- | --- | --- | ---: |
| Farming | Farm | Food | 30 |
| Logging | Forest | Wood | 25 |
| Mining | Mine | Stone | 20 |
| Hunting | Forest | Meat | 15 |

Production requires a standing order for each tile/job pair. Select a work tile
to create, pause/resume, reprioritize, or remove its orders. Priorities are
**1: high**, **2: normal**, and **3: low**. Colonists keep their fixed professions;
priorities rank eligible work sites, not jobs or workers. Forest tiles can have
separate logging and hunting orders. A disabled tile, paused order, or missing
order stops production, but does not prevent cleanup of existing piles or cargo.

Default orders are seeded only for a new or explicitly reset colony. An additive
upgrade of an existing colony starts with **zero orders**: create them manually,
or explicitly reset the colony if losing its state is acceptable. Publishing and
simulation ticks do not automatically backfill orders.

Ground piles accumulate partial or multiple stacks. Haulers batch full stacks
while a tile is producing, and collect partial piles when production stops. Each
trip carries at most one stack of that worker's job resource to an enabled storage
tile. Logging and hunting can leave separate wood
and meat piles on the same forest tile. Needs can interrupt work and delivery;
carried goods remain in the worker's hands until delivered.

The prominent **Global Hauling Mode** button applies to the whole colony:

- **Everyone: produce + haul** (`selfHaul`): all eight workers produce and haul
  their job's output. The simulation calls this role `both`.
- **Paired: producer + hauler** (`dedicatedHaulers`): each job's pair splits into
  one producer and one hauler. The producer leaves output on the ground; the
  hauler delivers only that job's resource. Hauling is a role, not a fifth job.

The button sends `set_haul_policy`; its mode and the roster's roles always come
from subscribed server state. Pending requests, permission rejections, and
connection failures are shown beside the control, without locally changing the
policy. Role assignments are derived by the simulation, not chosen by the UI.

Storage has **no capacity limit**. Colony food, wood, stone, and meat totals are
pooled stored goods, not per-tile inventories, and exclude ground piles and
carried cargo. Stack sizes limit a hauling load, not a ground pile or storage.
Food must reach storage before colonists can eat it; wood, stone, and meat are
tracked stocks with no consumer in this slice. Disabling storage blocks
deliveries, but does not delete stored goods or cargo.

The custom-drawn map uses labeled resource-colored boxes for ground piles and
attached boxes for cargo. Dashed arrows point to active delivery destinations;
they are guides, not predicted paths. A shared-stock display sits over storage
and briefly highlights replicated stock increases. The resource legend matches
the stored totals and roster cargo colors. Hover or select a pile's tile for its
amounts; compact storage and cargo amounts may be rounded. The roster shows each
worker's job, hauling role, activity, and cargo alongside their needs.

## Requirements

- Docker with Compose
- Rust and Cargo
- The `wasm32-unknown-unknown` Rust target
- Godot 4.7 (the vendored SDK supports Godot 4.6.1+)

Install the Rust target once:

```bash
rustup target add wasm32-unknown-unknown
```

## Public API

External clients use the same SpacetimeDB subscription and intent-level reducer
model as the Godot client. See [docs/API.md](docs/API.md) for the current public
tables, reducer signatures, wire examples, authorization rules, and schema
generation workflow. This is documentation of the current implementation, not a
versioned compatibility promise.

## Run Locally

Start SpacetimeDB, publish the module, generate Godot bindings, and run the game:

```bash
docker compose up -d
./scripts/publish
./scripts/generate-bindings
godot --path client/godot
```

`./scripts/publish` builds on the host and uses the matching SpacetimeDB CLI in
the container. Its login identity is stored in a Docker volume so later publishes
retain ownership of the database. On first publish, that identity is also recorded
as Continuum's admin. Because authorization is initialized with the database, use
`./scripts/publish --fresh` when first upgrading an existing unauthenticated colony.

Use `./scripts/publish --fresh` only when a breaking schema change requires
deleting existing colony data. The jobs/hauling schema adds `item_stack`, policy,
role, and cargo fields and removes storage-capacity fields; upgrading from the
previous slice requires a fresh publish and regenerated bindings. A fresh colony
also requires authorizing client identities again.

## Development

Run backend tests:

```bash
cargo test --manifest-path backend/spacetimedb/Cargo.toml
```

Run the headless Godot end-to-end test:

```bash
godot --headless --path client/godot --script res://tools/smoke_test.gd
```

The smoke test accepts the same `--stdb-host` and `--stdb-db` user arguments as
the client.

Observe the live colony in a terminal:

```bash
godot --headless --path client/godot --script res://tools/watch.gd -- --seconds=120
```

The watcher reports stored totals without capacity denominators, ground totals
separately, the global hauling policy, and every worker's job, role, activity,
and cargo each in-game hour. It also prints new events and alert changes, and
accepts `--stdb-host` and `--stdb-db` like the client.

Call reducers or query state through the containerized CLI:

```bash
./scripts/stdb sql continuum "SELECT * FROM colony"
./scripts/stdb call continuum set_time_scale 600
./scripts/stdb call continuum set_zone_enabled '{"recreation":{}}' false
./scripts/stdb call continuum set_haul_policy '{"dedicatedHaulers":{}}'
./scripts/stdb call continuum set_haul_policy '{"selfHaul":{}}'
./scripts/stdb sql continuum "SELECT * FROM item_stack"
./scripts/stdb sql continuum "SELECT * FROM work_order"
./scripts/stdb call continuum reset_colony
```

### Authorization

Continuum has two authorization roles, separate from colonists' hauling roles.
Operators may enable or disable tiles and zones, manage standing work orders,
change the global hauling policy, and acknowledge alerts. Admins inherit those permissions and are the only
callers allowed to change simulation speed, reset the colony, or authorize and
revoke operators. The scheduled tick accepts only the database scheduler identity.
Membership is stored in a private table; command and membership-change event-log
entries include the caller's full identity for auditing.

The publishing CLI identity becomes the sole admin when the database is created.
To authorize a Godot client:

1. Start the client once and copy the full `Continuum identity: ...` line from its
   terminal output. The client stores a token under `user://`, keyed by server and
   database, so subsequent runs against that colony keep the same identity.
2. Using the persistent publishing/admin CLI identity, authorize it:

```bash
./scripts/stdb call continuum set_operator '"<CLIENT_IDENTITY>"' true
```

Revoke the same client with:

```bash
./scripts/stdb call continuum set_operator '"<CLIENT_IDENTITY>"' false
```

Keep the `spacetimedb-config` Docker volume: losing its publishing token loses the
sole admin identity. A new or unauthorized client can still subscribe and observe
the colony, but command reducers reject it. The headless smoke test uses the same
persisted Godot token and must be authorized before its reducer phase can pass.

After changing Rust tables, reducers, or types, publish and regenerate bindings:

```bash
./scripts/publish
./scripts/generate-bindings
```

The generation script fetches schema v10 from the running SpacetimeDB instance
and drives the vendored SDK's code generator headlessly. Generated files live in
`client/godot/spacetime_bindings/schema/` and should not be edited manually.

## Architecture

- `backend/spacetimedb/src/lib.rs`: reducers and scheduled tick entry points
- `backend/spacetimedb/src/schema.rs`: database tables and shared types
- `backend/spacetimedb/src/auth.rs`: authorization and membership checks
- `backend/spacetimedb/src/persistence.rs`: world loading, saving, and seeding
- `backend/spacetimedb/src/events.rs`: event logging and alerts
- `backend/spacetimedb/src/sim.rs`: deterministic simulation logic
- `backend/spacetimedb/src/sim/work_orders.rs`: standing orders and site selection
- `backend/spacetimedb/src/sim/tests.rs`: simulation regression tests
- `client/godot/`: Godot UI, map, SDK, and generated typed bindings
- `scripts/publish`: test, WASM build, identity bootstrap, and publish workflow
- `scripts/generate-bindings`: reproducible headless Godot binding generation
- `scripts/stdb`: matching containerized SpacetimeDB CLI

SpacetimeDB is pinned to `2.10.0`. The Godot client vendors
[Flametime's upstream Godot-SpacetimeDB-SDK](https://github.com/flametime/Godot-SpacetimeDB-SDK)
`0.3.2` at commit `f6c59d7`, and uses schema v10 with `v3.bsatn.spacetimedb`.

The intended simulation speed is `6` in-game seconds per real second, or four
real hours per in-game day. Client speed presets are pause (`0`), `6`, `60`,
`600`, and `3600`. These controls remain admin-only: speed commands from regular
operator clients are intentionally rejected by the existing authorization rules.

## Persistence And Multiplayer

The `spacetimedb-data` Docker volume stores authoritative colony state. Normal
container restarts and `docker compose down` preserve it. Do not use
`docker compose down -v` unless you intend to delete the colony and CLI identity.

Every Godot instance connects to the same `continuum` database by default. Run a
second instance normally, or override the endpoint and database after `--`:

```bash
godot --path client/godot -- \
  --stdb-host=http://127.0.0.1:3000 --stdb-db=continuum
```
