# Connected gameplay-slice verification

`backend/spacetimedb/tests/gameplay_slice.rs` exercises the public pure
simulation, not a mock loop or a new golden projection. It deliberately leaves
the historical contracts/fingerprints unchanged. See
[Simulation Composition](simulation-architecture.md) for scheduling contracts.

## Fixture and boundaries

The fixture has four farmers with staggered needs, two farms, storage, dining,
sleep and recreation. Sparse operational rows sit on an 8×8 physical material
world (`geometry: Some(...)`), with solid support, body clearance and live BFS
navigation. It is physically flat but **does not use** the historical
`geometry: None` Manhattan-travel path. Durable actor/tile IDs differ from vector
and spatial order. Default movement, needs and wellbeing tuning remain active in
the unattended scenario; food output alone is set to six units/hour to make
finite reserves deplete in a bounded test. The isolated logistics scenarios
disable accrual and production so conservation has a directly measurable oracle.

The cross-feature scenarios additionally fix productivity at 100% and disable
need accrual to isolate ecological output and target accounting. Ecological
fields are explicitly supplied by durable tile ID, not procedurally generated
inside the tests. Food consumption still uses the real eating activity. Mining
uses actual material cells, designation priorities and partial excavation work.

The tests are deterministic, have no wall-clock sleeps, random seeds, network,
database, server process or client dependency. Simulation steps are internally
bounded to 60 in-game seconds. The baseline three-test target ran in roughly half a
second locally after compilation; this is an observation, not a performance SLA.

## Exact scenarios

### Delivery and an interrupted cargo trip

`food_requires_delivery_and_storage_loss_preserves_carried_goods`:

- A hungry actor cannot consume a 30-unit farm pile while storage is disabled;
  hunger is unchanged, no Eating transition occurs, and no goods disappear.
- Enabling storage allows a real pickup, but pickup alone does not populate the
  larder. Storage is disabled again while the carrier holds all 30 units.
- Cargo survives ten simulated minutes of that interruption. Re-enabling storage
  permits movement, delivery and then actual hunger recovery through eating.
- Every recovery minute checks `stored + piled + carried` against measured hunger
  removal × food cost; final balance and supported actor positions are checked.
- Idle actors with no labour fallback need not emit `MealMissed`: denial events
  are transition-based. The test uses state/consumption evidence instead of
  assuming one denial event per tick.

### Observe → stabilize → fail → recover unattended

`observe_stabilize_fail_and_recover_with_operator_policy_and_orders`:

1. Run 24 in-game hours with dedicated haulers and normal meals. Require hauling,
   positive stored food and healthy mood.
2. Disable storage and recreation for 24 hours. Production still leaves piles;
   delivery cannot feed the colony. Disable all farming orders, then advance
   another 144 hours without intervention. Require missed meals, denied
   recreation, near-max hunger/recreation need and a substantial mood decline.
3. Clone the failed state as an untreated control. In the intervention branch,
   restore storage/recreation, switch to self-hauling and rationed meals, and
   enable only farm 17's priority-one order. Advance **both** branches another
   96 in-game hours without further edits.
4. Require real eating/recreation transitions, new production rather than merely
   spending leftovers, usable food reserves, recovered needs and smoothed mood,
   and better productivity than the untreated branch. At hourly observations,
   working actors must be at the selected farm; disabled farm 91's leftovers
   cannot increase and must eventually be delivered. Check exact elapsed time,
   supported positions, finite bounded needs, cargo and nonnegative stock.

The recovery is a combined operator intervention. This scenario does **not**
claim that rationing or self-hauling alone causes recovery, or quantify policy
superiority. The restored food/recreation loop is the tested causal contrast.
The intervention branch covers 288 hours; the untreated continuation adds 96
hours of simulation work. Thresholds assert outcomes, not golden float values.

### Durable-ID arbitration under contention

`durable_ids_resolve_contended_food_and_piles_independent_of_row_arrival` runs
under both hauling policies:

- Four hungry actors contend for just 0.2 stored food. Only actor 7, the lowest
  durable ID, gets hunger recovery on that first interval.
