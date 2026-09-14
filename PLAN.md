## Core game
- [ ] Persistent multiplayer colony that runs 24/7
- [ ] Very slow simulation, roughly **2–6 real hours per in-game day**
- [ ] Server/world chooses initial simulation speed
- [ ] Later allow simulation-speed changes through player voting/quorum
- [x] Optional cooldown on speed changes
- [ ] Optional hardcore mode with immutable speed
- [ ] Colony continues operating while nobody is online
- [ ] Designed around asynchronous play throughout the week
- [ ] Multiple players manage the same colony
- [ ] Soft player specialization without hard classes
- [ ] Colony should tolerate being unattended when engineered well
- [ ] Main progression loop: **observe → understand → stabilize → automate → trust → expand**

## Simulation
- [ ] Colonists with individual needs and wants
- [ ] Sleep and sleep quality
- [ ] Food and food quality
- [ ] Recreation
- [ ] Social interaction
- [ ] Comfort / housing quality
- [ ] Safety
- [ ] Workload / fatigue
- [ ] Relationships between colonists
- [ ] Mood
- [ ] Needs should interact and produce cascading effects
- [ ] Example: no recreation → bad mood → poor sleep → fatigue → lower productivity
- [ ] Autonomous colonists rather than direct unit control
- [ ] Jobs / work orders
- [ ] Work priorities
- [x] Instant rectangular construction for all seven operational tile kinds; construction jobs are not implemented
- [ ] Resource gathering
- [ ] Production chains
- [ ] Storage
- [ ] Logistics
- [ ] Maintenance / degradation
- [ ] Research
- [ ] Population growth
- [ ] Events / incidents
- [ ] Failures caused primarily by systems interacting, not arbitrary random punishment
- [ ] Cascading failures
- [ ] Failures should generally be understandable after investigating them

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

### Implemented slices
- [x] Needs slice: hunger, fatigue, recreation, mood, productivity, sleep hours, and recent sleep quality are simulated per colonist; social, comfort, safety, relationships, and food quality are not implemented
- [x] Autonomous colonist goals cover eating, sleeping, recreation, work, and hauling; direct unit control is not implemented
- [x] Production slice: farming, logging, mining, and hunting produce food, wood, stone, and meat on work tiles
- [x] Work-order slice: standing per-tile orders, priorities `1..=3`, pause/remove, deterministic selection, and forest's independent logging and hunting orders
- [x] Hauling slice: self-haul or dedicated producer/hauler roles, bounded carried stacks, ground piles, and unlimited pooled storage
- [x] Construction PoC: operators can instantly build any of the seven semantic operational tile kinds for 20 stored wood per cell across a fully empty rectangle; construction jobs are not implemented
- [x] Environmental slice: every tile can have seeded, bounded, overlapping soil fertility, forest density, and moisture fields; no terrain-driven production or need effects are implemented
- [x] Failure-chain slice: disabling recreation can produce unmet recreation, lower mood and sleep quality, more fatigue, lower productivity, and food shortage; this is not the full failure model

## Unattended operation
- [ ] Standing orders
- [x] Policies (meal rationing slice; broader policy systems remain)
- [ ] Priorities
- [ ] Automation
- [ ] Threshold-based behavior
- [ ] Emergency procedures
- [ ] Reusable macros
- [ ] Colony should increasingly manage routine situations automatically
- [ ] Automation should itself be progression
- [ ] Players should feel rewarded for making systems require less attention

### Implemented slices
- [x] Server scheduler advances the authoritative colony while clients are disconnected
- [x] Standing work orders persist and are not backfilled or rewritten by publish/load/tick

## Event modes
- [ ] **Chill mode:** dangerous events only while someone is online
- [ ] Normal production continues while unattended
- [ ] **Scheduled mode:** dangerous events only during configured real-world windows
- [ ] **Hardcore mode:** incidents and failures can occur at any time
- [ ] Differentiate ordinary simulation failures from externally triggered dangerous events
- [ ] Allow server owners to define how punishing unattended operation should be

