# Continuum Public Protocol/API

This guide describes the public surface of the module at schema v10. Continuum
is a SpacetimeDB module, not an HTTP application: clients subscribe to rows and
send reducer calls over the SpacetimeDB protocol. The Godot client and an
external client use the same tables and reducers.

This is a snapshot of the current implementation. There is no versioned API
compatibility promise yet. Check the published schema and regenerate bindings
after a module change.

## Connection And Transport

The repository's pinned SDK (Flametime Godot-SpacetimeDB-SDK `0.3.2`, commit
`f6c59d7`) constructs the subscription WebSocket as:

```text
ws(s)://HOST/v1/database/DATABASE/subscribe?connection_id=...&compression=None&confirmed=false
```

The client sends `Authorization: Bearer TOKEN` during the WebSocket handshake
(the Web export puts the token in the URL). `confirmed=false` is the current
Godot connection option default; a client may explicitly choose another value.
It negotiates the SDK's `v3.bsatn.spacetimedb` subprotocol. Subscription
queries and reducer calls are then messages on that connection; there is no
separate Continuum REST server.
The exact connection and message encoding should be taken from the pinned SDK,
not reimplemented from this abbreviated description. For a remote connection,
use HTTPS/WSS and never put a real token in a URL that may be logged by a proxy,
browser history, referrer, or debug logger.

The vendored SDK also contains an HTTP helper with these currently implemented
paths:

```text
POST /v1/identity
POST /v1/database/{database}/call/{reducer}
```

Those paths are SDK helper behavior, not a separately supported Continuum API.
The first returns a token in the helper's JSON handling; the second posts JSON
arguments. Prefer the generated SDK or the matching SpacetimeDB client for
subscriptions and BSATN reducer calls.

The paths and protocol details above are implementation references from this
pinned SDK, not a promise that raw protocol details remain stable.

## Read State

The public tables are the authoritative replicated state. Subscribe with SQL
queries such as `SELECT * FROM colony`; the Godot client subscribes to all eight
tables below. `membership` is deliberately private and is not a public table.

| Table | Key fields and meaning |
| --- | --- |
| `config` | `id: u32` (always `0`); `time_scale: f64` (in-game seconds/real second); `game_seconds: f64` (in-game clock seconds); `generation: u32` (increments on reset); `haul_policy: HaulPolicy` (colony-wide hauling policy). |
| `colony` | `id: u32` (always `0`); `food`, `wood`, `stone`, `meat: f32` (stored resource units); `avg_mood`, `avg_productivity`, `smoothed_mood`, `smoothed_productivity: f32` (current and day-smoothed aggregate scores); `population: u32` (colonist count). Stored stocks exclude ground piles and carried cargo. |
| `tile` | `id: u32` (primary key); `x`, `y: i32` (grid coordinates); `kind: TileKind` (facility type); `enabled: bool` (whether the facility operates). |
| `colonist` | `id: u64` (primary key); `name: String` (display name); `x`, `y`, `target_x`, `target_y: i32` (current/target grid coordinates); `move_progress: f32` (normalized movement progress); `activity: Activity` (observable activity); `work: WorkType` (fixed profession); `haul_role: HaulRole` (server-derived role); `carried_kind: ResourceKind` (cargo kind, including the zero/default value when empty); `carried_amount: f32` (cargo units); `goal: Goal` (persistent current goal); `hunger`, `fatigue`, `recreation`, `mood`, `productivity: f32` (simulation scores); `sleep_hours`, `last_sleep_quality: f32` (recent sleep measures). |
| `item_stack` | `id: u64` (primary key); `tile_id: u32` (ground tile); `x`, `y: i32` (ground coordinates); `kind: ResourceKind` (resource); `amount: f32` (ground units). Ground piles can be partial or multiple stacks. |
| `work_order` | `id: u64` (primary key, deterministic); `tile_id: u32` (work tile); `work: WorkType` (producing profession); `priority: u8` (1 high, 2 normal, 3 low); `enabled: bool` (whether the standing intent is active). Ticks do not rewrite orders. |
| `alert` | `id: u64` (auto-increment primary key); `code: String` (unique problem key); `severity: Severity`; `message: String`; `active: bool`; `acknowledged: bool`; `raised_game_seconds: f64` (in-game clock at raise); `raised_at: Timestamp` (server timestamp). |
| `event_log` | `id: u64` (auto-increment primary key); `game_seconds: f64` (in-game clock); `day`, `hour`, `minute: u32` (display time components); `severity: Severity`; `message: String`; `at: Timestamp` (server timestamp). |

The cooldown worker adds the public `speed_control` singleton: `id: u32`
(always `0`), `cooldown_seconds: u32` (wall-clock seconds), and
`last_changed_at: Option<Timestamp>` (server timestamp of the last actual
speed change, or `None`). Its missing row is equivalent to cooldown `0` until
the first policy or speed write. See the integration-dependent
[speed-control contract](speed-controls.md).

