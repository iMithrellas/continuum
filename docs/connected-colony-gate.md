# Isolated connected-colony gate

Run from the checkout whose backend should be tested:

```sh
scripts/internal/test-connected-colony
```

The gate builds **this checkout's** locked release WASM, publishes it, and exercises
the real SpacetimeDB 2.10.0 CLI/server protocol. It is not a Godot presentation or
WebSocket subscription test. Fresh short-lived CLI connections provide authenticated
reducer calls and authoritative SQL; every CLI process exits before the next step.

## Prerequisites and isolation

- Linux (`/proc` listener ownership verification), Python 3, Cargo with the
  `wasm32-unknown-unknown` target, and build dependencies.
- Native `spacetimedb-cli` and `spacetimedb-standalone` 2.10.0 at the usual Continuum
  cache location; alternatively set **both** `SPACETIME_CLI` and
  `SPACETIME_RUNTIME` to executable paths.
- Without native tools, an accessible Docker daemon and the already cached image
  `clockworklabs/spacetime@sha256:3e3645a3ada6f77a64343fb062a06df4b5185816e145c8f1b57eaa9f2a37eb25`.
  A uniquely owned, never-started container supplies the two binaries via `docker
  cp`, then is removed. No pull, shared container, or Docker server port is used.

The server listens only on a randomly selected loopback port. Its data, signing
keys, three identities, CLI settings and database name are exclusively owned by
this invocation. No existing server, database, credentials or game settings are
read or changed. Before sending requests, `/proc` verifies the loopback listener
socket belongs to the owned server PID. Port allocation has the usual release/bind
race; a collision fails startup rather than attaching to a shared server.

Build timeout defaults to 300 seconds (`--build-timeout SECONDS`). CLI calls have
30-second limits; readiness and gameplay waits have explicit deadlines. Interrupt
and termination handlers run bounded cleanup. Only the owned server process group,
container ID and private directory are cleaned. Docker removal and its independent
absence check each have a 15-second timeout. A failed removal, uncertain absence,
or runtime/directory disposal failure records `cleanup_failed`, exits nonzero and
never emits either pass marker. Independent cleanup still runs; private state is
retained if runtime exit cannot be verified. SIGKILL cannot be handled.

## Assertions

1. Create three local authenticated identities. Publish as administrator; reject
   viewer speed, policy and work-order writes with the exact server authorization
   reason `caller is not an authorized colony member`. The operator's admin-only
   speed rejection must say `this command requires a colony admin`. Generic
   transport/parser errors or mentions of "admin" do not satisfy these assertions.
   Compare the named public-table snapshot while paused to detect mutation.
2. Grant the separate operator identity. Reject its administrator-only speed write;
   accept operator hauling, rationed-meal, zone and persistent work-order intents.
3. Resume with storage disabled. Make **no requests or client connections for four
   wall seconds**, reconnect, pause, and verify scheduled game time advanced by at
   least 1,200 seconds and the exact order rows survived.
4. Observe actual produced wood on the ground with no cargo while storage is
   disabled. Disable forest production, enable storage, observe carried wood at a
   slower sampling speed, then observe stored wood increasing. Check conservation
   across ground, cargo and stored wood with production disabled; ticks must not
   rewrite orders.
5. Install a nonempty Meat production-policy intent, pause, capture the **16 named
   public tables** below, stop the owned runtime, restart against the same private
   durable data, and compare every captured row. After reconnect, require operator
   work-order and production-policy no-op writes plus an admin speed no-op. These
   reducers authorize before returning unchanged, proving membership survived;
   public SQL reads alone cannot prove that. Require the viewer's specific
   authorization failure again and compare the snapshot after all no-ops.

Restart snapshot scope (90-second total budget, at most 30 seconds per SQL call):
`config`, `world_seed`, `speed_control`, `colony`, `tile`, `terrain`, `colonist`,
`item_stack`, `world_geometry`, `terrain_chunk`, `terrain_material`,
`excavation_designation`, `work_order`, `production_policy`, `alert`, `event_log`.
This is an explicit scope, not a promise to snapshot every future public table.
Sender-scoped `my_role` and private membership/excavation-jobs/tick-schedule rows are
not directly compared. Membership is exercised through authorization; scheduling
is exercised through disconnected gameplay before restart. This is not a
production-target suspension/resume or ecology-multiplier correctness gate.

The resource gate follows aggregate wood, not an individually tagged item: stacks
merge, and the current protocol has no item-instance provenance. It nevertheless
requires actual ground, carrier and stored states, not just elapsed time or a log
message. A missed carry state, rejected setup, stalled tick or missing prerequisite
is a failure, never a skipped/fake pass.