## World / settlements
- [ ] Persistent main colony
- [ ] Potentially multiple settlements/outposts later
- [ ] Remote mines / farms / industrial sites
- [ ] Trade and resource transfer between settlements
- [ ] Expeditions
- [ ] New settlements introduce new operational problems
- [ ] Old settlements remain relevant instead of becoming obsolete
- [ ] Different players can manage different locations simultaneously

### Implemented slices
- [x] Persistent 24x24 seeded colony grid with seven non-empty operational tile kinds plus `empty`
- [x] Rectangular operator intents normalize reversed inclusive bounds, prevalidate builds, and charge 20 stored wood per cell
- [x] Rectangular control and work-order reducers update only non-empty or work-compatible tiles respectively; incompatible cells are skipped

## Observability
- [ ] Basic in-game status overview
- [x] Historical graphs (client-only bounded session history; no server persistence)
- [ ] Event log / audit timeline
- [ ] Explain why systems stopped or degraded
- [ ] Production throughput metrics
- [ ] Storage utilization
- [ ] Resource reserves
- [ ] Colonist mood / fatigue / productivity metrics
- [ ] Infrastructure health
- [ ] Alerts
- [ ] Alert acknowledgement
- [ ] Diagnostics improve through progression
- [ ] Instrumentation itself should be unlockable
- [ ] Custom player-defined metrics later
- [ ] External metrics endpoint later
- [ ] Ideally Prometheus-compatible metrics
- [ ] Let players use Grafana if they want
- [ ] Let players build custom alerting outside the game
- [ ] Telemetry availability can itself become part of the simulation
- [ ] Remote sites can lose communications while continuing to operate
- [ ] Better sensors/comms unlock better visibility

### Implemented slices
- [x] Replicated colony overview exposes pooled stocks, population, aggregate mood/productivity, and smoothed mood/productivity
- [x] Replicated colonist overview exposes needs, goal, activity, profession, derived hauling role, and cargo
- [x] Event/audit feed records state-changing operator commands with caller identity; only the newest 200 event rows are retained and reset clears history
- [x] Alerts can be observed and acknowledged by operators; alerting is not a general notification system yet

## Clients
- [ ] Full **Godot desktop client**
- [ ] Godot mainly handles rendering, UI and input
- [ ] Mobile client
- [ ] Mobile colony overview
- [ ] Mobile notifications
- [ ] Mobile emergency actions
- [ ] Mobile predefined macros
- [ ] Mobile limited management
- [ ] Lightweight browser client
- [ ] Browser dashboards
- [ ] Browser alerts / logs / metrics
- [ ] Browser macro execution
- [ ] Different clients intentionally have different capability levels

### Implemented client slices
- [x] Godot `Select` and `Build` modes, with a build type menu for farm, forest, mine, storage, dining, sleep, and recreation
- [x] Godot drag-to-select inclusive rectangles, including one-cell selections; Build releases dispatch one `build_tile_block` intent after local occupied-cell and wood checks
- [x] Map painting cancellation on Escape, right-click, release outside the drawn grid, or window focus loss
- [x] Select-mode block controls for enabling/disabling non-empty tiles and setting or pausing compatible farming, logging, mining, and hunting orders; incompatible cells are skipped by the reducer
- [x] Blended soil and ecological-cover terrain visualization, with independent overlapping soil/forest fields; terrain is decorative and has no production modifiers yet
- [x] Concise searchable, collapsible, draggable-width sidebar with responsive font, button, spacing, and padding scale
- [x] Role-aware sidebar controls fail closed from the authenticated sender-scoped role view; operator loss cancels Build immediately
- [x] Separate normal/admin client profiles and verified admin bootstrap flow through the authorized publisher
- [x] Offline launch menu with Join last server, Join server, Start local server, Settings, and Exit actions
- [x] Menu endpoint validation, successful-last-server persistence, cancellation, stale-callback guards, and session replacement across endpoint/profile changes
- [x] Local source-checkout server runner with Docker/Compose and POSIX/Linux process-group prerequisites, non-destructive publish path, cancellation, and process-group cleanup; binding regeneration and exported/package provisioning are not implemented
- [x] Shared base-font setting from 10..24 (default 13), persisted metric scaling, alternate `--settings-file=PATH` support, and muted menu/workspace presentation
- [x] Removed bottom legend/footer strip; map labels, inspection, panel chooser, function keys, and workspace dock provide the remaining access paths
- [x] Just-first project, client, backend, and isolated-test workflow is exposed through documented `just` recipes; helper scripts remain private

