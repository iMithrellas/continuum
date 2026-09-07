set shell := ["bash", "-cu"]

# Start SpacetimeDB and wait until its healthcheck passes.
up:
    docker compose up -d --wait spacetimedb

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

# Run the SpacetimeDB CLI inside the matching server container.
stdb +args:
    ./scripts/stdb {{ args }}

# Follow SpacetimeDB logs.
logs:
    docker compose logs -f spacetimedb
