# Native population profile (not a deployment limit)

`examples/population_profile.rs` isolates actor population from map expansion.
It does not change simulation behavior or golden fixtures. Cargo discovers the
example automatically; no manifest registration is needed.

## Repeat it

From the repository root:

```sh
cargo run --release --manifest-path backend/spacetimedb/Cargo.toml --example population_profile -- 3 12,48,128,256 12 120
rustfmt --edition 2021 --check backend/spacetimedb/examples/population_profile.rs
cargo check --manifest-path backend/spacetimedb/Cargo.toml --example population_profile
cargo test --manifest-path backend/spacetimedb/Cargo.toml --example population_profile
cargo test --manifest-path backend/spacetimedb/Cargo.toml --lib
```

All arguments are optional: repeats (default 3), comma-separated populations
(12,48,128,256), warmup intervals (12), measured intervals (120). Each interval
is **60 in-game seconds**, one current bounded simulation interval. Safety bounds
are 1–10 repeats, up to eight populations of 12–256 each, 1–60 warmup intervals,
and 30–240 measured intervals. These are benchmark guardrails, **not supported
population limits**. A custom short/long-warmup trajectory that fails to exercise
production, delivery, and needs is rejected by workload assertions.

## Fixed workload and timing scope

- Every population/policy/repeat starts fresh at 08:00 with the same flat live
  **24×24×32-cell geometry**, eight material chunks, 576 operational rows, 78
  production orders, and 78 full ground piles. Cells are 0.5 metres per edge.
  This is the historical starter footprint with live navigation, **not** the
  current seeded 128×128 hillside. Use `geometry_profile` for map scaling.
- Durable actor IDs are 1 through N. The eight-founder work/position roster is
  repeated; needs are deterministically staggered to exercise eating, sleeping,
  recreation, production, and hauling concurrently. Initial stored food is
  50 resource units per actor; other stored resources begin at zero.
- Both `SelfHaul` and `DedicatedHaulers` run, with normal meals and default
  tuning (including 1.4 metres per in-game second walking). All facilities,
  orders, and initial piles are unchanged as population increases. Facilities
  have no occupancy cap. Farming/logging/hunting can produce; flat live geometry
  has no excavation designations, so assigned miners only haul seeded stone or
  serve needs/idle. This is not a finite-excavation scaling measurement.
- Each repeat warms for 12 game minutes, then measures a continuous two-game-hour
  trajectory. Only `sim::step` wall time, including event construction, is timed.
  Setup, geometry construction, validation, checksum computation, event dropping,
  database load/reconciliation/persistence, and networking are excluded. Derived
  navigation remains warm between calls, unlike a fresh database transaction.
- p50/p95 are nearest-rank percentiles of all measured step times pooled across
  repeats (360 samples per population/policy by default), in **milliseconds per
  60-game-second step**. These are not confidence intervals or reducer latencies.
  Sampled actor-intervals count each actor's post-step activity, not precise
  time spent active. Navigation counters include warmup.

## Original bounded native baseline (pre-integration)

Measured 2026-10-03 on Linux x86_64, AMD Ryzen AI 9 465, rustc 1.98.1
(`48a229cea`, LLVM 22.1.8), module release profile `opt-level=z`, LTO,
one codegen unit. The command above was used; no CPU pinning, thermal control,
or otherwise isolated host was imposed. Treat values as observations, not a
performance guarantee.

This historical baseline used profiler commit `f93d640`, integrated as
`d14f89a`, before the intent proposal pipeline. Retain it as a before/after
reference, not as the current integrated module's performance.

| Actors | Self-haul p50 ms | Self-haul p95 ms | Dedicated p50 ms | Dedicated p95 ms |
| ---: | ---: | ---: | ---: | ---: |
| 12 | 0.710 | 0.805 | 0.584 | 0.679 |
| 48 | 3.418 | 3.650 | 2.496 | 2.653 |
| 128 | 10.158 | 10.731 | 7.698 | 8.162 |
| 256 | 21.079 | 22.140 | 16.118 | 17.223 |

The population sweep shows increasing native cost with fixed initial geometry.
Dedicated p95 is about 16–27% lower here, **not at equivalent production**:
dedicated roles reduce producer count and increase idle time. For 256 actors,
self-haul had 15,373 working and 5,433 idle actor-intervals; dedicated had 8,468
working and 12,452 idle. Both had measured haul, eat, sleep, and recreation activity.
Policy choice changes the work actually executed; it is not just an implementation
optimization.

### Workload evidence