### Hosting and connection management

- [ ] Verify native SpacetimeDB support, runtime distribution, module packaging, and graceful shutdown on every target platform before implementation
- [ ] Define one shared server-manager contract for discovery, start, status, stop, autostart, health checks, and ownership; unsupported environments must report a clear reason
- [ ] Keep dedicated hosting focused on Docker or documented manual service setup; the desktop UI must never control remote hosts or offer a local stop action for them
- [ ] Add first-use provisioning for a native local server as a regular managed process, with local-only binding by default
- [ ] Pin the native runtime and module for each world; explicit upgrades only, with no rebuild or publish on every world start
- [ ] Store stable per-user server data, logs, and config in documented platform-appropriate paths, independent of the UI process
- [ ] Track single-instance ownership with a stable process identity and server data/lock identity, not PID alone; handle duplicate starts and ownership conflicts safely
- [ ] Let the UI start, inspect status, and stop managed local servers; stop gracefully, enforce a timeout, and offer force termination only after timeout
- [ ] UI exit leaves a managed server running unless the user explicitly chooses stop and exit; reopening the UI rediscovers an already-running managed process
- [ ] Keep starting a stopped server separate from enabling/disabling autostart
- [ ] Register autostart only after user login: Linux per-user `systemd` service and Windows per-user scheduled task at logon; no pre-login boot requirement
- [ ] Show managed-local status and actions distinctly from remote server ownership and actions
- [ ] Add durable server connection history from successful subscriptions only, keyed by normalized endpoint plus database identity without changing existing profile credential partitioning
- [ ] Keep history free of authentication tokens; removing history must not remove credentials or world data
- [ ] Add durable favorites and preserve them across restarts; allow history removal without removing a favorite unless explicitly requested
- [ ] Show `unknown`, `checking`, `online`, and `unreachable` in history/list views; `unreachable` is not definitive proof that a server is offline
- [ ] Record last seen and last sample time; display stale samples as stale rather than implying current status
- [ ] Measure latency using actual health/request round trips, not ICMP, and do not describe it as one-way network latency
- [ ] Show connected-session rolling RTT as latest and smoothed values; show it as unavailable when disconnected
- [ ] Bound background checks while the browser is visible with limited concurrency, timeouts, backoff, and no new subscription/reconnect per probe
- [ ] Distinguish server reachable, database joinable, and profile authentication failure in status and diagnostics
- [ ] Preserve existing menu, endpoint validation, successful-last-server persistence, cancellation, callback guards, and session replacement behavior

#### Phased work

- [ ] Phase 1: document and test the shared contract; confirm native SpacetimeDB platform support, distribution, module/runtime pinning, data paths, and shutdown behavior
- [ ] Phase 2: implement first-use native provisioning and managed-process ownership/status/recovery without changing dedicated-host setup
- [ ] Phase 3: add graceful stop/timeout handling, restart discovery, post-login autostart registration, conflict handling, and clear unsupported-platform UX
- [ ] Phase 4: add history, favorites, status/last-seen/latency presentation, bounded probes, and reachable-versus-joinable/auth diagnostics
- [ ] Phase 5: document upgrades, migrations, operational paths, and dedicated Docker/manual service guidance

#### Hosting and connection tests

- [ ] Test Linux and Windows login autostart, UI close/reopen discovery, clean shutdown, timeout/force offer, process crash recovery, duplicate starts, ownership conflicts, and paths containing spaces
- [ ] Test unsupported platforms and unavailable native distributions with actionable errors; test pinned runtime/module startup and explicit upgrade behavior
- [ ] Test remote entries cannot invoke local stop/control; test local managed actions remain separate from remote list ownership
- [ ] Test history/favorites persistence, normalized endpoint/database keys, successful subscriptions only, failed joins excluded, credential/world data retained after removal, and selection/sorting behavior
- [ ] Test probe success, timeout, backoff, stale samples, limited concurrency, no probe-created subscriptions, reachable-but-not-joinable servers, and profile authentication failures

