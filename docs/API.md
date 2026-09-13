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
queries such as `SELECT * FROM colony`; the current Godot screen subscribes to
the operational tables it renders. `world_seed` and `terrain` are public for
clients that render the environmental layer, and the current Godot screen
subscribes to both for its map visualization. `membership` is deliberately
private and is not a public table.

| Table | Key fields and meaning |
| --- | --- |
| `config` | `id: u32` (always `0`); `time_scale: f64` (in-game seconds/real second); `game_seconds: f64` (in-game clock seconds); `generation: u32` (increments on reset); `haul_policy: HaulPolicy` (colony-wide hauling policy); `meal_policy: MealPolicy` (colony-wide meal policy, default `normal`). |
| `world_seed` | `id: u32` (always `0`); `seed: u64` (persisted procedural-world seed). Reset replaces it; additive terrain filling preserves it. |
| `colony` | `id: u32` (always `0`); `food`, `wood`, `stone`, `meat: f32` (stored resource units); `avg_mood`, `avg_productivity`, `smoothed_mood`, `smoothed_productivity: f32` (current and day-smoothed aggregate scores); `population: u32` (colonist count). Stored stocks exclude ground piles and carried cargo. |
| `tile` | `id: u32` (primary key); `x`, `y: i32` (grid coordinates); `kind: TileKind` (facility type); `enabled: bool` (whether the facility operates). |
| `terrain` | `tile_id: u32` (primary key); `soil_fertility`, `forest_density`, `moisture: f32` (seeded bounded environmental values). Fields are independent of `tile.kind` and can overlap. |
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
| `MealPolicy` | `normal`, `rationed` |
| `WorkType` | `none`, `logging`, `mining`, `hunting`, `farming` |
| `TileKind` | `empty`, `sleep`, `forest`, `storage`, `farm`, `mine`, `dining`, `recreation` |
| `ResourceKind` | `food`, `wood`, `stone`, `meat` |
| `HaulRole` | `both`, `producer`, `hauler` |
| `Activity` | `idle`, `travelling`, `working`, `hauling`, `eating`, `sleeping`, `recreating` |
| `Goal` | `nothing`, `eat`, `sleep`, `recreate`, `work`, `haul` |
| `Severity` | `info`, `warning`, `critical` |

`TileKind` is the operational layer: it is the facility/work-zone state used by
the simulation. `Terrain` is a separate environmental layer. The current
four-octave fBm sampler produces bounded values for all three terrain fields;
it does not currently affect production, movement, needs, or tile conversion.

The two hauling policies are colony-wide. `selfHaul` gives workers the `both`
role. `dedicatedHaulers` derives one `producer` and one `hauler` within each
fixed profession pair. Hauling roles are server-derived, not a command input;
professions are fixed.

Meal policy is also colony-wide. `normal` preserves the existing eating
accounting. `rationed` halves food cost per simulated eating time and reduces
hunger recovery to 65% of normal. Limited food is consumed only when available,
and hunger remains clamped to `0..=100`; no direct mood modifier is applied.

## Commands

These are the current externally callable reducers. Arguments shown are their
Rust signatures and the generated binding types.

| Reducer | Signature | Authorization and validation |
| --- | --- | --- |
| `set_tile_enabled` | `(tile_id: u32, enabled: bool)` | Operator/admin. Unknown IDs and `empty` tiles error; the current value is a no-op. |
| `build_facility` | `(tile_id: u32, kind: TileKind)` | Operator/admin. Only `dining`, `sleep`, or `recreation` may be built on an in-bounds `empty` tile. Deducts exactly `20` stored wood atomically and enables the facility; insufficient wood or invalid targets error. |
| `build_tile_block` | `(start_x: i32, start_y: i32, end_x: i32, end_y: i32, kind: TileKind)` | Operator/admin. Inclusive bounds normalize reversed endpoints. Any non-`empty` kind is accepted when every cell is in-bounds, present, and empty. Costs `20 * area` stored wood and enables every cell atomically. Empty kind, missing or occupied cells, invalid bounds, or insufficient/non-finite wood error; rejection changes no rows or audit event. |
| `set_zone_enabled` | `(kind: TileKind, enabled: bool)` | Operator/admin. `empty` errors; changing no matching tiles is a no-op. |
| `set_tile_block_enabled` | `(start_x: i32, start_y: i32, end_x: i32, end_y: i32, enabled: bool)` | Operator/admin. Inclusive normalized bounds. Applies to all non-`empty` tiles and ignores empty cells. An all-empty rectangle errors; if selected tiles already have the value it is a no-op with no event. |
| `set_work_order` | `(tile_id: u32, work: WorkType, priority: u8, enabled: bool)` | Operator/admin. Unknown tile, `none`, wrong facility, or priority outside `1..=3` errors; identical row state is a no-op. |
| `set_block_work_order` | `(start_x: i32, start_y: i32, end_x: i32, end_y: i32, work: WorkType, priority: u8, enabled: bool)` | Operator/admin. Inclusive normalized bounds and priority `1..=3`. Filters compatible facilities only: farming/farm, mining/mine, logging/forest, hunting/forest. Empty/incompatible cells are skipped; no compatible cell errors. Matching orders are inserted or updated by deterministic ID; unchanged matches are no-ops and an unchanged whole request emits no event. |
| `remove_work_order` | `(order_id: u64)` | Operator/admin. Unknown ID errors. |
| `set_haul_policy` | `(policy: HaulPolicy)` | Operator/admin. `selfHaul` or `dedicatedHaulers` only; missing config errors; existing policy is a no-op. |
| `set_meal_policy` | `(policy: MealPolicy)` | Operator/admin. `normal` or `rationed`; missing config errors; actual changes are audited, while an unchanged policy is a no-op with no event. |
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

