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

### Implemented slices
- [x] Needs slice: hunger, fatigue, recreation, mood, productivity, sleep hours, and recent sleep quality are simulated per colonist; social, comfort, safety, relationships, and food quality are not implemented
- [x] Autonomous colonist goals cover eating, sleeping, recreation, work, and hauling; direct unit control is not implemented
- [x] Production slice: farming, logging, mining, and hunting produce food, wood, stone, and meat on work tiles
- [x] Work-order slice: standing per-tile orders, priorities `1..=3`, pause/remove, deterministic selection, and forest's independent logging and hunting orders
- [x] Hauling slice: self-haul or dedicated producer/hauler roles, bounded carried stacks, ground piles, and unlimited pooled storage
- [x] Construction slice: operators can instantly build any of the seven operational tile kinds for 20 stored wood per cell across a fully empty rectangle; construction jobs are not implemented
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
- [x] Just-first project, client, backend, and isolated-test workflow is exposed through documented `just` recipes; helper scripts remain private

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
- [ ] Construction jobs with materials, progress, labor, interruption, and completion events
- [ ] Terrain effects wired into farming, forestry, moisture, movement, or other operational outcomes
- [ ] Food quality, social interaction, comfort/housing, safety, relationships, research, population growth, and richer production chains
- [ ] Threshold automation, emergency procedures, reusable macros, and player-configurable standing policies
- [ ] Multi-settlement world model, trade, remote sites, expeditions, and communications loss

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