Every measured step checks unique/sequential durable IDs, actor scalar finiteness
and nonnegativity, positions inside the footprint, stored/ground-resource
validity, and legacy sorted stack IDs. Each repeat must show measured work,
haul, and needs service, non-food total growth, and non-food storage growth.
Non-food totals include **storage + ground piles + carried cargo**, and may not
decrease beyond 0.01 units over the measured window. An additional test disables
production and verifies wood/stone/meat conservation on every haul step under
both policies. Food has consumption and is not asserted conserved.

The following evidence is from the first repeat; final checksums matched all
three fresh repeats. Production is net wood/stone/meat total growth; delivered
is their storage growth, **including transfers of the initial full piles**.
Delivery can exceed production because this is a transient stocked workload,
not a steady-state throughput test.

| Actors | Policy | Produced units | Delivered units | Final checksum |
| ---: | --- | ---: | ---: | --- |
| 12 | SelfHaul | 33.200 | 990.000 | `891602d96dc8d9aa` |
| 12 | DedicatedHaulers | 23.267 | 680.000 | `47c6755bd4b823ec` |
| 48 | SelfHaul | 154.800 | 729.867 | `270ac98c829b40a9` |
| 48 | DedicatedHaulers | 89.000 | 840.000 | `0ff50b0536300922` |
| 128 | SelfHaul | 426.367 | 875.000 | `851112b3d8d1a23d` |
| 128 | DedicatedHaulers | 233.767 | 715.000 | `d511445f570daf61` |
| 256 | SelfHaul | 867.200 | 1290.000 | `64ee5b165c4b0f04` |
| 256 | DedicatedHaulers | 471.200 | 955.000 | `143fd98d4f5a3ecb` |

Checksums use FNV-1a over version-local debug-formatted state, including all
actor components sorted by ID, stacks, resources, policies, clock, colony stats,
orders, and tiles. Immutable fixed geometry and derived navigation cache are
excluded. They detect repeated-run state drift, not a cryptographic guarantee
or a stable cross-platform replay format. A test also reverses actor storage
order and compares events and final state. The three example tests and all 148
library tests passed at the original baseline, including the original golden
trace without regeneration.

## Post-integration follow-up at `d61f2ef`

Measured again on 2026-10-03 on the same host/toolchain/release profile, after
rebasing onto integrated `d61f2ef` and skipping the already-cherry-picked profiler
commit. This includes the intent proposal/ordered validation pipeline
(`a5772f2`), ecological production support, and production-policy integration
(`0c87315`, `d61f2ef`). **Only this document was changed for the follow-up**;
the profiler, workload, timing scope, and simulation were not modified.

Commands, in execution order (default A, threaded B, default C):

```sh
cargo run --release --manifest-path backend/spacetimedb/Cargo.toml --example population_profile -- 3 12,48,128,256 12 120
cargo run --release --manifest-path backend/spacetimedb/Cargo.toml --example population_profile --features native-parallel-intents -- 3 12,48,128,256 12 120
cargo run --release --manifest-path backend/spacetimedb/Cargo.toml --example population_profile -- 3 12,48,128,256 12 120
```

Runs were sequential, not concurrent. Each entry below is **p50 / p95 in
milliseconds per 60-game-second step**, with 360 measured steps per entry per
run. Compilation time is excluded. The second default run checks run-order
variability; it is not pooled with the first or presented as a confidence bound.
No CPU pinning, thermal control, or isolated host was imposed.

| Actors | Haul policy | Default A p50 / p95 ms | Threaded B p50 / p95 ms | Default C p50 / p95 ms |
| ---: | --- | ---: | ---: | ---: |
| 12 | SelfHaul | 1.392 / 1.735 | 1.432 / 1.621 | 1.222 / 1.361 |
| 12 | DedicatedHaulers | 1.147 / 1.433 | 1.175 / 1.337 | 1.002 / 1.133 |
| 48 | SelfHaul | 7.099 / 7.867 | 6.403 / 6.685 | 5.969 / 6.187 |
| 48 | DedicatedHaulers | 5.270 / 5.866 | 4.822 / 5.137 | 4.468 / 4.660 |
| 128 | SelfHaul | 21.369 / 22.604 | 19.245 / 19.917 | 18.318 / 18.796 |
| 128 | DedicatedHaulers | 16.496 / 17.418 | 14.848 / 15.496 | 14.208 / 14.623 |
| 256 | SelfHaul | 40.405 / 45.166 | 39.322 / 40.658 | 38.047 / 39.185 |
| 256 | DedicatedHaulers | 30.879 / 39.113 | 30.542 / 31.829 | 29.791 / 30.891 |

