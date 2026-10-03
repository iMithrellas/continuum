# Connected planning acceptance gate

Run from a candidate checkout; pass its actual WASM and client directory:

```sh
python3 scripts/internal/test-planning-connected.py \
  --wasm /absolute/candidate/continuum_module.wasm \
  --client /absolute/candidate/client/godot \
  --evidence /tmp/opencode/planning-final-unique-evidence
```

`--cli`, `--runtime`, and `--godot` override executable locations. The default
native server is the installed SpacetimeDB 2.10.0 runtime. No Docker is used.
The overall deadline defaults to 900 seconds; every subprocess and UI checkpoint
also has a bounded deadline. Evidence must be a new directory.

## Real path under test

The runner owns a random loopback port (never 3001), random database, publishing
identity, private native data directory, and private HOME/XDG paths. It publishes
only the passed WASM, awaits `world_starter_origin`/public Ready (initialized legacy
is supported), pauses simulation, queries starter data, and runs the unchanged
`scenes/main.tscn`. The test driver is a separate SceneTree, not a Main subclass.

The client is copied into the private directory. Bindings are regenerated from
that server's actual schema using the production generator, after removing ONLY
the disposable copy's old generated directory. This is important: editor import
can create obsolete `OwnRole` from the checked-in plugin cache, and that obsolete
class collides with the actual Membership decoder. No source checkout, production
binding, user token or existing endpoint is rewritten.

Planning Controls are revealed through the real workspace and clicked through
Godot input. Map gestures use viewport input events and the real map hit-testing
and signals. Camera APIs only move/zoom the actual map; they do not supply terrain.
No dispatch stubs, synthetic reducer results, cache injection, permission overrides,
`map_intent_override`, or `planning_rows_override` are used. Viewer wire checks
call the real generated reducers over the actual normal client's connection.

Authoritative publisher-authenticated SQL checks establish the normal identity's
membership and verify room footprints/costs, canonical typed R2, free overlapping
Storage, independent removal, reverse creation order, busy double gesture,
server overlap rejection, exact Viewer role rejection, restoration and disconnected
mutation denial. Selection IDs come from actual rows, never XY/width arithmetic.
Both room and Storage inspection texts must come from the actual Main panels.

After **each** successful creation the gate checks isolation: room-only creation
must preserve every Tile row, create exactly one full-metadata room and its R2
property, and change only colony wood by 20. Zone-only creation must create four
exact Storage rows, preserve outside usage/anchor IDs, and leave colony/building/
thermal tables unchanged. Both creation orders and both independent removals use
these exact delta assertions. A settled request without an Accepted outcome is
not considered a successful operation.

Legacy founding has **0 stored wood**: the runner lets real scheduled workers
supply at least 40 wood, then pauses and records the opening stored balance.
No resources are minted. Both 20-wood rooms must fit within that same recorded
opening balance; there is no resupply between the tested creations.

## Evidence and limits

`result.json`, redacted client/server logs, and the private generated schema are
retained. Private tokens/homes are not copied. The runner terminates/reaps its own
process groups, verifies its listener is released, and verifies its private
directory is removed. Script errors make an otherwise successful UI run fail.

Teardown always runs **before** bindings/log archival. Every cleanup/reporting
failure is isolated and recorded as a secret-free stage/type; it cannot replace
the original scenario failure or skip another resource's disposal. Terminate/reap
has kill/retry fallbacks, and private directory cleanup has an exact owned-path
fallback. A result-write error produces best-effort `failure-result.json`; stdout
still contains the final resource proof if all evidence writes fail. Any
finalization error makes the gate fail, even when resource disposal succeeds.

Run the deterministic real-runtime teardown regression suite separately:

```sh
python3 scripts/internal/test-planning-connected-faults.py \
  --wasm /absolute/candidate/continuum_module.wasm \
  --evidence /tmp/opencode/planning-faults-unique-evidence
```

Its six cases cover the original missing client layout, forced bindings archival,
result writing, first group termination, permanently failing TemporaryDirectory
cleanup, and combined archive/log/both-result-writer failures. The original
preparation error must survive every case. A separate bounded supervisor records
exact launched PIDs/start times/private paths, examines every owned process
session (including descendants), independently probes listener release and home
removal, and never turns emergency recovery into a pass. Faults are restricted to
reporting/cleanup/preparation; no fake UI, SQL or wire scenario substitutes for the
positive connected gate. The supervisor also disposes its current child/resource
sessions if externally interrupted.

The legacy gate passed on base `5c23f27` plus dependency `964e1d3` (locally
cherry-picked as `4e8b7cb`). The thermal field/header fixes are dependencies, not
test-owned production changes. Before final approval rerun against the final
generation + streaming client + final WASM. Large-world performance and 2048
subscription behavior are **not** established by a legacy pass.
The release target is a **fresh 2048 world**; no old-save migration gate is
required. Fresh-world restart durability remains a separate final acceptance
requirement, along with complete generation and physical subscription coverage.

Current legacy Main retains `map.has_world_snapshot() == true` after disconnect,
but clears readiness/Operator authority and blocks changes; the evidence records
this separately. This gate claims disconnected mutation denial, not cache disposal
or detached-node lifecycle coverage. It uses headless engine input, not OS-level
mouse automation or screenshot visual approval.