Resource stocks in `colony` are stored goods. `item_stack` rows are ground
goods. `colonist.carried_*` is cargo in transit. They are not interchangeable:
food must be delivered to storage before it can be eaten; disabling storage
blocks delivery but does not delete stored goods or cargo. Storage has no
capacity limit in this implementation.

### Enums

Wire enum variant names use lower camel case. The generated bindings expose the
same names, for example `selfHaul` and `dedicatedHaulers`, not snake case.

| Type | Allowed values |
| --- | --- |
| `HaulPolicy` | `selfHaul`, `dedicatedHaulers` |
| `WorkType` | `none`, `logging`, `mining`, `hunting`, `farming` |
| `TileKind` | `empty`, `sleep`, `forest`, `storage`, `farm`, `mine`, `dining`, `recreation` |
| `ResourceKind` | `food`, `wood`, `stone`, `meat` |
| `HaulRole` | `both`, `producer`, `hauler` |
| `Activity` | `idle`, `travelling`, `working`, `hauling`, `eating`, `sleeping`, `recreating` |
| `Goal` | `nothing`, `eat`, `sleep`, `recreate`, `work`, `haul` |
| `Severity` | `info`, `warning`, `critical` |

The two hauling policies are colony-wide. `selfHaul` gives workers the `both`
role. `dedicatedHaulers` derives one `producer` and one `hauler` within each
fixed profession pair. Hauling roles are server-derived, not a command input;
professions are fixed.

## Commands

These are the current externally callable reducers. Arguments shown are their
Rust signatures and the generated binding types.

| Reducer | Signature | Authorization and validation |
| --- | --- | --- |
| `set_tile_enabled` | `(tile_id: u32, enabled: bool)` | Operator/admin. Unknown IDs and `empty` tiles error; the current value is a no-op. |
| `set_zone_enabled` | `(kind: TileKind, enabled: bool)` | Operator/admin. `empty` errors; changing no matching tiles is a no-op. |
| `set_work_order` | `(tile_id: u32, work: WorkType, priority: u8, enabled: bool)` | Operator/admin. Unknown tile, `none`, wrong facility, or priority outside `1..=3` errors; identical row state is a no-op. |
| `remove_work_order` | `(order_id: u64)` | Operator/admin. Unknown ID errors. |
| `set_haul_policy` | `(policy: HaulPolicy)` | Operator/admin. `selfHaul` or `dedicatedHaulers` only; missing config errors; existing policy is a no-op. |
| `acknowledge_alert` | `(alert_id: u64)` | Operator/admin. Unknown ID errors; already acknowledged is a no-op. |
| `set_time_scale` | `(time_scale: f64)` | Admin only. Baseline accepts finite `0..=100000` (the cooldown worker explicitly rejects NaN/infinity); missing config errors; unchanged value is a no-op with no timestamp update. `0` pauses the clock. |
| `reset_colony` | `()` | Admin only. Destructive reseed; no input no-op exists. It increments `config.generation`, deletes public world rows and event history, then logs the reset event. |
| `set_operator` | `(identity: Identity, authorized: bool)` | Admin only. Zero/database identities and admin membership error. `authorized=true` for an existing operator and `false` for a missing operator are idempotent no-ops; otherwise it adds/removes the operator. |
| `set_speed_change_cooldown`* | `(cooldown_seconds: u32)` | Admin only. Cooldown worker only; values above `3600` error, equal value is a no-op, and changing it does not alter `last_changed_at`. |

Work-order IDs are deterministic tuples in the current implementation: the
server derives the ID from `(tile_id, output resource)`, so priority and enabled
changes retain the same ID. Selection is ordered by
`(priority, Manhattan distance, id)`, making the final ID tie-break deterministic.
Lower numeric priority wins: `1` high, `2` normal, `3` low. Orders are not
automatically backfilled on publish or tick; defaults are seeded for a new or
explicitly reset colony only.

The event log is an audit feed, not immutable history: only the newest 200 rows
are retained, and `reset_colony` deletes the existing rows before writing its
own reset event. Preserve events externally if durable history is required.

Reducers return success, a no-op, or a rejection. A successful reducer call is
not permission to update a local cache: wait for the subscription's server
update and render that state. On timeout or disconnect, the outcome is unknown;
do not blindly retry an intent that may have committed.

`init` is the module initializer and `tick` is the scheduled internal reducer.
They are not public client commands. `tick` accepts only the database scheduler
identity. Clients must not invoke either as part of normal operation.

## Authorization And Identity