#### Server Management menu

- [ ] Add a separate **Server Management** menu, distinct from the existing offline launch actions and from in-game colony panels; provide an explicit launch entry and a clear return path to the game/menu
- [ ] Show successful connection history in a searchable list, pin favorites above unpinned history, and preserve the existing normalized endpoint/database identity key and successful-last-server behavior
- [ ] Keep history removal, favorite removal, and local-world/server-data removal as separate explicit actions; never remove credentials or world data as a side effect of clearing history
- [ ] Include local managed-server discovery, status, start, graceful stop, timeout/force offer, and ownership-conflict details in this view; remote entries remain connection-only and cannot invoke local management controls
- [ ] Preserve the last successful action and selection when returning to the menu, while clearly distinguishing `unknown`, `checking`, `online`, `unreachable`, and stale samples
- [ ] Keep search and list operations local and bounded; background checks use the existing limited concurrency, timeout, backoff, and no-new-subscription rules

## Client diagnostics

- [ ] Add persisted Settings toggles for in-game diagnostics and, independently, a small diagnostics graph; the graph is subordinate to the main diagnostics toggle and both settings follow the existing per-device settings persistence and font scaling
- [ ] Render diagnostics as a compact, neutral technical badge/overlay rather than gameplay UI: subdued border, restrained contrast, monospace metric values where useful, no neon, safe-area placement, input pass-through when collapsed, and accessible global font scaling
- [ ] Keep the overlay unobtrusive and visually distinct from colony panels; it may show frame-time and RTT graphs with separate units and visible gaps for missing/stale data, but never imply that an absent sample is zero

### Timing and statistics contract

- [ ] Record bounded per-frame wall-clock interval samples with `Time.get_ticks_usec()` from a render/process observation point; do not use `_process(delta)` for elapsed-time measurement because `delta` follows engine time scaling, and do not use system wall-clock time
- [ ] Treat `Performance.TIME_FPS` as an optional coarse display only: the official monitor is updated once per second; `Engine.get_frames_per_second()` is also an average, not a percentile source
- [ ] Compute mean FPS over the active window as `N / sum(frame_interval_seconds)`; compute p50, p95, and p99 from the sorted frame-time samples in milliseconds using a specified nearest-rank rule (`ceil(percentile * N)`, 1-based, clamped to `1..N`)
- [ ] If an FPS equivalent is shown for a percentile, label it exactly as `p99 frame-time equivalent FPS` (and similarly for other percentiles); never label the inverse p99 frame time as `99th percentile FPS` or as “1% low average”
- [ ] Recalculate and refresh displayed statistics at a low fixed frequency rather than sorting on every frame; use a bounded time/count window and expose sample count/window age so sparse data is not overinterpreted
- [ ] Exclude paused, minimized, hidden/unfocused transition gaps, and other invalid intervals from the timing sample window; reset or segment after a long gap, show a warmup/incomplete label until the minimum sample budget is met, and do not pretend this is exact GPU presentation timing
- [ ] Document that the measurement is main-loop/render-observation timing: it identifies client frame stalls, but does not independently measure GPU scanout, compositor latency, or presentation timing

### Network diagnostics contract

- [ ] Display application-level round-trip time only: send an authenticated-independent echo/heartbeat that the current provider/SDK can support, timestamp send/response with the same monotonic clock, and keep rolling actual samples with their timestamps
- [ ] Confirm whether the pinned SpacetimeDB/Flametime SDK exposes a usable application echo/heartbeat response before implementation; if not, add the smallest provider-supported health response without mutating simulation state or requiring colony permissions
- [ ] Mark RTT unavailable when disconnected and stale after the freshness timeout; do not reuse the last value as current, and keep missing intervals visible in any graph
- [ ] Do not call WebSocket/TCP transport reliable delivery “packet loss”: generic Godot `WebSocketPeer`/TCP APIs do not expose actual IP packet-loss counters, and the current SDK protocol does not provide them
- [ ] Show `N/A` for packet loss unless verified transport counters become available; if probes are implemented, show a separately named `probe timeouts` ratio with denominator = completed probes in the observation window, include timeout/reset semantics, and never relabel it as packet loss

