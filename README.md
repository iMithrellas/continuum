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

The colony also has a global meal policy. Normal meals preserve the existing
food accounting. Rationed meals use 50% of the normal food cost per simulated
eating time and recover hunger at 65% of the normal rate; the existing hunger,
mood, and productivity simulation supplies the tradeoff without a direct mood
penalty. The choice is operator-controlled, persisted in `config`, and defaults
to normal during schema migration and colony reset.

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
and briefly highlights replicated stock increases. There is no separate bottom
resource legend/footer: read stored totals from the storage stock overlay and
resource identity from the map labels and colored pile/cargo boxes. Hover or
select a pile's tile for its amounts; compact storage and cargo amounts may be
rounded. The roster shows each worker's job, hauling role, activity, and cargo
alongside their needs.

## Terrain And Block Operations

The backend persists one `world_seed` and one `terrain` row per tile. Terrain is
an environmental layer, separate from the operational `tile.kind`: a tile's
soil fertility, forest density, and moisture are continuous seeded values that
may overlap, while `tile.kind` determines the facility or work zone currently
operating there. The current simulation does not use terrain values to change
production, movement, needs, or other outcomes.

Operators can issue atomic rectangular intents over inclusive grid bounds:

- `build_tile_block` converts a fully empty rectangle to any of the seven
  non-empty operational tile kinds and costs 20 stored wood per cell.
- `set_tile_block_enabled` enables or disables all non-empty tiles in the
  rectangle; empty cells are ignored.
- `set_block_work_order` changes or creates orders only on tiles compatible with
  the selected producing work type. Forest cells independently support logging
  and hunting orders.

The reducers normalize reversed bounds, reject out-of-grid rectangles, and
reconcile from subscribed server state. A failed build is prevalidated before
wood or tiles change. See [docs/API.md](docs/API.md) for exact errors, no-op
behavior, authorization, and migration/reset semantics.

The Godot map tools expose two modes: `Select` and `Build`. In `Build`, choose
one of `Farm`, `Forest`, `Mine`, `Storage`, `Dining`, `Sleep`, or `Recreation`
from the type menu, then press and drag across empty ground and release to send
one rectangular build intent. Bounds are inclusive, so a one-cell drag is valid.
Build costs 20 stored wood per cell; the client checks occupied cells and the
available wood before dispatch, while the server performs the authoritative
atomic validation and charge.

In `Select`, press and drag to select a rectangle. The selected-block panel
provides `Enable block` and `Disable block`, plus compatible work-order rows for
`Farming`, `Logging`, `Mining`, and `Hunting`. Each row exposes priority buttons
(`H`, `N`, `L`) and `Pause`; empty and incompatible cells are skipped by the
server. Forest supports independent logging and hunting orders. The existing
selected-tile inspection remains available for per-tile details.

While dragging, Escape, right-click, releasing outside the drawn grid, or losing
window focus cancels without dispatching an intent. A valid Build-mode drag
release submits one atomic `build_tile_block` request. A Select-mode drag only
selects; the selected-block buttons separately dispatch the corresponding
enable/disable or work-order mutation. Displayed state follows the subscribed
server rows, and pending requests do not optimistically change the map.

## Native Local Hosting

Linux x86_64 can manage one durable SpacetimeDB `2.10.0` instance at
`http://127.0.0.1:3001`. Start, graceful stop, status refresh, and explicit
post-timeout force stop are available in **Servers**. The manager
persists under XDG data storage, keeps runtime helpers out of the checkout, and
refuses module digest changes until an explicit upgrade flow is added. Closing
the client leaves a healthy server running and a fresh client can rediscover it.

Native installation uses only the pinned, checksum-verified installer; missing
Cargo, wasm targets, runtime files, or module artifacts produce actionable
errors. Native lifecycle tests use the private-PID Docker workflow described in
[docs/native-hosting-contract.md](docs/native-hosting-contract.md).

## Workspace UI

The map is the primary surface. The workspace manager provides eight real game
panels: **overview**, **people**, **inspector**, **operations**, **policies**,
**alerts**, **activity**, and **trends**. It replaces the former sidebar; panel
contents are the same live colony controls and data, not prototype placeholders.

Keyboard controls are stable and ordered as follows:

| Key | Panel |
| --- | --- |
| F1 | Overview |
| F2 | People |
| F3 | Inspector |
| F4 | Operations |
| F5 | Policies |
| F6 | Alerts |
| F7 | Activity |
| F8 | Trends |

