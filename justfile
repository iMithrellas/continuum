set shell := ["bash", "-cu"]

module_manifest := "backend/spacetimedb/Cargo.toml"
godot := env_var_or_default("GODOT", "godot")

# Check the Rust module without building the WASM artifact.
check:
    cargo check --manifest-path {{module_manifest}}

# Run the Rust simulation and module tests.
test:
    cargo test --manifest-path {{module_manifest}}

# Check Rust formatting without modifying files.
fmt-check:
    cargo fmt --manifest-path {{module_manifest}} -- --check

# Format the Rust module in place.
fmt:
    cargo fmt --manifest-path {{module_manifest}}

# Compile the SpacetimeDB module to its release WASM artifact.
wasm:
    cargo build --manifest-path {{module_manifest}} --release --target wasm32-unknown-unknown

# Start SpacetimeDB and wait until its healthcheck passes.
up:
    docker compose up -d --wait spacetimedb

# Alias for starting the local SpacetimeDB server.
spacetime: up

# Stop the local server without removing its persistent volumes.
down:
    docker compose down

# Publish the Rust module while preserving the existing database state.
publish: up
    ./scripts/publish

# Publish after deleting the database state. Use only for breaking schema changes.
publish-fresh: up
    ./scripts/publish --fresh

# Regenerate Godot bindings from the published module schema.
bindings: publish
    ./scripts/generate-bindings

# Start SpacetimeDB, publish the Rust module, and generate client bindings.
setup: bindings

# Run the Godot client against the local SpacetimeDB server.
run: up
    {{godot}} --path client/godot

# Run the headless Godot smoke test after publishing the current module.
smoke: setup
    {{godot}} --headless --path client/godot --script res://tools/smoke_test.gd

# Observe the live colony from a terminal for two minutes.
watch: up
    {{godot}} --headless --path client/godot --script res://tools/watch.gd -- --seconds=120

# Run the SpacetimeDB CLI inside the matching server container.
stdb +args:
    ./scripts/stdb {{ args }}

# Follow SpacetimeDB logs.
logs:
    docker compose logs -f spacetimedb