### Diagnostics tests

- [ ] Unit-test deterministic interval samples for mean FPS, nearest-rank p50/p95/p99 frame times, sample/window bounds, low-frequency refresh, minimum sample warmup, and correctly labelled percentile FPS equivalents
- [ ] Test stalls, pause/resume, minimize/unfocus transitions, long gaps, engine time-scale changes, session reset, and invalid/missing samples without contaminating the active timing window
- [ ] Test authenticated-independent RTT success, timeout, stale expiry, disconnect/reconnect reset, rolling timestamps, probe-timeout denominator/reset behavior, and honest `N/A` packet-loss presentation
- [ ] Test diagnostics setting persistence, graph dependency on the main toggle, safe-area/input pass-through behavior, accessibility scaling, separate frame-time/RTT units, and missing-data gaps
- [ ] Test Server Management launch/return navigation, searchable history, favorites pinned first, last-successful selection/action persistence, local management controls, remote-control isolation, and history/favorite/data deletion boundaries

### Diagnostics research references

The client is Godot `4.7` (`client/godot/project.godot`), with SpacetimeDB `2.10.0`, schema v10, and vendored Flametime Godot-SpacetimeDB-SDK `0.3.2` at commit `f6c59d7`. The current provider path is an authenticated SpacetimeDB WebSocket (`v3.bsatn.spacetimedb`) carrying subscriptions and reducer calls; there is no separate Continuum REST service. Use the pinned SDK/provider contract rather than reimplementing wire messages.

