set shell := ["bash", "-cu"]
set positional-arguments

module_manifest := "backend/spacetimedb/Cargo.toml"
godot := env_var_or_default("GODOT", "godot")

# Check the Rust module without building the WASM artifact.
check:
    cargo check --manifest-path {{ module_manifest }}

# Run the Rust simulation and module tests.
test:
    cargo test --manifest-path {{ module_manifest }}

# Check Rust formatting without modifying files.
fmt-check:
    cargo fmt --manifest-path {{ module_manifest }} -- --check

# Format the Rust module in place.
fmt:
    cargo fmt --manifest-path {{ module_manifest }}

# Compile the SpacetimeDB module to its release WASM artifact.
wasm:
    cargo build --manifest-path {{ module_manifest }} --release --target wasm32-unknown-unknown

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
    scripts/internal/publish

# Publish after deleting the database state. Use only for breaking schema changes.
publish-fresh: up
    scripts/internal/publish --fresh

# Regenerate Godot bindings from the published module schema.
bindings: publish
    echo "==> importing Godot project"
    {{ quote(godot) }} --headless --path client/godot --import >/dev/null
    echo "==> generating bindings"
    {{ quote(godot) }} --headless --path client/godot --script res://tools/generate_bindings.gd
    echo "==> re-importing generated scripts"
    {{ quote(godot) }} --headless --path client/godot --import >/dev/null
    echo "==> done: client/godot/spacetime_bindings/"

# Start SpacetimeDB, publish the Rust module, and generate client bindings.
setup: bindings

# Run the Godot client against the local SpacetimeDB server.
run *args: up
    {{ quote(godot) }} --path client/godot -- "$@"

# Run the headless Godot smoke test after publishing the current module.
smoke *args: setup
    {{ quote(godot) }} --headless --path client/godot --script res://tools/smoke_test.gd -- "$@"

# Run smoke against an already running server and matching published bindings.
# The smoke test mutates the selected database while restoring its state.
smoke-existing *args:
    {{ quote(godot) }} --headless --path client/godot --script res://tools/smoke_test.gd -- "$@"

# Observe the live colony from a terminal for two minutes.
watch *args: up
    if (( $# == 0 )); then set -- --seconds=120; fi; {{ quote(godot) }} --headless --path client/godot --script res://tools/watch.gd -- "$@"

# Run the SpacetimeDB CLI inside the matching server container. Just escapes each
# positional argument, preserving spaces and shell metacharacters.
stdb *args:
    docker compose exec -T spacetimedb spacetime "$@" </dev/null

# Follow SpacetimeDB logs.
logs:
    docker compose logs -f spacetimedb

# Launch the admin-profile client. Supported flags are --grant, --yes,
# --stdb-host=URL, and --stdb-db=NAME.
admin *args:
    scripts/internal/run-admin-client "$@"

# Grant the newly bootstrapped admin profile after explicit confirmation.
admin-grant *args:
    scripts/internal/run-admin-client --grant "$@"

# Private integration gates; each owns disposable resources.
test-map-ui:
    scripts/internal/test-map-ui

test-access:
    scripts/internal/test-access

test-sidebar-access:
    scripts/internal/test-sidebar-access

test-block-reducers:
    scripts/internal/test-block-reducers

test-access-cleanup:
    scripts/internal/test-access-cleanup
