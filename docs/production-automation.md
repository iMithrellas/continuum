# Standing production targets

## Public contract

- `set_production_policy(resource: ResourceKind, target: f32) -> Result<(), String>`
- `remove_production_policy(resource: ResourceKind) -> Result<(), String>`
- Public table `production_policy`: primary key `resource: ResourceKind`,
  `target: f32`. Resources are Food, Wood, Stone, Meat.
- Targets must be finite, positive and at most 1,000,000 units. Zero is invalid;
  use work-order enablement to disable production explicitly.

Both reducers require Operator membership (Admin inherits it), before validation
or writes. Unknown/non-member callers cannot mutate intent. Repeating a set with
the same target, or removing an absent row, is a successful no-op with no audit
event. Actual changes log the resource, target (for sets), and caller identity.
Writes and audit events share the reducer transaction. Policy writes do not
advance time, including while paused.

## Simulation semantics

An absent row means historical unlimited production. An enabled standing order
may operate only while **stored + ground + carried** supply is below its output's
target. Goods are accumulated in durable stack and colonist ID order. Suspension
never rewrites `work_order.enabled`, priority, or tile enablement. Disabled orders
remain disabled after policy removal or consumption. Logging and hunting use
independent Wood and Meat rows; Food controls farming.

Checks occur at decisions and actions in the existing sequential actor schedule.
A bounded action can overshoot the threshold; this is a standing threshold, not
a hard capacity/reservation limit. There is no hidden hysteresis or pause state.
Consumption or construction expenditure makes production eligible on the next
simulation decision. At zero elapsed time, actors and resources do not advance.

Existing goods remain haulable; suspended facility orders release small leftover
piles without waiting for the normal batch size. Physical mining's Stone target
is wired into `World::mining_job`, shared by navigation decisions and excavation
actions. It suspends enabled excavation designations without changing their
intent or partial progress. Completed atomic cells yield one Stone each;
partial progress does not count as supply. Legacy flat-fixture Mine orders also
obey Stone targets. Physical excavation does **not** require a Mine work order:
its operator intent is the enabled excavation designation, as before. Mining
haulers may collect existing stone at any pile anchor even while suspended.

## Persistence and migration

This is an additive table, not a Config or WorkOrder column migration. Existing
saves get an empty policy table and retain their previous behavior; no backfill
or default target is installed on load. Tick saves deliberately leave policy
rows untouched, just like work-order intent. Colony reset deletes all policy
rows. Regenerate client bindings after deploying the additive schema; subscribe
to the public intent table rather than inferring policy from order enablement.

Dedicated tests cover validation, independent rows, disabled-order precedence,
threshold resume, zero-time pause, pile flushing, physical partial excavation,
stable accumulation and conservation across pile/cargo/storage transfers. The
unchanged historical golden trace runs with no policy rows.

`python3 scripts/internal/test-production-automation.py` (after `just wasm`)
uses a disposable Docker server for real operator/admin and non-member/revoked
authorization, rejected-write atomicity, audit identities, repeated writes,
paused writes, persistence across republish, and reset. Optionally set
`CONTINUUM_BASELINE_WASM` to the previous release artifact to verify additive
upgrade without changing existing save rows. No client bindings are needed.
