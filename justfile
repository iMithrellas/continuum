set shell := ["bash", "-cu"]
set positional-arguments

# Run from the Godot project root so gdlintrc/gdformatrc are discovered.
atlas_ui_gd := "scripts/workspace_deck.gd scripts/workspace_layout.gd scripts/workspace_window.gd scripts/command_card.gd scripts/main.gd scripts/main_menu.gd scripts/client_settings.gd scripts/diagnostics_overlay.gd scripts/diagnostics_bar.gd scripts/history_chart.gd scripts/ui_data.gd ui/theme/icons.gd ui/components/roster_row.gd ui/components/resource_readout.gd ui/components/activity_feed.gd ui/components/log_entry.gd ui/components/away_digest.gd tools/atlas*.gd tools/map_ui_test.gd tools/planning_test.gd tools/role_panels_test.gd tools/workspace_test.gd tools/main_menu_test.gd tools/diagnostics_integration_test.gd tools/ui_scale_test.gd"

lint-gd:
    cd client/godot && gdlint {{ atlas_ui_gd }}

fmt-gd-check:
    cd client/godot && gdformat --check {{ atlas_ui_gd }}

test-atlas-ui:
    GODOT={{ quote(godot) }} python3 client/godot/tools/atlas_ui_checks.py

# Isolated backend-free UI contracts, typed composition and exported-pack widgets.
test-ui:
    GODOT={{ quote(godot) }} python3 client/godot/tools/ui_check.py

# Requires private Xvfb on PATH; captures actual main at 48 scale/state combinations.
test-ui-render:
    GODOT={{ quote(godot) }} python3 client/godot/tools/ui_render_matrix.py --live

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

# Run the Godot client; native hosting is explicit in the Servers menu.
run *args:
    {{ quote(godot) }} --path client/godot -- "$@"

# Start the persistent local server and publish the current module.
local-server:
    scripts/internal/start-local-server

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

# Exercise physical terrain and optional additive migration in a private native server.
# Set CONTINUUM_BASELINE_WASM to also upgrade an old module without deleting its data.
test-vertical-terrain:
    scripts/internal/test-vertical-terrain

# Own disposable native resources; optional baseline upgrade and private binding generation.
test-building-properties *args: wasm
    python3 scripts/internal/test-building-properties.py "$@"

# Backend-free cut-height, surface picking and excavation interaction coverage.
test-terrain-view:
    {{ quote(godot) }} --headless --path client/godot --editor --quit
    {{ quote(godot) }} --headless --path client/godot --scene res://tools/terrain_test.tscn
    {{ quote(godot) }} --headless --path client/godot --scene res://tools/terrain_ui_test.tscn

# Camera/HUD/cache regressions plus existing backend-free client contracts.
test-map-client:
    {{ quote(godot) }} --headless --path client/godot --import
    python3 client/godot/tools/map_client_checks.py

# Include isolated software-GL 24/128/256 camera and composed shader checks.
test-map-client-render:
    {{ quote(godot) }} --headless --path client/godot --import
    python3 client/godot/tools/map_client_checks.py --gpu

# Repeat client CPU/frame/UI profiles without replacing saved comparison logs.
profile-map-client:
    {{ quote(godot) }} --headless --path client/godot --import
    python3 client/godot/tools/map_client_checks.py --gpu --profile

# Real GPU regression: spatial depth blur/darkening and sharp selection overlays.
# Requires a display; intentionally not headless (Godot's headless renderer is dummy).
test-terrain-render:
    {{ quote(godot) }} --path client/godot --rendering-method gl_compatibility --scene res://tools/terrain_render_test.tscn
    {{ quote(godot) }} --path client/godot --rendering-method gl_compatibility --scene res://tools/terrain_composed_test.tscn

# Run the backend-free workspace layout and interaction regression scene.
test-workspaces:
    {{ quote(godot) }} --headless --path client/godot --editor --quit
    {{ quote(godot) }} --headless --path client/godot --scene res://tools/workspace_test.tscn

test-access:
    scripts/internal/test-access

test-sidebar-access:
    scripts/internal/test-sidebar-access

test-block-reducers:
    scripts/internal/test-block-reducers

test-access-cleanup:
    scripts/internal/test-access-cleanup

# Exercise local-server runner lifecycle with fake child processes.
test-local-server-runner:
    scripts/internal/test-local-server-runner

# Exercise offline menu navigation, join-last guards, settings, and narrow layouts.
test-main-menu:
    scripts/internal/test-main-menu

# Exercise native first-use menu/start/join/ping/stop/reopen in a private PID namespace.
test-menu-host-join-e2e:
    scripts/internal/test-menu-host-join-e2e

# Verify endpoint/profile changes replace the cached-auth client instance.
test-session-switch:
    scripts/internal/test-session-switch

# Verify the backend-free Server Management browser, history, favorites, and HTTP probe lifecycle.
test-server-browser:
    scripts/internal/test-server-browser

# Verify diagnostics statistics, overlay behavior, and settings integration.
test-diagnostics:
    scripts/internal/test-diagnostics

# Run the authenticated reducer-ack session diagnostics gate in private Docker resources.
test-session-ping:
    scripts/internal/test-session-ping

# Exercise persistent gameplay in a disposable native server.
test-connected-colony:
    scripts/internal/test-connected-colony

# Verify stock-target authorization, persistence, and additive upgrade behavior.
test-production-automation: wasm
    python3 scripts/internal/test-production-automation.py

# Exercise physical delivery, unattended failures, and recovery without a server.
test-gameplay-core:
    cargo test --manifest-path {{ module_manifest }} --test gameplay_slice

# Backend-free connected-slice models, actual controls, bindings, and cache contracts.
# Ordered test manifest and strict bounded/private execution live in the runner.
test-gameplay-client:
    GODOT={{ quote(godot) }} python3 client/godot/tools/gameplay_client_checks.py

# Offline timeout, redaction, interruption, and owned-resource disposal regressions.
test-gate-safety:
    python3 scripts/internal/connected-colony-fault-tests.py
    python3 scripts/internal/test-production-automation-faults.py
    python3 scripts/internal/test-world-ready.py

# Exercise fresh server-authoritative world generation with default settings.
test-world-generation: wasm
    python3 scripts/internal/test-world-generation.py

# Measure native population scaling independently of map expansion.
profile-population *args:
    cargo run --release --manifest-path {{ module_manifest }} --example population_profile -- "$@"

# Stage the module and bootstrap scripts before using the Linux/Windows export presets.
prepare-native-export:
    bash scripts/internal/prepare-native-export

# Native ownership, cancellation and Windows pure-helper tests; no real host signals.
test-native:
    scripts/internal/test-native-server-manager
    godot --headless --path client/godot --editor --quit
    godot --headless --path client/godot --script res://tools/native_controller_test.gd
    {{ quote(godot) }} --headless --path client/godot --scene res://tools/native_controls_test.tscn
    {{ quote(godot) }} --headless --path client/godot --scene res://tools/session_handoff_test.tscn
    {{ quote(godot) }} --headless --path client/godot --scene res://tools/native_ready_handoff_test.tscn
    scripts/internal/test-native-server-windows
    GODOT={{ quote(godot) }} python3 scripts/internal/test-managed-servers.py

# Multi-server UI lifecycle with fake managers and disposable file/lock checks.
test-managed-servers:
    GODOT={{ quote(godot) }} python3 scripts/internal/test-managed-servers.py
