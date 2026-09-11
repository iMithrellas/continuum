# Continuum Public Protocol/API

This guide describes the public surface of the module at schema v10. Continuum
is a SpacetimeDB module, not an HTTP application: clients subscribe to rows and
send reducer calls over the SpacetimeDB protocol. The Godot client and an
external client use the same tables and reducers.

This is a snapshot of the current implementation. There is no versioned API
compatibility promise yet. Check the published schema and regenerate bindings
after a module change.

## Connection And Transport

The repository's SDK constructs the subscription WebSocket as:

```text
ws(s)://HOST/v1/database/DATABASE/subscribe?connection_id=...&compression=None&confirmed=true
```

The client sends `Authorization: Bearer TOKEN` during the WebSocket handshake
(the Web export puts the token in the URL). It negotiates the SDK's
`v3.bsatn.spacetimedb` subprotocol. Subscription queries and reducer calls are
then messages on that connection; there is no separate Continuum REST server.
The exact connection and message encoding should be taken from the pinned SDK,
not reimplemented from this abbreviated description.

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

## Read State

The public tables are the authoritative replicated state. Subscribe with SQL
queries such as `SELECT * FROM colony`; the Godot client subscribes to all eight
tables below. `membership` is deliberately private and is not a public table.

| Table | Key fields and meaning |
| --- | --- |
| `config` | Singleton `id = 0`; `time_scale: f64`, `game_seconds: f64`, `generation: u32`, and `haul_policy`. |
| `colony` | Singleton colony stocks and aggregate state: `food`, `wood`, `stone`, `meat`, mood/productivity aggregates, and `population`. Stored stocks exclude ground piles and carried cargo. |
| `tile` | `id`, coordinates, `kind`, and `enabled`. Kinds are `empty`, `sleep`, `forest`, `storage`, `farm`, `mine`, `dining`, `recreation`. |
| `colonist` | Position/activity and needs plus fixed `work`, derived `haul_role`, and `carried_kind`/`carried_amount`. |
| `item_stack` | Ground pile: `id`, `tile_id`, position, resource `kind`, and `amount`. Ground piles can be partial or multiple stacks. |
| `work_order` | Persistent standing intent: `id`, `tile_id`, `work`, `priority`, and `enabled`. Ticks do not rewrite orders. |
| `alert` | One row per alert code: severity, message, active/acknowledged state, and timestamps. |
| `event_log` | Auditable simulation and command events with game time, severity, message, and server timestamp. |

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
| `set_tile_enabled` | `(tile_id: u32, enabled: bool)` | Operator or admin. Unknown IDs and `empty` tiles are rejected; setting the existing value is a no-op. |
| `set_zone_enabled` | `(kind: TileKind, enabled: bool)` | Operator or admin. `empty` is rejected; setting all matching tiles to the requested state is otherwise idempotent. |
| `set_work_order` | `(tile_id: u32, work: WorkType, priority: u8, enabled: bool)` | Operator or admin. `work` must produce on that facility: farming/farm, logging/forest, mining/mine, hunting/forest. `priority` must be 1, 2, or 3. Same tuple state is a no-op. |
| `remove_work_order` | `(order_id: u64)` | Operator or admin. Unknown IDs are rejected. |
| `set_haul_policy` | `(policy: HaulPolicy)` | Operator or admin. Existing policy is a no-op. |
| `acknowledge_alert` | `(alert_id: u64)` | Operator or admin. Unknown IDs and already acknowledged alerts are rejected/no-op respectively. |
| `set_time_scale` | `(time_scale: f64)` | Admin only. Range is `0..=100000`; `0` pauses the clock. |
| `reset_colony` | `()` | Admin only. Destructive development helper; reseeds the colony and increments `config.generation`. |
| `set_operator` | `(identity: Identity, authorized: bool)` | Admin only. Adds or removes an operator. Zero and database identities, and admin membership, are rejected. |

Work-order IDs are deterministic tuples in the current implementation: the
server derives the ID from `(tile_id, output resource)`, so priority and enabled
changes retain the same ID. Selection is ordered by
`(priority, Manhattan distance, id)`, making the final ID tie-break deterministic.
Lower numeric priority wins: `1` high, `2` normal, `3` low. Orders are not
automatically backfilled on publish or tick; defaults are seeded for a new or
explicitly reset colony only.

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
not pause the colony.

## CLI Examples

The repository wrapper runs the matching SpacetimeDB CLI in the Compose service.
The following reads are safe and do not change colony state:

```bash
./scripts/stdb sql continuum "SELECT * FROM config"
./scripts/stdb sql continuum "SELECT * FROM colony"
./scripts/stdb sql continuum "SELECT * FROM tile"
./scripts/stdb sql continuum "SELECT * FROM colonist"
./scripts/stdb sql continuum "SELECT * FROM item_stack"
./scripts/stdb sql continuum "SELECT * FROM work_order"
./scripts/stdb sql continuum "SELECT * FROM alert"
./scripts/stdb sql continuum "SELECT * FROM event_log"
```

These calls change state and require the stated role; use only against an
isolated test database when testing writes:

```bash
./scripts/stdb call continuum set_haul_policy '{"dedicatedHaulers":{}}'
./scripts/stdb call continuum set_haul_policy '{"selfHaul":{}}'
./scripts/stdb call continuum set_work_order 7 '{"farming":{}}' 1 true
./scripts/stdb call continuum set_time_scale 0
```

The enum objects above are the JSON spelling expected by the CLI's wire
encoding. In generated Godot code, use constructors such as
`ContinuumHaulPolicy.create_dedicated_haulers()` and
`ContinuumWorkType.create_farming()` instead of hand-building JSON.

For schema inspection, use the CLI's JSON description and the module's binding
tooling; do not infer a schema from application tables:

```bash
./scripts/stdb describe --json continuum
./scripts/generate-bindings
```

`generate-bindings` imports the Godot project, fetches the published schema from
the running SpacetimeDB instance, and regenerates
`client/godot/spacetime_bindings/`. It must be rerun after table, reducer, or
type changes. Generated files are outputs and are not hand-edited.