### Overhead, not a speedup claim

Even the faster default C has p50 costs **1.72–1.85× the original baseline**
across these populations/policies; default A was approximately twice baseline.
The new pipeline gathers owned decision snapshots and later re-queries them
at each actor's ordered commit turn. Navigation searches reflect additional
query work: for 256 self-haul actors, cumulative searches rose from 29,991 in
the original run to 59,691 in all follow-up runs, while routes remained 2,075
and graph builds remained one. These counters support increased query work,
but the before/after timings do **not** isolate intent costs from the other
integration changes or host variation. This was not a component-ablation study.

The threaded feature parallelizes only tiny pure goal decisions. Query gathering,
conflict validation, ordered actions, and shared-resource mutation remain serial.
At measurement time, `std::thread::available_parallelism()` reported 20; the
executor caps its configured workers at eight. Its chunking creates six scoped
threads for 12 actors and eight for 48, 128, and 256. These threads are spawned
and joined **every bounded interval**, not once at process startup; warmup does
not remove that recurring cost. Thread startup/join and scheduling are included
in the step timings, but were not separately instrumented or quantified.

Threaded B p50 was **2.5–17.3% higher than default C**, with the largest relative
penalty at 12 actors. It was not dramatically slower on this host. Some threaded
timings were lower than default A, but default C was lower still for every p50
and p95. That ordering is a warning about host/run-order variability, **not
evidence of a parallel speedup**. There is no controlled attribution of the
observed differences exclusively to thread startup. **Keep
`native-parallel-intents` off by default** for this workload: the runs establish
no reliable throughput benefit to offset its recurring worker overhead.

### Follow-up workload validation and coverage limits

All three follow-up runs completed the profiler's state/workload assertions at
all populations and both policies. All checksums, produced/delivered quantities,
activity counts, event counts, and route counts matched the original evidence
above; fresh repeats matched within each run and default/threaded results
matched across runs. The navigation search counters changed as described above.
No golden fixtures were changed. This measurement-only follow-up did not rerun
the separate example or library test suites; the test counts above belong to
the original baseline verification.

The unchanged `sim::new_world()` fixture has **empty ecological data and empty
production policies**. Missing ecological data gives neutral yield; no stock
targets are configured. Thus these timings execute the integrated paths but do
not benchmark populated ecology lookups, stock-target pauses/resumes, or policy
scaling. The original fingerprint also omits these new world fields; identical
checksums validate the older covered state, not a full-world equivalence proof
for newly integrated fields. No profiler code was extended in this follow-up.

As before, these are **native, warm-cache simulation-only measurements, not
WASM fuel/memory or server limits**. WASM uses the serial executor even when
the native feature is enabled. Neither the slower integrated default nor the
optional-thread results establish a practical maximum population.

## Final once-gather schedule

The double-gather integration results above are historical, **not the current
default cost**. Commit `8cad244` restores one ordered gather per actor. Native
speculation copies component inputs without querying World/navigation; current
labour is resolved at the actor's ordered validation turn.

Independent review at `5ad9fc0` repeated the profiler with two repeats, 12 warmup
intervals and 120 measured intervals per repeat. Self-haul p50 milliseconds per
60-game-second interval were:

| Actors | Default | Native feature |
| ---: | ---: | ---: |
| 12 | 0.709 | 0.886 |
| 48 | 3.399 | 3.732 |
| 128 | 10.207 | 10.889 |

The default is back near the original baseline; optional threads remain slower
for these samples and stay off by default. Checksums, workload results, events
and navigation counters matched. An independent cache-stress comparison against
the original per-actor schedule also matched its 304 graph builds and 320
searches. The final schedule and experiment limits are described in
[simulation architecture](../../docs/simulation-architecture.md).

## What remains unmeasured

Native CPU timing alone cannot establish WASM instruction/fuel limits, linear
memory high-water marks, SpacetimeDB transaction limits, or server population
capacity. This run collects neither WASM fuel nor process/memory profiles. It
does not measure persistence, fresh per-transaction cache rebuilds, client row
updates, larger maps, inaccessible geometry, mining, long-term shortages,
occupancy contention, or many simultaneous colonies. Large elapsed durations
invoke multiple bounded intervals and cannot be budgeted from p95 times by a
simple linear guarantee.

Before claiming a deployment budget, run the same explicit population/policy
fixtures through the actual WASM reducer/runtime, include load/save and event
persistence, record fuel and memory plus end-to-end tail latency, and test the
real map and time-scale workload. **256 actors is merely the largest bounded
sample here, not a practical maximum or a promised supported size.**
