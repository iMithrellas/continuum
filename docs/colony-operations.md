# Colony operations snapshot

`client/godot/scripts/colony_operations_model.gd` is a pure, read-only advisory
model. It makes no reducer calls and is **not** a server-authoritative job-reason
table. Call with complete current replicated collections (not incremental deltas):

```gdscript
const Operations = preload("res://scripts/colony_operations_model.gd")
var entries = Operations.snapshot(tiles, orders, colonists, stacks, resources, policies, context)
```

Exact public API:

```gdscript
static func snapshot(tiles: Array, orders: Array, colonists: Array, stacks: Array, resources: Dictionary, policies: Array = [], context: Dictionary = {}) -> Array[Dictionary]
```

## Inputs and normalization

Dictionary fixtures and generated SDK row objects are accepted. Fields use the
existing dictionary/property adapter pattern. Enums accept SDK objects or
`{value: ordinal}`, integer ordinals, and case-insensitive names. Unknown values
are not clamped. Tile identifiers are nonnegative integers; absent navigation
targets return `-1`. Malformed relevant rows conservatively downgrade negative
diagnoses where possible; this does not detect incomplete subscriptions. The
caller must gate on subscription readiness, since empty arrays mean known empty.

- Tiles: `id`, `kind`, `enabled`.
- Work orders: `tile_id`, `work`, `enabled`; a matching enabled facility is required.
- Colonists: `id`, `work`, `haul_role`, `activity`, `goal`, `carried_kind`, `carried_amount`.
- Item stacks: `id`, `tile_id`, `kind`, `amount`; all matching resource stacks count,
  even on a disabled site.
- Resources: stored colony totals keyed by `food`, `wood`, `stone`, `meat`.
  Missing/invalid totals return `null`, not an invented zero.
- Optional policies: actual `production_policy` rows with resource enum `resource`
  and finite `target` in `(0, 1,000,000]`, per the finalized
  [production automation contract](production-automation.md). Absent means unlimited;
  invalid/ambiguous targets are never clamped into inferred enforcement.
- Optional context: `physical_world: bool` and `excavation_designations: Array`.
  Only explicit `physical_world: true` selects live finite mining. Omitting context
  or setting false preserves the legacy flat facility/work-order behavior and
  all existing five/six-argument calls remain compatible.

## Output contract

Four entries always appear in stable order:

| key / work_key | name / work_name | facility | resource |
| --- | --- | --- | --- |
| logging | Logging | Forest | wood |
| mining | Mining | Mine | stone |
| hunting | Hunting | Forest | meat |
| farming | Farming | Farm | food |

Each entry has `state`, `summary`, `detail`, `suggested_action`, `focus_tile_id`,
`ready_workers`, `active_orders`, `ground_amount`, `stored_amount`, plus
`carried_amount`, `policy_targets`, `target`, `total_supply`, and `supply_complete`.
The focus is the lowest active site ID,
then enabled facility, then any matching facility, then a ground-stack tile.

`ready_workers` counts known producing roles not currently attending needs,
hauling, or carrying cargo, with a known activity and explicit zero cargo. It is
an observed eligibility count, **not** a reachable-worker count. `active_orders`
counts enabled matching orders on enabled facilities, not worker assignments.

## Standing production targets

Pass the subscribed `production_policy` table rows as `policies`. `target` is the
effective valid per-resource threshold, or `null` for absent, invalid, duplicate,
or otherwise ambiguous policy evidence. `policy_targets` retains the sorted list
of valid supplied values for compatibility; it is not a substitute for `target`.

`total_supply` is stored + ground + carried for this resource, or `null` when any
relevant component is missing, negative, nonfinite, or malformed. `supply_complete`
describes this numeric coverage, not network subscription readiness. Unknown pile
or carrier kinds with positive/unknown quantities prevent completeness; explicit
zero with unknown kind contributes zero safely. Known other-resource rows do not
affect this resource. Cargo is counted regardless of carrier profession or role.
Duplicate relevant durable IDs invalidate completeness. Component fields remain
observed accepted quantities, so their partial sums must not be used to infer
threshold suspension when `supply_complete` is false.

`target_reached` reports **expected output suspension**, not a server job-reason
row: enabled intent exists, a valid target exists, all supply components are known,
and `total_supply >= target`. It takes precedence over worker/activity/needs and
haul observations, but **not** absent/disabled facilities or orders, missing/paused
designations, completed excavation, or unavailable designation coverage. With no
known enabled intent it cannot invent a suspension. This applies independently
to Wood/logging, Meat/hunting, Food/farming and Stone/mining, including finite
physical excavation. A worker's old Working activity can lag the threshold check.

The explanation shows total and target and preserves manual intent, ground goods
and cargo. Existing goods remain haulable; moving goods to storage does not reduce
total supply. Consumption/construction expenditure below the target makes output
eligible on the next simulation decision without enabling manually disabled work.
A bounded production action can overshoot; targets are not a hard capacity limit.
Removing a policy removes this threshold restriction, not other work prerequisites.

