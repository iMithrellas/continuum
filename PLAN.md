# Continuum roadmap

Reconciled on **2026-10-03** after the connected gameplay slice, against its
implementation, tests, and feature contracts. Checked items describe the implemented scope, not
completion of the broader game or certification on every platform. Unchecked
items are remaining work or verification; design principles are ordinary bullets.

## Core game

The goal is asynchronous play throughout the week: multiple players engineer a
colony that tolerates being unattended. Main progression loop:
**observe → understand → stabilize → automate → trust → expand**.

- [x] Persistent shared colony in one SpacetimeDB module database; the server scheduler advances it while clients are disconnected
- [x] Slow default simulation: six in-game seconds per real second, or **four real hours per in-game day** (within the intended 2–6-hour range)
- [x] Server-authoritative speed, admin speed/pause controls, and optional real-time cooldown on changes
- [ ] Server-owner choice of initial speed at world creation; the current seed uses the default
- [ ] Simulation-speed voting/quorum and an optional immutable-speed hardcore mode
- [ ] Soft player specialization and shared responsibility areas without hard classes
- [ ] Validate the unattended multiplayer loop through sustained play, including return comprehension and recovery from interacting failures

## Simulation

### Implemented slices

- [x] Individual hunger, fatigue, recreation, mood, productivity, sleep hours, and recent sleep quality
- [x] Autonomous goals for eating, sleeping, recreation, work, and hauling
- [x] Farming, logging, and hunting produce food, wood, and meat through compatible work orders; physical-world mining excavates finite cells for prototype stone output
- [x] Standing per-tile orders with priorities `1..=3`, pause/remove, deterministic selection, and independent forest logging/hunting orders
- [x] Self-haul or dedicated producer/hauler roles, bounded carried stacks, ground piles, and unlimited pooled storage; goods must be delivered before consumption
- [x] Instant construction of all seven semantic operational tile kinds for 20 stored wood per footprint cell; rectangular builds are atomic and limited to 4,096 cells per request
- [x] Seeded, bounded, overlapping soil fertility, forest density, and moisture fields
- [x] Persisted terrain ecology modifies farming, logging, and hunting yield deterministically; mining is unaffected
- [x] Pure goal proposal/validation/ordered-commit seam; bounded opt-in native threads plan from actor snapshots, while WASM remains serial and shared-state commits remain ordered
- [x] Recreation loss can cause lower mood and sleep quality, more fatigue, reduced productivity, and food shortage; failure/recovery and resource conservation have regression coverage

### Remaining systems

Failures should emerge primarily from understandable interactions rather than
arbitrary punishment. The recreation chain is the first implemented example.

- [ ] Food quality, social interaction, comfort/housing, safety, relationships, and richer individual wants
- [ ] Richer production chains, material-specific inventories, storage capacity, and mass-limited carrying
- [ ] Maintenance/degradation, research, population growth, and additional interacting failure chains
- [ ] Authoritative throughput accounting and server-owned explanations of why production/jobs stopped

### Construction direction

Construction should be material-driven and bottom-up rather than based on
placing semantic building entities. Function should emerge from the interaction
of designations, physical modifications, material properties, environmental
conditions, and suitability. For example, a space may progress from cleared
ground, to a storage designation, to a room with a floor, walls, and roof, and
then gain insulation or cooling until it becomes suitable for food storage. The
simulation should not require a discrete `FoodStorageBuilding` entity.

- [ ] Separate space designations from physical construction and derived function
- [ ] Support construction as incremental work with materials, labor, progress, interruption, and completion events
- [ ] Model physical modifications such as clearing, floors, walls, roofs, insulation, and cooling
- [ ] Model material properties that affect strength, thermal behavior, permeability, durability, and other outcomes
- [ ] Model environmental conditions that affect suitability and function
- [ ] Derive room and space capabilities from their actual construction and conditions
- [ ] Allow unfinished, damaged, improvised, and partially suitable spaces to remain meaningful
- [ ] Replace semantic facility requirements with capability and suitability checks wherever practical

## Unattended operation

Automation should itself be progression: players should be rewarded for making
routine situations require less attention.

