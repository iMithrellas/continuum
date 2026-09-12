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
- [ ] Construction (instant dining/sleep/recreation facilities; no construction jobs yet)
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

## Unattended operation
- [ ] Standing orders
- [ ] Policies
- [ ] Priorities
- [ ] Automation
- [ ] Threshold-based behavior
- [ ] Emergency procedures
- [ ] Reusable macros
- [ ] Colony should increasingly manage routine situations automatically
- [ ] Automation should itself be progression
- [ ] Players should feel rewarded for making systems require less attention

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