`Ctrl+F` opens the panel chooser for the active workspace. `Ctrl+\` toggles
Map mode, hiding panels so the whole viewport is available to the map. Drag a
window title bar to move it or its corner grip to resize it; neighboring edges
snap with a gutter, and holding `Alt` bypasses snapping. Pinning preserves a
panel's position and size. Restore minimized panels from the dock; reopen closed
panels through the chooser or their function key. Selecting a map block opens the
inspector unless Map mode is active. `Escape` cancels a move or resize.

The manager includes **Daily operations**, **Logistics & build**, **Colonist
welfare**, and **Diagnostics** layouts. Users can create, rename, reset, and
delete custom layouts; built-in layouts cannot be deleted. Preferences are
personal to this device and auto-save locally to `user://workspaces.json`.
They contain no colony state, roles, or replicated data. `--workspace-file=PATH`
selects an alternate file for test or disposable runs.

On narrow viewports the manager enters compact mode and shows one panel at a
time without replacing the stored desktop geometry. Unauthorized operator and
policy panels stay hidden, while the map and permitted inspection panels remain
available. Simulation speed controls are in the top header and are visible only
to admins; workspace permissions do not grant reducer authority.

Run `just test-workspaces` for the backend-free layout and viewport-input tests.

The map renders a blended soil layer and independent ecological cover. Soil
fertility, moisture, and forest density may overlap and are currently
decorative: terrain does not modify production, movement, needs, or other
simulation outcomes yet.

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

The repository uses `just` recipes for normal project, client, and backend
workflows. List the available recipes with:

```sh
just --list
```

Run the client through its offline launch menu with:

```sh
just run
```

The launch menu has four actions: `Join last server`, `Servers`, `Settings`, and
`Exit`. It starts offline; `Join last server` is disabled until a server join
succeeds, and failed validation, connection, subscription, or local provisioning
attempts are not remembered. Settings contains display and diagnostics controls;
all server controls except the last-server shortcut live in `Servers`.

`Servers` opens a separate searchable Server Management view with `Host` and
`Database` inputs, `Join server`, and native local-server controls, including
startup cancellation and login autostart. Its history lists successful connections
only, pins favorites first, preserves history in companion local files, and
performs bounded visible-only HTTP health probes. Rows label the result
as HTTP status/RTT; this is not active-session RTT. Return hides probes and restores
the menu. World selection is not exposed yet, and selecting a row joins the current
single-world SDK target (`host/database`).

`Servers` -> `Join server` requires an `http://` or `https://` host containing only a
hostname/IP (including bracketed IPv6) and an optional port from 1 through
65535. The database name must use lowercase ASCII letters and numbers
separated by dashes and be at most 128 characters.
The settings file is local to this device and stores the last successful
host/database and display preference, not replicated colony state. Auth tokens
are separate for normal and admin profiles and keyed by host/database.
Use `--settings-file=PATH` to select an alternate settings file for a test or
disposable run; the default is `user://continuum_settings.cfg`.

`Servers` -> `Start local server` installs the checksum-pinned SpacetimeDB 2.10.0 native
runtime when necessary, prepares the module once, and starts a regular process
on `http://127.0.0.1:3001`. It does **not** start Docker. A source checkout needs
Cargo and the `wasm32-unknown-unknown` target for the first module build; an
exported client needs a packaged module and installer assets. Subsequent starts
reuse the installed module and data. A different module digest is refused rather
than silently upgrading the world.

`Cancel startup` in `Servers` prevents subsequent preparation/start/join steps.
A download or build already in progress finishes its bounded atomic step safely;
the UI remains responsive. Exit uses the same cancellation boundary before closing,
rather than joining a busy worker on the UI thread. Already-running servers are
left alone.

Before exporting, run `just prepare-native-export`. The included `Linux` and
`Windows` Godot export presets include the generated module and bootstrap assets
from `client/godot/native/`. Install the matching Godot export templates, then
export the desired preset. Packaged bootstrap files are staged out of the PCK
into the per-user native directory before execution; exported clients do not
search for a source checkout or require Cargo.

Use **Servers** for local Start, Stop, Refresh, and status. Stop first requests
graceful shutdown; Force stop requires a timeout and a confirmation dialog.
Exiting the client leaves the server running, and reopening discovers it.
**Servers → Start at login** registers a Linux user-systemd
service or a Windows per-user Task Scheduler logon task. Registration state is
read back from the OS; disabling autostart does not stop the running server.

Native data, configuration, logs, runtime and module pins live under
`$XDG_DATA_HOME/Continuum/native` (default `~/.local/share/Continuum/native`) on
Linux and `%LOCALAPPDATA%/Continuum/native` on Windows. `CONTINUUM_NATIVE_ROOT`
overrides this root for isolated runs. Client identity tokens remain separate;
starting a server does not grant the game client Operator permissions.