- [x] Persistent standing orders and priorities; publish/load/tick do not rewrite those intents
- [x] Colony-wide meal rationing and hauling policies
- [x] Persistent per-resource production targets count stored, ground, and carried goods; targets pause eligible production (including finite physical mining) without rewriting manual pause/order intent
- [ ] Broader player-configurable policies and rule composition beyond resource targets
- [ ] Emergency procedures
- [ ] Reusable macros

## Event modes

- [x] Ordinary production continues while the server is running without connected players
- [ ] **Chill mode:** dangerous events only while someone is online
- [ ] **Scheduled mode:** dangerous events only during configured real-world windows
- [ ] **Hardcore mode:** incidents and failures can occur at any time
- [ ] Differentiate ordinary simulation failures from externally triggered dangerous events
- [ ] Allow server owners to define how punishing unattended operation should be

## World / settlements

See [physical-world coordinates and interaction](docs/vertical-terrain.md) and
[geometry verification/budgets](backend/spacetimedb/VERTICAL_GEOMETRY.md).

### Implemented slices

- [x] One persistent colony; fresh/reset worlds are 128×128 physical cells with a 24×24 starter colony and a finite hillside fixture
- [x] Authoritative 0.5 m material cells in 16³ chunks, with elevation `z = -16 .. 15`; existing initialized world dimensions survive upgrades
- [x] Explicit admin-only non-destructive expansion up to 256 cells per horizontal axis; new land is flat soil over stone
- [x] Finite excavation designations/jobs, supported navigation, body clearance, elevation-aware facilities, and protected occupied volumes
- [x] Walking uses 1.4 m per in-game second and each validated hop's 3D geometric length
- [x] Rectangular operator intents normalize reversed inclusive bounds and atomically validate placement/cost; control/order reducers skip incompatible cells and layer-aware variants target an explicit elevation
- [x] Material density, strength, conductivity, and specific heat metadata; these values do not yet drive structural or thermal physics

### Remaining world work

- [ ] Persistent named blocks/designations that can be reused, renamed, and edited
- [x] Terrain fertility, forest density, and moisture affect farming, logging, and hunting yield; physical geometry affects movement, placement, and mining
- [ ] Procedural physical landscapes beyond the seeded ecological fields and current flat/hillside fixtures
- [ ] Structural, thermal, and environmental simulation as required by material-driven construction
- [ ] Multiple settlements/outposts, remote mines/farms/industrial sites, trade, resource transfer, and expeditions
- [ ] Keep older settlements relevant while new sites introduce operational problems and parallel player responsibilities

## Observability

### Implemented slices

- [x] Replicated stocks, population, current/smoothed mood and productivity, plus per-colonist needs, goals, activity, profession, hauling role, and cargo
- [x] Bounded client-session history charts with colony-generation/clock resets
- [x] Observed resource rates since connection, estimated depletion horizons, and last-hour need trends; missing/warming/paused values stay unavailable
- [x] Local “Since you left” snapshots keyed by endpoint, database, profile, and authenticated identity; reset/backward-clock checks invalidate baselines
- [x] Event/audit messages include command caller identities as literal text; the server retains the newest 200 event rows and reset clears history
- [x] Active alerts and shared operator acknowledgement; no structured acknowledgement actor/time or alert location is available
- [x] Reversible advisory Overview guidance with operation reasons, including physical mining; selected colonist destination markers/work badges; reasons are client-derived, not authoritative throughput or proof of reachability

### Remaining observability work

- [ ] Durable away history and structured event actor/source/verb/subject data; local snapshots and the capped feed cannot provide complete absence history
- [ ] Authoritative throughput accounting and authoritative production/need degradation or stopped-job explanations; client operation reasons remain advisory observations
- [ ] Storage utilization once finite capacity exists, infrastructure health, and broader notifications
- [ ] Progression-linked instrumentation, custom player-defined metrics, and better sensors/comms
- [ ] External metrics/alerting, ideally Prometheus-compatible and usable with Grafana or custom clients
- [ ] Remote communications loss while sites continue operating; telemetry availability as a simulation mechanic

## Clients

### Implemented client slices