- Four satisfied farmers then contend for two equidistant finite piles (31 and
  29 units). Farm 17 beats farm 91 by durable ID. The first pickup belongs to
  actor 7 under self-hauling and actor 19 under dedicated hauling (ID-ranked
  staffing makes actor 7 a producer).
- Four row-arrival permutations run alongside the reference over mixed
  15/45/60/120/30/90/3600-second calls. Events and **full authoritative World
  state**, canonicalized by durable ID, must match after every call.
- Goods are conserved through contention and eventually all 60 units reach
  storage, with no leftover piles or cargo.

`World.stacks` requires ascending IDs for binary searches. The row-arrival helper
reverses incoming stacks and normalizes them before stepping, as a load boundary
must; it does not claim arbitrary unsorted internal stack vectors are supported.
This models the boundary contract but does not execute persistence code. Derived
navigation caches are excluded from authority comparisons; geometry, components,
orders, piles, policies, resources, clock and smoothed statistics are compared.
The cross-feature additions also reverse production-policy and designation
arrival order and compare ecology, excavation materials/progress and dirty sets.

### Ecological yield → target hold → delivery → consumption/resumption

`ecological_piles_target_hold_delivery_and_consumption_preserve_manual_intent`:

- Two farmers with equal productivity and output rates work different sites for
  one minute with storage disabled. Explicit fertility/moisture extremes produce
  **0.5 and 1.5 actual ground food units**, while stored food stays at two units.
  An existing one-unit cargo brings total supply to the five-unit food target.
- Ten further minutes hold production at exactly five units. All manually enabled
  work orders remain enabled and otherwise unchanged; the target is derived
  permission, not a rewritten operator intent.
- Enable storage. The existing cargo is deposited and both sub-stack-size piles
  are picked up despite the target hold. Every checked step conserves the
  five-unit supply across stock/piles/cargo, and hauling finishes in storage.
- Disable both orders manually and let a hungry actor eat the stored food using
  the real schedule. Below-target supply allows production again, but no disabled
  work resumes or is auto-enabled. Actual consumption drains the larder.
- Re-enable only poor farm 91 at priority three. Rich farm 17 remains manually
  disabled at priority one; a farmer placed at that richer site must redirect to
  farm 91. Only farm 91 produces, restoring the target and usable stored food.
- Then explicitly re-enable rich farm 17 and spend 0.5 food units at the pure
  boundary. Both enabled workers must redirect from nearby farm 91 to priority-one
  farm 17. One travel-only interval isolates destination ranking. In the next
  production interval actor 7 makes 1.5 units, overshooting the target to six;
  actor 19 must resolve its current labour to Haul and pick up that batch instead
  of producing a second one. Native proposals make no labour query before ordered
  validation. Delivery finishes without rewriting orders.
- Four persistent actor/tile/order/policy arrival permutations match complete
  authority and event order after **every** step, through all these interventions.

The final 0.5-unit expenditure is an explicit pure-world boundary edit, not a
construction reducer or validated expense. The earlier food reduction is actual
simulated eating. One bounded production action's target overshoot is intentional.

### Prioritized excavation: partial target hold, expenditure and manual resume

`prioritized_physical_excavation_holds_partial_progress_then_resumes_after_expenditure`:

- Two miners contend on supported physical geometry with two stone cells.
  Equally adjacent designation 73 at priority one beats designation 5 at priority
  three, despite its larger ID and reversed row arrivals. Both miners perform real partial work:
  the first cell reaches 0.5 progress, the second stays at zero, and no resource
  is counted before a cell is actually removed.
- Explicitly supply one stored stone unit at the pure boundary, meeting its
  target; advance ten minutes. Partial progress and solid material are retained,
  and neither designation's enablement is changed by the hold.
- Spend that unit at the pure boundary. Both miners resume partial work through
  the schedule; exactly one completed cell becomes AIR and yields one ground
  stone unit. The second designation remains held at zero progress.
- Restore storage and finish pickup/delivery while held. Actor 7 wins the
  contended pickup; total stone supply remains one throughout transport.