Rectangular reducers are single reducer transactions. `build_tile_block`
prevalidates the complete rectangle before deducting wood or updating tiles.
`set_tile_block_enabled` only considers non-empty tiles, while
`set_block_work_order` filters by the work definition and preserves unrelated
orders. Forest is intentionally compatible with both logging and hunting, so
the two order IDs remain distinct for the same tile.

The event log is an audit feed, not immutable history: only the newest 200 rows
are retained, and `reset_colony` deletes the existing rows before writing its
own reset event. Preserve events externally if durable history is required.

`world_seed` and `terrain` are additive public tables. On load, a missing seed is
derived once from the persisted `config.generation` and retained; missing
terrain rows are filled from that seed for existing tiles only. Existing terrain
rows and operational rows are not regenerated by load or republish. `init` and
`reset_colony` explicitly reseed the default 24x24 layout; reset deletes public
world rows, terrain, orders, alerts, and event history, increments generation,
and restores default orders/policies. It also resets speed cooldown state.

`meal_policy` was added as the final `config` column with a SpacetimeDB schema
default of `normal`. Automatic migration populates existing config rows with
that default. New columns with defaults must remain at the end of the table
definition. A normal republish is sufficient; do not use `--delete-data` for
this feature.

Reducers return success, a no-op, or a rejection. A successful reducer call is
not permission to update a local cache: wait for the subscription's server
update and render that state. On timeout or disconnect, the outcome is unknown;
do not blindly retry an intent that may have committed.

`init` is the module initializer and `tick` is the scheduled internal reducer.
They are not public client commands. `tick` accepts only the database scheduler
identity. Clients must not invoke either as part of normal operation.

## Authorization And Identity

There are two authorization roles: `Operator` and `Admin`. Admins inherit
operator permissions. An absent member is `Viewer`. The publishing identity becomes
the sole initial admin; only an admin can call `set_operator(identity, authorized)`,
which adds or removes an operator, or `grant_admin(identity)`, which promotes/adds a
distinct admin. The target identity is a SpacetimeDB `Identity` value, not the
colonist ID or a display name.

Membership is stored in the private `membership` table. Unauthorized clients
can still subscribe and observe public state, but command reducers reject them.
Do not expose membership rows, admin tokens, or bearer tokens in logs or client
telemetry. Treat an identity and its token as credentials; use the persistent
publishing identity only for administration.

The public `my_role` view is the only client role-discovery surface. It is evaluated
with the authenticated `ViewContext` sender and returns at most that sender's private
`Membership` row; `None` means Viewer. Clients must treat the role as `Unknown` while
disconnected or before the view subscription is applied, and should refresh it after
reconnect. The server still enforces every reducer independently.

`grant_admin(identity)` is admin-only, rejects zero/database identities and
self-promotion, promotes an existing operator or adds a new admin, and is idempotent
for an existing admin. Actual membership changes create audit events with caller and
target identities. It is intended for an explicit administrator/publisher bootstrap
command, not automatic client startup.

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
just stdb sql "$DB" "SELECT * FROM config"
just stdb sql "$DB" "SELECT * FROM colony"
just stdb sql "$DB" "SELECT * FROM tile"
just stdb sql "$DB" "SELECT * FROM colonist"
just stdb sql "$DB" "SELECT * FROM item_stack"
just stdb sql "$DB" "SELECT * FROM work_order"
just stdb sql "$DB" "SELECT * FROM alert"
just stdb sql "$DB" "SELECT * FROM event_log"
```

The reducer calls below change state and require the stated role; use only
against an isolated test database when testing writes. The tile query is
read-only and supplies the ID used by the following work-order example:

```bash
DB=continuum-worker-cooldown
just stdb call "$DB" set_haul_policy '{"dedicatedHaulers":{}}'
just stdb call "$DB" set_haul_policy '{"selfHaul":{}}'
just stdb sql "$DB" "SELECT id, x, y, kind FROM tile"
just stdb call "$DB" set_work_order 412 '{"farming":{}}' 1 true
just stdb call "$DB" set_time_scale 0
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
just stdb sql "$DB" "SELECT * FROM speed_control"
just stdb call "$DB" set_speed_change_cooldown 300
```

The command is not available in the baseline `continuum` schema. Its exact
contract is documented in [speed-controls.md](speed-controls.md).

For schema inspection, use the CLI's JSON description and the module's binding
tooling; do not infer a schema from application tables:

```bash
DB="${CONTINUUM_DB:-continuum}"
just stdb describe --json "$DB"
just bindings
```

The pinned Godot generator fetches the same published schema from
`GET /v1/database/{database}/schema?version=10` before emitting bindings.

`just bindings` imports the Godot project, fetches the published schema from
the running SpacetimeDB instance, and regenerates
`client/godot/spacetime_bindings/`. It must be rerun after table, reducer, or
type changes. Generated files are outputs and are not hand-edited.