- [x] Godot desktop prototype handles rendering, UI, input, subscriptions, and intent dispatch; simulation authority remains server-side
- [x] Select, Build, Excavate, and Facility modes; inclusive rectangle selection, local placement/cost checks, and explicit elevation-aware reducer dispatch
- [x] Editing cancellation on Escape, right-click, invalid release/focus loss, camera gestures, and lost operator permission
- [x] Cut-height terrain, whole-entity occlusion/depth rendering, connected-region labels/patterns, cursor-anchored zoom, panning, Fit, and 1:1 controls
- [x] Cached/sparse rendering with bounded texture budgets; initial terrain snapshots and cut changes remain synchronous
- [x] Named workspaces with movable/resizable/collapsible floating panels over the full map; pinning locks geometry, and v1/v2 layouts migrate to floating-only v3
- [x] Two compact global strips, panel/workspace menu, map-local navigation, narrow-window forecast reflow, and visible action failures
- [x] Token-backed theme, licensed fonts/icons, reusable live-state components, focus handling, and reduced-motion preference
- [x] Whole-window UI scale at 100/125/150%, migration from old font-size settings, and `--settings-file=PATH`; logical font metrics are not scaled twice
- [x] Normal/admin/developer local profiles with separate identities; F9 requires server admin authority and F10 requires the developer profile
- [x] Offline menu with Join last server, Servers, Settings, and Exit; direct Join and native Start/Stop live in Servers
- [x] Connection cancellation, successful-last-server persistence, session replacement, and stale-callback/startup-handoff guards
- [x] `just` recipes for development, backend checks, client fixtures, and export staging; see [UI implementation and verification](docs/ui-redesign.md)

### Remaining clients

- [ ] Complete and validate the desktop game experience through multiplayer/unattended play
- [ ] Mobile overview, notifications, emergency actions, macros, and limited management
- [ ] Lightweight browser dashboards, alerts/logs/metrics, and macro execution
- [ ] Deliberately different client capabilities backed by server-enforced scopes

### Hosting and connection management

Current contracts: [native hosting](docs/native-hosting-contract.md) and
[Windows implementation/release gate](docs/windows-native-hosting.md).

- [x] Non-blocking native manager/controller with discovery, installation/module preparation, start, status, health, graceful stop, and timeout-confirmed force stop
- [x] First-use native server at `127.0.0.1:3001`; ordinary menu launch does not start it, client exit leaves it running, and reopen rediscovers it
- [x] Pinned SpacetimeDB 2.10.0 distribution/hashes and module digest, durable per-user data/logs/config, locks, process start identities, and snapshot-checked ownership manifests
- [x] Startup cancellation invalidates later start/join stages while an atomic download/build may finish; the UI remains responsive
- [x] Native local controls are independent of remote history entries and dedicated Docker/manual-service workflows
- [x] Linux user-systemd and Windows per-user logon-task registration/readback; Windows adapter includes dedicated console and Job Object ownership
- [x] Linux/Windows export presets and `just prepare-native-export` stage module/bootstrap assets; exported clients copy executable resources from the PCK to durable storage
- [x] Verified publisher ownership/admin bootstrap and shell-safe path handling
- [x] Searchable durable successful-connection history, separately persisted favorites, last-joined timestamps, selection, and favorite-first ordering
- [x] History canonicalizes scheme/DNS host/database and known default ports, preserves display spelling/bracketed IPv6, and uses a placeholder `default-world`; raw credential keys remain separate
- [x] History/favorite removal does not delete credentials or world data; legacy last-server import is one-time
- [x] Bounded visible-browser HTTP health probes: four concurrent requests, three-second timeout, ten-second refresh, capped backoff, last-sample/stale state, and cancellation when hidden
- [x] Health status distinguishes `unknown`, `checking`, `online`, and `unreachable`; health reachability does not assert database joinability or authentication, which remain unknown until a join

#### Verification and remaining hosting work

- [x] Existing Linux private-PID-namespace gates cover native launch/join, stop/reopen, ownership, supervisor-loss adoption, and timeout/force/restart
- [x] Existing backend-free browser/diagnostics tests cover history canonicalization, favorites, removal boundaries, bounded probes, and menu integration
- [x] Windows archives/checksums and Linux-safe adapter/PowerShell helper coverage exist
- [ ] Run real Windows lifecycle/Task Scheduler integration on a disposable Windows x86_64 account, and exercise actual login autostart on both operating systems
- [ ] Add an explicit backup/upgrade/migration flow for the pinned installed module; ordinary starts currently refuse changed digests
- [ ] Validate packaged native first-use and lifecycle behavior on release targets beyond the existing PCK/widget and source-hosting gates
- [x] Shared endpoint/database validation for direct join and history, with regression coverage for malformed addresses, limits, and existing history/credential behavior