- Manually disable the remaining designation and spend the delivered stone.
  Below-target supply does not resume that disabled job. Explicit re-enablement
  permits completion and delivery of exactly one more cell, with no duplicate
  output, leftover piles or cargo.
- Two actor/tile/designation arrival permutations match events and full authority
  after every step, including dynamically allocated pile anchors and material
  changes. This extends the existing single-miner direct-action unit test with
  real scheduling, competing workers, priority arbitration and transport.

Both cross-feature timelines are bounded by minute/ten-minute calls and fixed
iteration counts. No server-time waits or unattended multi-day extensions are
needed to prove these target holds.

## Commands and recorded results

From the repository/worktree root:

```sh
cargo test --manifest-path backend/spacetimedb/Cargo.toml --test gameplay_slice
cargo test --manifest-path backend/spacetimedb/Cargo.toml --features native-parallel-intents --test gameplay_slice
just test
just fmt-check
just wasm
```

Baseline result on 2026-10-03: the targeted three scenarios pass (0.49 seconds);
`just test` passes all 148 existing unit tests plus these three integration tests
(the new target took 0.48 seconds in that run); `just fmt-check` passes; `just wasm`
compiles the release artifact successfully. These are separate gates; none
publishes a module or validates a live server. Rerun and record actual results
when integrating additional branches.

Follow-up result on 2026-10-03, rebased onto integrated `d61f2ef`: all **five**
scenarios pass in the default target (0.86 seconds) and with
`native-parallel-intents` (2.49 seconds); `just fmt-check` passes. The feature run
uses the actual native goal-proposal executor, with the same outcome assertions
and per-step row-permutation state/event equality. These separate builds are not
a saved cross-build trace comparison and are not a parallel-performance claim.
The full suite and WASM build above describe the historical baseline; they were
not rerun for this test/documentation-only follow-up.

## Integration extensions still needed

Keep `physical_colony`, row permutation/canonicalization, conservation and
`unattended_checked` and mirrored-step helpers composable as coverage grows:

- **Ecology:** generated/persisted field loading and client mirroring remain
  outside these tests. Current ecology is suitability-based yield, not finite
  site capacity, depletion or regeneration; those would require new budgets and
  failure/recovery assertions if introduced.
- **Production targets:** the actual stateless threshold rules now execute in
  these tests. Reducer validation, durable policy loading and operator UI
  submission remain separate gates; the tests install/edit pure-world intent.
- **Intent pipeline:** owned speculative goal proposals and ordered revalidation
  now execute here, including the native-feature variant. Submit real operator
  intents through reducers separately, and check acknowledgement and
  authorization/rejection behavior, then run their resulting state through this
  recovery oracle. Current edits bypass reducer authorization, transaction
  validation and client acknowledgements.
- Extend permutations to every new durable row collection, including actual
  load/save normalization and newly authoritative state. Preserve ID arbitration
  and event equality; do not silently sort unsupported state to hide a bug.
- Add physical route disruption/repair, height changes and actual construction
  expenditure where those features connect to the slice. Current coverage
  includes two finite exposed stone cells and excavation-created route changes,
  but not tunnels, vertical excavation or construction reducers.

## Real multiplayer/server validation is separate

These are backend **pure simulation regression tests**, not evidence of a live
gameplay session. They do not test SpacetimeDB scheduling/persistence, concurrent
transactions, disconnect/reconnect, subscriptions, access control, operator
permissions, Godot UI intent submission, diagnostics visibility or multi-client
replication. “Connected” here means the production → pile → cargo → storage →
consumption → needs/wellbeing gameplay systems share actual simulation state.

A release gate must additionally publish matching schema/bindings to a private
server, use at least two real clients with appropriate roles, submit the same
interventions through authorized intents, observe acknowledgement and replication,
leave server time running while clients are absent, and reconnect to verify
durable outcomes. Use existing private integration tooling where applicable;
record server/client versions, commands, logs and observations. Do not label this
document or a passing WASM build as that validation.