Accumulate using backend-compatible double precision: start with stored stock,
then stacks in durable ID order, then colonist cargo in durable ID order. Already
decoded f32 inputs are promoted to doubles, not rounded to display values or
compared with an invented epsilon/hysteresis. ID-less fixtures use deterministic
amount order (known IDs first when mixed); live rows should always provide IDs.
This supply snapshot is inventory, **not throughput** or net-stock-change rate.

## Physical-world mining integration

Pass the physical-world mode and current public excavation designation rows:

```gdscript
var context = {
    "physical_world": true,
    "excavation_designations": excavation_designations,
}
var entries = Operations.snapshot(tiles, orders, colonists, stacks, resources, policies, context)
```

Live mining uses finite excavation cells (`live_destination` special-cases
`Goal::Work` + Mining), **not** Mine facilities or mining work orders. Mining alone
therefore bypasses those legacy checks. Designations need integer `total_cells`,
integer `completed_cells` in `[0, total_cells]`, and boolean `enabled`. Optional
generated fields `x_0`, `y_0`, `bottom_z` provide an exact corner map anchor.
Legacy dictionary aliases `x0`/`y0` are fallback-only; explicit generated spellings
take precedence, including invalid values that must not produce a focus. Dictionary and generated
row adapters both apply. The caller must wait for the designation subscription;
missing/non-array context data is `unknown`, whereas an explicit empty array is
`missing_designations`.

Mining states for designation intent:

- `missing_designations`: no designated extraction work.
- `designations_paused`: unfinished cells exist, but all unfinished designations
  are disabled (completed designations do not count as paused work).
- `designations_completed`: all designation counters report completion, including
  zero-cell designations. This is completion of designated finite deposits, not
  proof that all world deposits are exhausted.
- `designation_active`: at least one enabled unfinished designation exists.
  This is available **intent**, not proof of a reachable, unprotected work face,
  usable material yield, or current output. Target suspension and worker/needs/working/travel and
  goods/logistics observations retain precedence after active intent is established.

Malformed rows prevent negative designation diagnoses; known positive unfinished
intent can still be reported. Mining `active_orders` is zero in physical mode,
and `active_designations` counts enabled unfinished designations instead. The other
three professions retain their facility/order intent checks. All professions use
the finalized standing-target rule; unfinished physical excavation may therefore
report `target_reached` while `active_designations` remains positive.

Physical mining focus uses the lowest existing tile ID at an exact designation
corner, preferring active, then unfinished, then completed designations. This is
only a map anchor: neither a designation ID nor the server's synthetic work
destination `id=0` is a tile key. With no safely mapped corner, focus remains `-1`
unless ground goods reference an existing tile. Suggested actions direct the player
to **Excavation on the map**, never to create a Mine facility/mining work order.
Stopped extraction does not erase already-made stone or its hauling eligibility.

## Diagnosis and limits

States in precedence order: `missing_facility`, `facility_disabled`,
`orders_paused` / `missing_orders`, `target_reached`, `no_producers`, `needs_precedence`,
`producing`, `travelling`, `no_storage`, `awaiting_haul`, otherwise `unknown`.
Forest logging and hunting are diagnosed separately. Hauler-only roles never
count as producers. Needs precedence requires all observed producers to have a
need activity or need goal; raw need levels cannot prove the server's decision.
Travel is work travel only with a work goal. These observations can lag a
facility/order switch and do not predict the next tick.

Missing or paused orders stop **new production**, not hauling already-made goods.
Ground stacks, cargo, and stored stock are separate inventories. No enabled
storage is a delivery limitation, not proof of a production stop: producer-only
workers can still make goods. Hauling still requires suitable workers and an
enabled reachable destination; this model never asserts reachability. An idle
worker or a needs snapshot does not prove a blocked route. Net stock change is
not throughput and is never calculated here. Suggested actions are inspection
guidance, not commands or a claim that the player can assign professions.

## Headless tests

From repository root:

```sh
godot --headless --path client/godot --editor --import
godot --headless --path client/godot --script tools/colony_operations_model_test.gd
```

Expected marker: `COLONY_OPERATIONS_MODEL_PASS`. Covers switches and absent orders,
shared Forest professions, workers/hauling roles, need-goal travel, cargo/stacks,
unknown rows, object adapters, optional policy targets and row-shuffle stability.
Physical mining tests cover absent/paused/completed/active designation intent,
unknown coverage, generated-row exact-corner/elevation focus mapping, worker observations, legacy compatibility,
haulable stone after extraction stops, and shuffled designation rows.
Target tests cover stock+piles+cargo, manual pause precedence, missing/nonfinite
supply, invalid policies, independent Forest targets, finite Stone suspension,
exact threshold/resume comparisons and backend durable-ID accumulation ordering.