There are two authorization roles: `Operator` and `Admin`. Admins inherit
operator permissions. The publishing identity becomes the sole initial admin;
only an admin can call `set_operator(identity, authorized)`, which adds or
removes an operator. The target identity is a SpacetimeDB `Identity` value, not
the colonist ID or a display name.

Membership is stored in the private `membership` table. Unauthorized clients
can still subscribe and observe public state, but command reducers reject them.
Do not expose membership rows, admin tokens, or bearer tokens in logs or client
telemetry. Treat an identity and its token as credentials; use the persistent
publishing identity only for administration.

## Atomic Intent Flow

Subscribe first, wait for the subscription-applied event, and only then enable
controls that issue commands. Send an intent through the reducer call, show it
as pending, and reconcile the UI from replicated rows and reducer outcome. Do
not optimistically mutate `config`, `tile`, or `work_order` locally. This keeps
concurrent clients safe and makes rejection, reconnect, and server-side
normalization visible.

## Clock And Scheduler

The scheduler runs at one real-second intervals. `config.time_scale` controls how
many in-game seconds each tick advances; it is not the scheduler interval.
`set_time_scale(0.0)` pauses simulation time while the scheduler still exists.
The current client presets are `0`, `6`, `60`, `600`, and `3600`, but the reducer
accepts the wider admin-only range documented above. A client disconnect does
not pause the colony. In the cooldown worker, an actual changed speed records
`last_changed_at` using server wall time and is blocked until the configured
wall-clock cooldown elapses; setting the current speed is a no-op and does not
start or extend that cooldown.

## CLI Examples

The repository wrapper runs the matching SpacetimeDB CLI in the Compose service.
Set `DB` to the database containing the currently published module. The default
`continuum` is the baseline database; `continuum-worker-cooldown` is the ready
cooldown-worker database used by the examples below. Substitute any database
you publish the matching module to. The following reads are safe and do not
change colony state:

```bash
DB="${CONTINUUM_DB:-continuum}"
./scripts/stdb sql "$DB" "SELECT * FROM config"
./scripts/stdb sql "$DB" "SELECT * FROM colony"
./scripts/stdb sql "$DB" "SELECT * FROM tile"
./scripts/stdb sql "$DB" "SELECT * FROM colonist"
./scripts/stdb sql "$DB" "SELECT * FROM item_stack"
./scripts/stdb sql "$DB" "SELECT * FROM work_order"
./scripts/stdb sql "$DB" "SELECT * FROM alert"
./scripts/stdb sql "$DB" "SELECT * FROM event_log"
```

The reducer calls below change state and require the stated role; use only
against an isolated test database when testing writes. The tile query is
read-only and supplies the ID used by the following work-order example:

```bash
DB=continuum-worker-cooldown
./scripts/stdb call "$DB" set_haul_policy '{"dedicatedHaulers":{}}'
./scripts/stdb call "$DB" set_haul_policy '{"selfHaul":{}}'
./scripts/stdb sql "$DB" "SELECT id, x, y, kind FROM tile"
./scripts/stdb call "$DB" set_work_order 412 '{"farming":{}}' 1 true
./scripts/stdb call "$DB" set_time_scale 0
```

The seed layout makes tile `412` the farm at `(3,17)`; unlike tile `7` in the
unit fixture, it is a valid farming tile. SQL enum literals are not accepted by
this CLI for this query, so inspect the unfiltered `kind` value and choose a
row in the client or from the returned output; do not add `WHERE kind = 'farm'`.
For a database with a different layout, replace `412` with a numeric ID from
that query. The enum objects above are the JSON spelling expected by the CLI's
wire encoding. In generated Godot code, use constructors such as
`ContinuumHaulPolicy.create_dedicated_haulers()` and
`ContinuumWorkType.create_farming()` instead of hand-building JSON.

The cooldown table and reducer are available on any database published from the
cooldown worker module. For the currently available ready database, use:

```bash
DB=continuum-worker-cooldown
./scripts/stdb sql "$DB" "SELECT * FROM speed_control"
./scripts/stdb call "$DB" set_speed_change_cooldown 300
```

The command is not available in the baseline `continuum` schema. Its exact
contract is documented in [speed-controls.md](speed-controls.md).

For schema inspection, use the CLI's JSON description and the module's binding
tooling; do not infer a schema from application tables:

```bash
DB="${CONTINUUM_DB:-continuum}"
./scripts/stdb describe --json "$DB"
./scripts/generate-bindings
```

The pinned Godot generator fetches the same published schema from
`GET /v1/database/{database}/schema?version=10` before emitting bindings.

`generate-bindings` imports the Godot project, fetches the published schema from
the running SpacetimeDB instance, and regenerates
`client/godot/spacetime_bindings/`. It must be rerun after table, reducer, or
type changes. Generated files are outputs and are not hand-edited.