### Multiple logical worlds in one module database

**Not integrated on current main.** Backend configuration/geometry remain
singletons, and the generated client has no world catalog. The history's
`default-world` field and unused selection hooks are scaffolding, not world
isolation. Historical runtime/API work remains available at `e421d5f` (the earlier
`task/world-backend` handoff); it needs reconciliation with current terrain,
schema, and client code before integration, rather than being marked complete.

This is a logical-world feature, not a second-process or second-database design. A
SpacetimeDB **server instance** can host a logical module database, and that one
database must contain multiple independent Continuum worlds. A physical database
per world is not the current answer, and no distributed cross-database transaction
is assumed. "World" means the simulation namespace inside one logical module DB;
"colony" is initially the one playable colony inside a world. Multiple colonies in
one world are a later model with a shared world clock and future explicit transfer
rules, not a claim that the current slice already supports them.

- [ ] Add a durable world catalog with an immutable `world_id`, human display name, canonical world slug, desired simulation state (`running`/`stopped`), and creation/update metadata as needed for discovery; make the slug unique only within its logical module DB
- [ ] Define world naming before schema work: canonical slugs are ASCII lowercase letters, digits, and hyphens; trim, case-fold, and turn supported spaces into hyphens; reject empty, non-ASCII/unsupported, reserved, over-length, and otherwise invalid names; reject collisions rather than silently merging or auto-renaming; preserve a separately validated display name, and use an explicit slug override only if the product needs names that cannot derive cleanly
- [ ] Treat `world_id` as the durable relationship key and the slug as a user-visible selector. Renaming a world must not rewrite IDs, silently break references, or silently change persisted connection targets; any slug/prefix change is an explicit operation with collision checks
- [ ] Scope every current authoritative world row by `world_id`, including the colony grid, colonists, resources and ground stacks, alerts, event log, work orders, terrain, seed, configuration/clock, speed policy, generation/reset state, and scheduler state; replace singleton assumptions and global/deterministic keys with world-qualified keys or IDs
- [ ] Define the first migration from the shipped single-world schema as an explicit adoption of all existing rows into a named default world, preserving row IDs, relationships, settings, event/reset semantics, terrain, and seed; do not choose an arbitrary world; document rollback/backup and republish behavior
- [ ] Keep world-level state separate from future colony-level state: the initial world may own the clock, policies, access model, terrain, and simulation lifecycle while the initial colony owns its grid, stock, colonists, and orders; decide each later shared policy deliberately rather than copying the current global meaning by accident
- [ ] Add a world-scoped simulation stop reducer and lifecycle state. Stopping a world pauses its simulation/tick only; it does not stop the local managed server, a remote server, the SpacetimeDB process, or other worlds. Persist the desired state, retain reads and discovery, and make start/stop authorization explicit
- [ ] Make the scheduler one global scheduled mechanism that enumerates runnable worlds, or otherwise preserve one coarse tick cadence without adding a per-colonist timer; select the simplest design compatible with current scheduled rows. A tick must carry/resolve `world_id` and a lifecycle/version guard so a stopped, reset, renamed, or recreated world cannot accept stale scheduled work
- [ ] Ensure a stopped world receives no elapsed-time catch-up on start: pause means no simulation advancement, and restart resumes from the persisted clock at the next normal interval. Guard concurrent start/stop and scheduled ticks atomically; define behavior for outstanding tick attempts and make it idempotent
- [ ] Decide and document the stopped-world command policy before reducers are changed: reads, subscriptions, discovery, and administration remain available; simulation-affecting commands are rejected by default while stopped unless an explicitly named administrative exception is justified. Do not rely on UI disabling for enforcement
- [ ] Make authorization world-aware. Preserve the current sender-scoped role discovery shape where possible, but validate membership and every target world server-side; define whether admins/operators are global database members, world memberships, or a deliberate combination. Prevent cross-world reads, commands, event/audit leakage, and role confusion, with server-side ownership checks on every reducer
- [ ] Expose world discovery/status through the server/module contract with permission-appropriate listing, creation, selection, lifecycle status, and any world-scoped role view. A stopped world remains selectable and readable; starting it requires the documented permission. Do not expose private membership rows, tokens, or unrelated worlds through public subscriptions
- [ ] Extend the client session target and user-facing connection string structurally to `host + database + world`, with optional colony selection later; do not encode world selection ambiguously into the existing SDK database argument or invent a new network URL path without confirming the provider/module contract. The client connection still authenticates to `host/database`; world selection is a post-database discovery/session concern
- [ ] Update the launch/server browser to list or discover worlds, allow permitted create/select actions, show running/stopped/unknown status, and make the selected world visible in connection status. Key successful connection history and favorites by normalized endpoint plus database plus world; retain host/database token paths and profile separation unchanged, and never store tokens in history
- [ ] Keep local settings migration explicit: the current last-successful host/database entry adopts the named default world only after the migration establishes that adoption, never by silently picking the first discovered world. Preserve existing credentials, server data, successful-last-server behavior, and history/favorite deletion boundaries
- [ ] Define future physical-database mapping only as an optional deployment concern: if used later, derive bounded deterministic names as `<world-slug>--<role>` after verifying platform/database identifier limits, reserve the delimiter, and make role names explicit. Slugs are unique only inside a logical DB, so same-slug worlds in different DBs require deployment-scope identity/registry handling; do not treat the prefix as globally unique

