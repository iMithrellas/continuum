# Playing the current slice

This guide follows the loop **observe → food delivered → needs → terrain-aware
orders → stock targets → return**. It describes implemented prototype behavior,
not a guarantee that a colony is safe unattended.

The default clock is deliberately slow: four real hours per game day. For a short
development playtest, an authorized admin can change speed in F9; that changes
the shared simulation for everyone, not just the local client's animation.

## Roles and controls

- Joining authenticated players default to **Operator**. An admin can explicitly
  assign read-only **Viewer** with `set_operator(identity, false)`; this persists
  across reconnects. Restoring `true` restores Operator, not Admin.
- **Viewer:** can read replicated colony state, select colonists, inspect the map,
  see destination markers/work badges, and use reversible Overview guidance.
- **Operator:** has viewer access plus the `Operations` and `Policies` panels and
  may change facilities, work orders, hauling/meal policy, production targets,
  excavation intent, and acknowledge alerts.
- **Admin:** inherits operator permissions and additionally controls simulation
  speed, reset, world expansion, and membership. Local Developer/Admin profiles
  are not server roles; server authorization is decisive.

Use the **Panels** menu to open `Overview`/`Operations`, `People`, `Policies`,
`Inspector`, and `Trends`. Map tools select, build, excavate, and configure
facilities/orders; the map's right inspector shows selected tile details and
terrain potential. Overview suggestions are navigation/inspection guidance. They
are reversible, never issue reducers, and are not a safety system or a promise of
recovery.

| Task | Required server role | Where |
| --- | --- | --- |
| Inspect public state, select actors, use Overview suggestions | Viewer or higher | Map, `Overview`, `People`, `Inspector`, `Trends` |
| Build/enable facilities, edit work orders, designate/pause excavation | Operator or Admin | Map tools and `Operations` |
| Set/remove production targets | Operator or Admin | `Overview` → expand `Stabilization` → `Production targets` |
| Change meal/haul policies | Operator or Admin | `Policies` |
| Change time scale, reset/expand world, manage members | Admin only | F9 admin panel / server administration controls |

The F10 Developer panel is local diagnostics/debug UI, not an authorization
route. A normal client profile is a viewer until an existing server admin grants
operator membership.

## Observe → food delivered

Start with Overview and People. Check stored colony food, active farm orders,
storage, and colonist needs/activity. Food is usable only after a worker produces
it onto a ground pile, someone carries it, and cargo is delivered into stored
resources. Follow `item_stack`, `colonist` cargo/activity, then the colony stock
readout; production alone is not food available to eat. With no enabled storage,
goods can remain piled or carried and eating cannot use those goods.

If a production order or tile has been manually paused, an automation target does
not re-enable it. Only an operator/admin can change a facility or order. Changes
are server-authoritative and displayed after replication; do not assume an
unconfirmed button press committed.

## Needs → terrain-aware orders

People shows per-colonist hunger, fatigue, recreation, mood, activity, work/haul
role, cargo, and current goal. Select an actor to inspect their current
destination. The map marks a visible selected-actor destination and shows work
badges to distinguish activity from assignment. These are current replicated
intent/position, not proof that the actor can reach every target or that a job
will finish.

Terrain potential labels describe estimated yield relative to baseline at the
selected operational tile: farming uses persisted fertility and moisture;
logging and hunting use persisted forest density. Inspect different sites, then
use an operator's work-order controls to enable compatible farming, logging, or
hunting. Mining is physical and finite: designate excavation on the map; do not
create a Mine facility/order to start live extraction. Completed excavated cells
yield stone once, and paused designations retain their progress.

Overview's expanded Stabilization section gives advisory reasons for observed production/logistics
state, including physical mining. It may be unknown or stale while subscriptions
are warming or when inputs cannot prove a diagnosis. It is not an authoritative
server job-reason feed, and it does not compute throughput from net stock change.
Use it to navigate to relevant tiles/panels and inspect the replicated state.

## Stock targets → return

An operator/admin can open **Overview → Stabilization → Production targets** and set a target per
resource (Food, Wood, Stone, Meat), or choose **Unlimited** to remove it. Targets
count **stored + ground + carried** goods. Reaching the target suspends eligible
production, including physical mining, without rewriting work-order or excavation
pause state. Once stock falls below the target, eligible work can resume.

A target is a standing threshold, **not a hard stock cap**: an already-running
bounded action may overshoot it. It does not guarantee reserves, prevent
consumption/construction, assign a worker, enable a paused order, or ensure
reachable delivery/storage. Logging (Wood) and hunting (Meat) have independent
targets; absent targets preserve unlimited production. Operator/admin changes
are persisted by the server; existing worlds receive no default target on
upgrade.

Use Trends and the replicated stores/needs to check the result after returning.
Session snapshots and alerts can help orient a returning player, but the current
slice has not been validated through sustained week-long multiplayer play.

## Verification and rollout

The pure connected gameplay scenarios are run with `just test-gameplay-core`;
backend-free client, generated-binding and cache regressions are grouped in
`just test-gameplay-client`; test-runner failure paths use `just test-gate-safety`;
real disposable-server reducer authorization/persistence for targets is covered
by `just test-production-automation`; the existing private server lifecycle and
unattended production regression is `just test-connected-colony`. These gates
cover different contracts and are not a substitute for release-target or sustained
multiplayer testing. [Integration evidence](gameplay-slice-verification.md#integrated-client-and-server-checks)
records the separate live Godot smoke check. `just profile-population` measures native simulation only;
it is not a server capacity or supported-population claim.

Deploy matching backend and client/generated bindings together. The new
`production_policy` table is additive and preserves old saves with no targets;
normal publish with regenerated bindings is the intended schema migration. Do
not publish the backend against an incompatible client build, recommend fresh
publishes to erase state, or use destructive reset as a routine upgrade. Managed
installed-module automatic upgrade/backup flow is not implemented: changed
installed module digests currently require explicit future upgrade handling.