Linux x86_64 has passed the real native lifecycle and menu integration gates in
an isolated PID namespace. Windows x86_64 uses the verified upstream native
archive and has parser, quoting, identity and state-machine coverage, but its OS
lifecycle and actual logon execution have **not** been run on this Linux host.
See [the Windows validation guide](docs/windows-native-hosting.md).
Dedicated hosting still uses the Docker recipes or a manually configured service.

`Settings` exposes a base font size from 10 through 24, default 13. It drives
the shared panel/UI metric scale and is persisted locally. The UI uses a muted
dark palette. The former bottom legend/footer strip has been removed; use map
labels, tile inspection, the panel chooser (`Ctrl+F`), function-key panels, and
the workspace dock for those access paths.
Settings also exposes `Show diagnostics` and a subordinate `Show frame/RTT graph`
toggle. Active-session RTT measures successful `diagnostic_echo` acknowledgements
at the authenticated WebSocket transport boundary, excluding local SDK parsing
and result-queue delay, with latest and smoothed values. It is unavailable when
disconnected or when the server lacks the reducer. Packet loss remains `N/A`:
WebSocket/TCP does not expose it. Probe timeouts are reported separately, and
HTTP health RTT never substitutes for session RTT.

To use the separate Docker development workflow, publish and regenerate bindings:

```sh
just setup
just run
```

`just publish` builds on the host and uses the matching SpacetimeDB CLI in
the container. Its login identity is stored in a Docker volume so later publishes
retain ownership of the database. On first publish, that identity is also recorded
as Continuum's admin. Because authorization is initialized with the database, use
`just publish-fresh` when first upgrading an existing unauthenticated colony.

Use `just publish-fresh` only when a breaking schema change requires
deleting existing colony data. The jobs/hauling schema adds `item_stack`, policy,
role, and cargo fields and removes storage-capacity fields; upgrading from the
previous slice requires a fresh publish and regenerated bindings. A fresh colony
also requires authorizing client identities again. Normal `just publish` and
`just setup` preserve the persistent database. The private test recipes below use
their own disposable containers and databases.

### Recipe Catalog

Common recipes are `setup` (publish plus bindings), `publish`,
`publish-fresh` (destructive database replacement), `bindings`, `run`, `smoke`,
`smoke-existing` (run against an already prepared server and bindings), `watch`,
and `stdb`. Backend checks are `check`, `test`, `fmt-check`, `fmt`, and `wasm`;
local server control is `up`, `down`, and `logs`. Authorization and isolated
integration gates are `admin-grant`, `admin`, `test-map-ui`,
`test-access`, `test-sidebar-access`, `test-block-reducers`, and
`test-access-cleanup`, `test-server-browser`, `test-diagnostics`, `test-native`,
`test-session-ping`, and `test-menu-host-join-e2e`. The last recipe runs native
processes only inside a private PID-namespace container; Docker is test isolation,
not the production local-server runtime.

## Development

Run backend tests:

```bash
just test
```

Run the headless Godot end-to-end test. This runs `setup` first, so it publishes
the current module and refreshes bindings for the local default `continuum`
database; it is not read-only:

```bash
just smoke
```

The smoke test accepts the same `--stdb-host` and `--stdb-db` user arguments as
the client, but those arguments affect the test client only. They do not retarget
the preparation step or prevent its publish. For an already prepared matching
server and bindings, use the non-publishing recipe instead:

```bash
just smoke-existing --stdb-host=http://127.0.0.1:3000 --stdb-db=continuum
```

Use `smoke-existing` when the target database and generated bindings already
match; it does not publish or generate bindings. The smoke test itself may issue
reducer calls, so this is not a read-only workflow.

Run the reproducible map UI gate, including input/controller coverage:

```bash
just test-map-ui
```

Run the isolated real-provider role lifecycle gate:

```bash
just test-access
```

Run the private production-main authorization gate:

```bash
just test-sidebar-access
```

The map UI gate uses a test-only subclass scene to exercise controller layout and
input assertions; production `main.tscn` always constructs the real provider. The
access gate uses a real private module, `my_role` subscription, live grant/revocation,
and disconnect/reconnect. The UI authorization gate (still named `test-sidebar-access`)
uses the production main scene,
external publisher role changes, real operator/admin reducer calls, and fail-closed
disconnect/reconnect checks. All three scripts use unique private containers,
volumes, and databases and remove them on exit; they never write the shared Compose
database.

Run the isolated rectangular-reducer integration gate:

```bash
just test-block-reducers
```

Both scripts build and publish a disposable private database in a uniquely named
SpacetimeDB container with private volumes and a dynamically assigned port. They
do not use the shared Compose database and clean up automatically; no shared DB
is required.