#### Multiple-world phases

- [ ] Phase 1: write schema/key, naming, lifecycle, command, authorization, migration, and client-target contracts; confirm SpacetimeDB scheduled reducer/table constraints and identifier limits against pinned documentation
- [ ] Phase 2: add the world catalog and migrate the current single world into an explicit default world without changing gameplay semantics or durable IDs
- [ ] Phase 3: thread world scope through persistence, reducers, views/subscriptions, event/alert reconciliation, reset/generation, and scheduler/tick guards; add world start/stop with no catch-up
- [ ] Phase 4: add permission-aware discovery/create/select/status UI and extend history/favorites/session diagnostics without changing credential keys or remote/local server ownership semantics
- [ ] Phase 5: evaluate multiple colonies per world and optional physical database deployment only after world isolation is proven; define shared clock/policy and explicit cross-colony transfer transactions then

#### Multiple-world verification

- [ ] Test slug normalization, Unicode/unsupported input, reserved/length rules, collisions, display-name preservation, rename behavior, and explicit default-world migration with IDs, refs, settings, favorites, tokens, terrain, seed, generation, and events preserved
- [ ] Test two worlds in one logical DB for isolated subscriptions, reads, writes, resets, policies, clocks, terrain, stocks, colonists, orders, alerts, event history, and sender-scoped permissions; include rejected cross-world targets and no information leakage
- [ ] Test stop/start persistence, stopped-world read/discovery access, default command rejection, atomic concurrent lifecycle changes, stale scheduler callbacks, world reset/recreate guards, normal next-interval resume, and no elapsed catch-up
- [ ] Test global scheduler fairness/cadence and that stopping one world neither stops other worlds nor the server process; separately test local managed-server stop to preserve the distinction
- [ ] Test world-aware connection selection, creation permissions, status rendering, selected-world display, history/favorite keys, legacy bookmark adoption, reconnect/session replacement, and profile token paths remaining host/database scoped

## Client diagnostics