## Evidence and extending the gate

The first output gives `CONNECTED_GATE_EVIDENCE=/tmp/opencode/continuum-connected-gate-*`.
Each run retains `build.log`, `server.log`, `evidence.jsonl`, and on successful
gameplay completion `paused-snapshot.json`. Bearer tokens are redacted from command
diagnostics, output, evidence and visible exception chains, including login timeout
and spawn failures. Sensitive raw argv never appear in retained error messages.
Private database files, signing keys, CLI settings and extracted tools are removed
on ordinary failures; cleanup failures retain the exact owned handle/path for safe
retry rather than claiming disposal. `cleanup_pass` requires verified disposal;
`CONNECTED_COLONY_PASS` follows it and requires gameplay/restart success too.
A failure exits nonzero and records the sanitized assertion/command blocker.

Offline safety/oracle tests (no Docker, network or server):

```sh
python3 scripts/internal/connected-colony-fault-tests.py
```

These mock login timeouts/spawn errors/token-bearing output and failed/timed-out
container removals, retained containers, daemon failures and incomplete private
directory disposal. They assert token-free visible tracebacks/evidence, bounded
subprocess disposal, no false pass markers, and exact semantic auth classification.

New ecology/automation checks should be separate methods on `Gate`, called after
`baseline()` and before the final pass marker. Reuse `call`, `rows`, `wait`, and
`record`; pause for setup, use an explicit operator, capture rejected-write state,
and enforce a bounded gameplay deadline. Do not silently probe-and-skip missing
APIs: new methods should require their intended schema/reducer revision. Keep this
baseline independent of in-flight backend APIs and never change golden fixtures to
make it pass.

## Baseline execution evidence

### Hardened follow-up on `257d06c`

Both genuine current-backend runs passed:
`/tmp/opencode/continuum-connected-gate-kpuihj8q/` and final-source
`/tmp/opencode/continuum-connected-gate-86n9ko0w/`. Built WASM SHA-256:
`4d94ac8d82d156bcfbef7fa188490e5da57297b193c4512435a0b18db56592cc`.
Each advanced 28,800 → 31,200 without a client, preserved 78 orders, conserved
3.7964885 Wood through ground/cargo/storage, compared the 16-table restart snapshot
(including nonempty Meat target 12345), and executed authorized operator/admin
no-ops after restart. `cleanup_pass` preceded the final overall pass.

17 offline fault tests passed; the explicit nonexistent-tool test exited 1 with no
overall pass and verified private-state disposal. Captured logs and independent
cleanup checks are at `/tmp/opencode/continuum-connected-followup-4z_b3e62/`:
`fault-tests.log`, `negative-prerequisite.log`, `verification.json`, and exact-ID
container-absence logs. The latest negative gate's own evidence is
`/tmp/opencode/continuum-connected-gate-v0mkokim/`. All four native runtime PIDs were
absent, both extraction containers were independently absent, private directories
were gone, and retained genuine-run files contained no JWT-like tokens. The
existing interactive QA server and its external artifacts were not touched.

Commands used:

```sh
python3 scripts/internal/connected-colony-fault-tests.py
scripts/internal/test-connected-colony --build-timeout 600
env SPACETIME_CLI=/tmp/opencode/nonexistent-followup-cli SPACETIME_RUNTIME=/tmp/opencode/nonexistent-followup-runtime scripts/internal/test-connected-colony
```

### Historical pre-review runs

The original runs below are historical gameplay evidence only: the reviewer found
exception-redaction, cleanup-oracle and restart-scope defects in that version. They
do not validate the hardened follow-up's safety assertions.

Executed twice successfully against the baseline checkout `e826e6f`, using the
cached pinned Docker image's native binaries. Both runs advanced the clock from
28,800 to 31,200 with no client during the four-second interval, preserved 78
orders, and observed/conserved 3.8763337 wood through all three logistics states.
The final-source run's evidence is at
`/tmp/opencode/continuum-connected-gate-kpdgqni9/`; the preceding run is at
`/tmp/opencode/continuum-connected-gate-t49r7re4/`. Both include graceful server
shutdown, successful durable restart comparison, and `cleanup_pass`.

An intentionally nonexistent explicit tool pair produced a nonzero prerequisite
failure (not a pass/skip) and `cleanup_pass`; its evidence is at
`/tmp/opencode/continuum-connected-gate-c38b4b9g/`. These paths are local evidence,
not prerequisites for future runs.
