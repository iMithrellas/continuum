# Continuum

Continuum is a persistent multiplayer colony simulation. The authoritative Rust
simulation runs as a SpacetimeDB module and keeps advancing while no clients are
connected. Godot subscribes directly to the database over WebSockets and sends
intent-level reducer calls; there is no separate REST server.

This first vertical slice contains a 16x16 colony, three autonomous colonists,
food production and consumption, sleep, recreation, mood, fatigue, productivity,
alerts, an event log, and a recoverable systemic failure chain:

`no recreation -> low mood -> poor sleep -> fatigue -> low productivity -> food shortage`

## Requirements

- Docker with Compose
- Rust and Cargo
- The `wasm32-unknown-unknown` Rust target
- Godot 4.7 (the vendored SDK supports Godot 4.6.1+)

Install the Rust target once:

```bash
rustup target add wasm32-unknown-unknown
```

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
retain ownership of the database.

Use `./scripts/publish --fresh` only when a breaking schema change requires
deleting existing colony data.

## Development

Run backend tests:

```bash
cargo test --manifest-path backend/spacetimedb/Cargo.toml
```

Run the headless Godot end-to-end test:

```bash
godot --headless --path client/godot --script res://tools/smoke_test.gd
```

Observe the live colony in a terminal:

```bash
godot --headless --path client/godot --script res://tools/watch.gd -- --seconds=120
```

Call reducers or query state through the containerized CLI:

```bash
./scripts/stdb sql continuum "SELECT * FROM colony"
./scripts/stdb call continuum set_time_scale 600
./scripts/stdb call continuum set_zone_enabled '{"recreation":{}}' false
./scripts/stdb call continuum reset_colony
```

After changing Rust tables, reducers, or types, publish and regenerate bindings:

```bash
./scripts/publish
./scripts/generate-bindings
```

The generation script fetches schema v10 from the running SpacetimeDB instance
and drives the vendored SDK's code generator headlessly. Generated files live in
`client/godot/spacetime_bindings/schema/` and should not be edited manually.

## Architecture

- `backend/spacetimedb/src/sim.rs`: deterministic simulation logic and tests
- `backend/spacetimedb/src/lib.rs`: tables, reducers, scheduled tick, persistence
- `client/godot/`: Godot UI, map, SDK, and generated typed bindings
- `scripts/publish`: test, WASM build, identity bootstrap, and publish workflow
- `scripts/generate-bindings`: reproducible headless Godot binding generation
- `scripts/stdb`: matching containerized SpacetimeDB CLI

SpacetimeDB is pinned to `2.10.0`. The Godot client vendors
[Flametime's upstream Godot-SpacetimeDB-SDK](https://github.com/flametime/Godot-SpacetimeDB-SDK)
`0.3.2` at commit `f6c59d7`, and uses schema v10 with `v3.bsatn.spacetimedb`.

The intended simulation speed is `6` in-game seconds per real second, or four
real hours per in-game day. Higher presets are available for development.

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