The current client targets Godot 4.7 and SpacetimeDB 2.10.0, with vendored Flametime
SDK 0.3.2 (upstream commit `f6c59d7` plus local transport instrumentation and
[validated unit-enum database keys](docs/spacetime-enum-keys.md)). See
[protocol notes](docs/API.md#connection-and-transport) and
[the implemented session-echo contract](docs/session-ping.md).

### Implemented collection and presentation

- [x] Persisted diagnostics/graph toggles; graph enablement depends on diagnostics, and the compact input-transparent readout lives in the telemetry header
- [x] Monotonic `Time.get_ticks_usec()` frame-interval samples, bounded to 300 samples/ten seconds, with warmup and invalid/long-gap resets
- [x] Mean FPS is `N / sum(intervals)`; p50/p95/p99 are nearest-rank frame times in milliseconds; Main refreshes snapshots every 250 ms
- [x] Focus-loss resets, resume re-anchoring, and session reset handling; long frame gaps restart warmup
- [x] Authenticated, role-independent `diagnostic_echo` acknowledgements supply latest/smoothed session RTT from WebSocket send/packet-observation timestamps, excluding SDK parse/dispatch delay
- [x] Session echo RTT is surfaced in the live diagnostics UI; it measures acknowledged application request RTT, not kernel TCP RTT
- [x] One echo in flight, at least one second between probes, stale/disconnected values unavailable, graph gaps for missing samples, and SDK call cancellation on timeout/reset/disconnect
- [x] HTTP health RTT stays separate; packet loss is unavailable, and probe-timeout ratio counts settled successes/timeouts only
- [x] Existing deterministic statistics, sampler/transport, settings, layout, and isolated real-session echo tests

Frame timing measures main-loop observation, not GPU scanout/compositor latency.
Echo RTT measures the application's acknowledged request path, not kernel TCP
RTT. Neither provides packet-loss counters. No percentile-FPS equivalent is
currently displayed; any future equivalent must be labelled as such.

### Remaining diagnostics work

- [ ] Improve diagnostics beyond the current live session-echo RTT and bounded client-side history; packet loss and kernel TCP RTT remain unavailable

## API

- [x] API-first public tables and intent-level reducers shared by Godot and external clients; [protocol documentation](docs/API.md) describes the current surface
- [x] Server-enforced operator/admin permissions and authenticated sender-scoped role discovery; public state remains readable by viewers
- [x] Replicated-state reconciliation after commands; local profile/client type does not grant server authority
- [ ] Stable versioned compatibility contract beyond the current schema snapshot
- [ ] Fine-grained read-only/metrics/alerts/command scopes and capability discovery beyond current roles
- [ ] Scoped mobile/web/custom clients, CLI/TUI clients, bots, Discord integrations, and external automation

## Backend

- [x] Separate Rust SpacetimeDB module, pure composed simulation, thin responsibility-specific reducers, and explicit persistence/event/auth boundaries
- [x] Server-authoritative state and game rules; one one-second scheduler advances bounded substeps in durable actor-ID order
- [x] Behavioral golden traces, row-order independence, persistence mappings, conservation, and failure/recovery tests
- [x] Pure proposal/validate/ordered-commit intent seam preserves actor-ordered shared-state execution; opt-in native planning threads are bounded, WASM remains serial, and no speedup is claimed
- [x] Seeded four-octave fBm ecological fields and additive physical geometry migration preserve existing state
- [x] Atomic bounded construction planning, delta persistence, dirty excavation writes, and cached/resumable supported navigation
- [x] Native/WASM geometry, expansion, migration, and construction-budget fixtures for current population sizes
- [x] Native-only population benchmark isolates actor scaling from map expansion; it does not establish WASM fuel, server capacity, or a supported colonist limit
- [ ] Establish practical population limits using WASM/runtime fuel, memory, transaction and end-to-end measurements
- [ ] Narrow subscriptions to relevant/spatial state as needed; Main currently subscribes to whole public operational/terrain tables
- [ ] Reduce unnecessary actor work through event-driven scheduling where it preserves the explicit behavioral contract
- [ ] Optional external services (potentially Go) for push notifications, discovery/invites, and integrations

## Multiplayer / governance

- [x] Persistent client identities and private membership roles; the publisher bootstraps the initial admin, and admins grant/revoke operators
- [x] Operators manage facilities, excavation, work orders, hauling/meal policy, and alert acknowledgement; admins additionally manage speed, cooldown, reset, expansion, and membership
- [x] Shared command/membership audit text includes caller identity; client role discovery is sender-scoped, live, and fail-closed
- [x] Disposable private-server connected-colony regression covers authorization, disconnected scheduled progress, production/hauling/storage, and durable restart; this is not live desktop QA or sustained multiplayer play
- [ ] Soft responsibility areas and richer membership/governance UX
- [ ] Voting and minimum quorum for speed/major colony decisions, including protection against tiny overnight minorities changing server settings

## Clear Next Iterations

- [ ] Validate the persistent multiplayer leave/return/stabilize loop through sustained play
- [ ] Persistent named blocks that can be reused, renamed, and edited as first-class objects
- [ ] Material-driven construction jobs that replace the current semantic facility-building PoC
- [ ] Ecology beyond current seeded yield modifiers: depletion, regeneration, seasons, and longer-term ecological budgets
- [ ] Food quality, social interaction, comfort/housing, safety, relationships, research, population growth, and richer production chains
- [ ] Automation beyond per-resource stock targets: emergency procedures, reusable macros, and broader player-configurable policies
- [ ] Logical-world isolation before multi-settlement trade, remote sites, expeditions, and communications loss
- [ ] Real target-platform release validation and explicit installed-module upgrades; native provisioning and export staging are already implemented

The verification menu is documented in [Playing the slice](docs/playing-the-slice.md),
with [integration evidence](docs/gameplay-slice-verification.md#integrated-client-and-server-checks).
Pure gameplay, reducer, private-server, and live desktop checks have different
scopes. No gate constitutes sustained week-long multiplayer validation.

## Maintenance findings (2026-10-03)

Scouted against production references, scenes, tests, and the current data flow.
Checked entries have been addressed by the client cleanup; the other findings
remain follow-up work.

- [ ] Retire the orphaned Docker menu adapter in `client/godot/scripts/local_server_runner.gd` and its dedicated test/recipe if that retired UI path is no longer supported. Its only caller is `local_server_runner_test.gd`; Main uses `ContinuumNativeServerController`. The `just local-server` Docker CLI helper still has an explicit entry point
- [ ] Remove or deliberately integrate `ContinuumServerManagement.set_world_catalog`, `_world_catalog`, `select_world`, and `world_selected`: the catalog is never read, the methods have no callers, and the signal has no listener. Keep the logical-world design above as the source of future scope
- [x] Consolidated endpoint/database parsing in `scripts/server_endpoint.gd`, shared by the join form and history. Both reject malformed IPv6, overlong DNS names/labels, and invalid ports. The direct form retains its lowercase HTTP(S)/database policy; history retains canonical keys/display spelling, separately from raw profile credential keys
- [x] Replaced the dead-end `tcp_info`-only presentation path with live authenticated session-echo RTT in the diagnostics bar and overlay; this is application RTT, not TCP/kernel RTT
- [x] Removed uncalled `main.gd` helpers `attach_diagnostics_transport`, `_identity_token_path`, and `_compact_text`; `main_menu.gd`'s `_font_size` and `_font_size_changed`; `colony_map.gd`'s `_soil_colour` and `format_amount`; and `native_server_manager.gd`'s `_module_identity`
- [x] Removed the unused controller `request_install` queue path, adapter `manifest_fields`, Linux adapter `windows_task_command` and its obsolete test, and uncalled Windows adapter `self_test`; production start/autostart installation and the real Windows supervisor/task path remain the active implementation
- [x] Centralized need labels/inversions, optional satisfaction values, 35/15 need bands, and 24/2 resource ETA bands in `ui/components/models.gd`; observations, row adapters, and cards share them. Removed the test-only `SessionObservations.need_level` helper and redundant numeric predicate; cross-layer tests cover missing values and severity boundaries
- [ ] Reconcile older supporting prose: `docs/ui-redesign.md` still calls main's integrated UI a pre-fast-forward candidate, and `justfile`/the old Docker adapter still refer to a future launch menu

Flat-world simulation/rendering branches, golden legacy projections, v1/v2 layout
migration, and old font-setting adoption still have explicit compatibility or
regression uses. Their historical naming alone is not evidence of dead code.

## Project philosophy

- Roughly **70% learning project**: SpacetimeDB, persistent multiplayer backends, synchronization/subscriptions, simulation architecture, and API/client design
- Roughly **30% building a game we genuinely want to play**
- Keep graphics cheap enough that art does not dominate development
- Systems depth over content breadth; start narrow and make systems composable
- Avoid trying to reproduce Dwarf Fortress breadth
- Make it feel like a living, breathing system rather than disconnected mechanics

## Possible long-term distribution

- [x] Self-hosted prototype via managed native hosting or dedicated Docker/manual services
- [ ] Consider source-visible / Aseprite-like commercial model
- [ ] Paid official builds
- [ ] Open API/protocol/SDK ecosystem
- Encourage community clients and integrations
- Avoid making hosted infrastructure mandatory