Observe the live colony in a terminal:

```bash
just watch --seconds=120
```

The watcher reports stored totals without capacity denominators, ground totals
separately, the global hauling policy, and every worker's job, role, activity,
and cargo each in-game hour. It also prints new events and alert changes, and
accepts `--stdb-host` and `--stdb-db` like the client.

Call reducers or query state through the containerized CLI:

```bash
just stdb sql continuum "SELECT * FROM colony"
just stdb call continuum set_time_scale 600
just stdb call continuum set_zone_enabled '{"recreation":{}}' false
just stdb call continuum set_haul_policy '{"dedicatedHaulers":{}}'
just stdb call continuum set_haul_policy '{"selfHaul":{}}'
just stdb sql continuum "SELECT * FROM item_stack"
just stdb sql continuum "SELECT * FROM work_order"
just stdb call continuum reset_colony
```

### Authorization

Continuum has two authorization roles, separate from colonists' hauling roles.
Operators may enable or disable tiles and zones, manage standing work orders,
change the global hauling and meal policies, and acknowledge alerts. Admins inherit those permissions and are the only
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
just stdb call continuum set_operator '"<CLIENT_IDENTITY>"' true
```

Revoke the same client with:

```bash
just stdb call continuum set_operator '"<CLIENT_IDENTITY>"' false
```

Keep the `spacetimedb-config` Docker volume: losing its publishing token loses the
sole admin identity. A new or unauthorized client can still subscribe and observe
the colony, but command reducers reject it. The headless smoke test uses the same
persisted Godot token and must be authorized before its reducer phase can pass.

#### Client Profiles And Role Discovery

The client discovers its own role from the authenticated sender-filtered `my_role`
view. The view returns only the caller's role; missing membership is `Viewer`.
`ContinuumAccess` starts as `Unknown` and returns to `Unknown` on disconnect,
subscription termination, or connection errors, so unavailable authorization fails
closed. The main scene applies the provider's `changed` signal only after the view is
applied. The backend remains authoritative and must not be replaced by this UI state.

Normal and admin client tokens use separate `user://` profile paths. The normal
client remains the default:

```bash
just run --profile=normal
```

On a local server, bootstrap the separate admin profile with the
persistent publishing identity (the command prompts before the grant):

```bash
just admin-grant
```

For an explicitly intended noninteractive local grant, use
`just admin-grant --yes`. Then launch the already-granted profile with:

```sh
just admin
```

The launcher verifies `Admin` through the authenticated role view before starting
the main scene. The grant recipe never runs implicitly from `admin`. Granting
requires the authorized persistent publisher identity; do not copy tokens or paste
them into the client. After backend changes, publish the module and regenerate
bindings before using an existing server:

`admin` and `admin-grant` accept the supported client-launch options; `--yes` only
bypasses the confirmation prompt. It prints the identity, never a token, and still
requires the authorized persistent publisher identity. A grant is allowed only when
the target matches the configured `CONTINUUM_PUBLISHER_HOST`; a remote publisher
may be used intentionally by setting that configuration to the same endpoint.

After changing Rust tables, reducers, or types, publish and regenerate bindings:

```bash
just bindings
```

The bindings recipe fetches schema v10 from the running SpacetimeDB instance and
drives the vendored SDK's code generator headlessly. Generated files live in
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
- `justfile`: public project, client, backend, and database recipes
- `scripts/internal/`: private helpers used by recipes; invoke recipes rather than
  these implementation details

SpacetimeDB is pinned to `2.10.0`. The Godot client vendors
[Flametime's upstream Godot-SpacetimeDB-SDK](https://github.com/flametime/Godot-SpacetimeDB-SDK)
`0.3.2` at commit `f6c59d7`, and uses schema v10 with `v3.bsatn.spacetimedb`.

The intended simulation speed is `6` in-game seconds per real second, or four
real hours per in-game day. Client speed presets are pause (`0`), `6`, `60`,
`600`, and `3600`. These controls remain admin-only: speed commands from regular
operator clients are intentionally rejected by the existing authorization rules.

## Persistence And Multiplayer

The managed native server stores authoritative state in its per-user native data
directory. Native stop/restart and client exit do not delete it. For the dedicated
Docker workflow, the `spacetimedb-data` volume stores authoritative colony state. Normal
container restarts and `just down` preserve it. Do not remove Compose volumes
unless you intend to delete the colony and CLI identity.

Every Godot instance connects to the same `continuum` database by default. Run a
second instance normally, or pass endpoint and database overrides directly as
recipe arguments:

```bash
just run --stdb-host=http://127.0.0.1:3000 --stdb-db=continuum
```