- [ ] Verify timing implementation against [Godot Performance](https://docs.godotengine.org/en/stable/classes/class_performance.html): `Performance.TIME_FPS` is a once-per-second average monitor, while `TIME_PROCESS` is a per-frame process duration and neither is a percentile history
- [ ] Verify the distinction against [Godot Engine](https://docs.godotengine.org/en/stable/classes/class_engine.html): `Engine.get_frames_per_second()` returns average rendered FPS and is not a p50/p95/p99 calculation
- [ ] Use [Godot Time](https://docs.godotengine.org/en/stable/classes/class_time.html): `Time.get_ticks_usec()` is monotonic and explicitly preferred over adjustable system clock methods for precise elapsed-time calculations
- [ ] Ground transport capability in [Godot WebSocketPeer](https://docs.godotengine.org/en/stable/classes/class_websocketpeer.html) and [Godot StreamPeerTCP](https://docs.godotengine.org/en/stable/classes/class_streampeertcp.html): available connection state, polling, buffering, and WebSocket heartbeat behavior do not constitute IP packet-loss counters
- [ ] Reconcile the implementation with the repository's [current protocol notes](docs/API.md#connection-and-transport) and [pinned SDK/runtime notes](README.md#architecture) before choosing an application echo/heartbeat path

## API
- [ ] API-first design from the beginning
- [ ] Official clients use the same underlying command model as external clients
- [ ] Godot desktop client is the most privileged
- [ ] Mobile clients have fewer capabilities
- [ ] Web client has fewer again
- [ ] Custom clients have explicitly granted scopes
- [ ] Capability/permission system
- [ ] Read-only scopes
- [ ] Metrics scopes
- [ ] Alert scopes
- [ ] Command scopes
- [ ] Intent-level commands rather than raw state mutation
- [ ] Stable versioned command/API contract
- [ ] Capability discovery
- [ ] Eventually allow custom clients
- [ ] CLI/TUI clients should be possible
- [ ] Bots should be possible
- [ ] Discord integrations should be possible
- [ ] Custom automation should be possible
- [x] Public protocol/API documentation

### Implemented slices
- [x] Public SpacetimeDB tables and reducer signatures are documented for the current schema snapshot
- [x] Operator/admin authorization is enforced server-side; unauthorized clients may still subscribe to public state
- [x] Reducer flow is intent-based with replicated-state reconciliation; the current docs make no compatibility promise

## Backend
- [ ] Separate backend project from Godot
- [ ] **Rust SpacetimeDB module**
- [ ] Keep simulation logic separated from SpacetimeDB-specific glue where practical
- [ ] Authoritative state lives server-side
- [ ] Clients subscribe only to relevant state
- [ ] Reducers/commands enforce game rules
- [ ] Slow/coarse simulation ticks rather than continuous high-frequency updates
- [ ] Event-driven updates where possible
- [ ] Scheduled state transitions
- [ ] Avoid unnecessary per-colonist ticking
- [ ] Benchmark how many colonists one SpacetimeDB instance can realistically handle
- [ ] Potentially add Go services later for things that do not belong inside SpacetimeDB
- [ ] Push notification service later
- [ ] Server discovery/invites later
- [ ] External integration services later

### Implemented slices
- [x] Separate Rust SpacetimeDB module with pure simulation core and persistence/event/auth glue
- [x] Authoritative state is persisted in public tables; scheduled ticks load, step, and save server-side state
- [x] Deterministic four-octave fBm terrain sampling is seeded and persisted; missing terrain rows are filled additively without rewriting existing fields
- [x] Rectangular build, tile-control, and compatible work-order reducers are atomic SpacetimeDB transactions

## Multiplayer / governance
- [ ] Player identity
- [ ] Colony membership
- [ ] Roles / permissions
- [ ] Soft responsibility areas
- [ ] Shared activity/audit log
- [ ] See who changed what
- [ ] Player voting
- [ ] Minimum quorum for important changes
- [ ] Simulation-speed voting
- [ ] Prevent tiny overnight minorities from changing major server settings
- [ ] Potentially use governance for other colony-wide decisions later

### Implemented slices
- [x] Publishing identity bootstraps the sole admin; admins can add or revoke operator identities
- [x] Operators can manage facilities, zones, work orders, hauling/meal policy, and alert acknowledgement; admins additionally manage speed, cooldown, reset, and membership
- [x] Command and membership changes include the caller identity in the event feed
- [x] Godot role discovery is live, sender-scoped, fail-closed on unavailable views, and reflected in the sidebar without claiming blanket permissions

## Clear Next Iterations
- [ ] Persistent named blocks that can be reused, renamed, and edited as first-class objects
- [ ] Material-driven construction jobs that replace the current semantic facility-building PoC
- [ ] Terrain effects wired into farming, forestry, moisture, movement, or other operational outcomes
- [ ] Food quality, social interaction, comfort/housing, safety, relationships, research, population growth, and richer production chains
- [ ] Threshold automation, emergency procedures, reusable macros, and player-configurable standing policies
- [ ] Multi-settlement world model, trade, remote sites, expeditions, and communications loss
- [ ] Packaged/export server provisioning and distribution workflow; current local hosting supports a source checkout with Docker Compose, while native managed hosting remains pending

## Project philosophy
- [ ] Roughly **70% learning project**
- [ ] Learn SpacetimeDB deeply
- [ ] Learn persistent multiplayer backend architecture
- [ ] Learn synchronization/subscriptions
- [ ] Learn game simulation architecture
- [ ] Learn API/client design
- [ ] Roughly **30% building a game we genuinely want to play**
- [ ] Keep graphics cheap enough that art does not dominate development
- [ ] Systems depth over content breadth
- [ ] Start narrow and make systems composable
- [ ] Avoid trying to reproduce Dwarf Fortress breadth
- [ ] Make it feel like a living, breathing system rather than a collection of disconnected mechanics

## Possible long-term distribution
- [ ] Dedicated/self-hosted servers
- [ ] Consider source-visible / Aseprite-like commercial model
- [ ] Paid official builds
- [ ] Open API/protocol/SDK ecosystem
- [ ] Encourage community clients and integrations
- [ ] Avoid making hosted infrastructure mandatory
