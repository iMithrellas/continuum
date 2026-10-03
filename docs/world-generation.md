# Complete server-generated worlds

Fresh production worlds span **2048 × 2048 half-metre cells**. Every initial
column and overview row is authored on the server **before gameplay**, in bounded
scheduled transactions with public progress. Exploration never generates terrain.

Historical pure 24² simulation/128² geometry fixtures remain unchanged. Publishing
this additive module never resets, translates, enlarges or regenerates existing
state. A missing generation row means legacy dense mode; it is ready only when
Config and Colony already exist.

## Locked public contract

`world_generation` singleton:

```
id:u32=0, generation_id:u64, generator_version:u32, storage_version:u32
seed:u64, width:i32, height:i32, min_z:i32, max_z:i32
starter_x:i32, starter_y:i32, phase:GenerationPhase
completed_chunks:u32, total_chunks:u32, completed_units:u64, total_units:u64
ready:bool, error:String
```

Versions are currently1; seed matches WorldSeed. New enum ordinals:
**Preparing=0, Terrain=1, Overview=2, Validating=3, Founding=4, Ready=5, Failed=6**.
Only Ready has ready=true; errors are capped at1024 UTF-8 bytes.

`terrain_column_chunk`, indexed by `(chunk_x,chunk_y)`:

```
id:u64, chunk_x:i32, chunk_y:i32, generation_id:u64, revision:u32
base_z:Vec<i16>, soil_depth:Vec<u8>
soil_fertility:Vec<u8>, forest_density:Vec<u8>, moisture:Vec<u8>
```

All arrays have **1024 elements**, representing32² horizontal columns; index is
`local_x+32*local_y`. ID=`(chunk_y as u64)<<32 | chunk_x as u64`. Revision remains0
for the immutable initial baseline. `base_z` is the first air/feet elevation:
at/beyond it material is air(0); below it through `base_z-soil_depth` soil(1);
below soil through min_z stone(2). Padding outside rectangular bounds has
base_z=-16 and zero other fields and is never a valid coordinate.

Ecological bytes normalize by `/255` and affect actual production. Exposed bedrock
has no fertility/forest support. The protected starter soil guarantees moisture
and fertility>=192/255 and forest density>=160/255; founding Terrain rows contain
those same translated source values, ensuring productive farms/forests.

Existing `terrain_chunk` keeps its full16³ array/ID/revision wire shape, with an
added XYZ index. In compact mode it is a **complete voxel override**, materialized
only on first actual edit from persisted column authority. Explicit air is mined
air, never fallback. A private monotonic allocator provides new override IDs.
Missing source means unknown/corrupt/not-ready, not procedural generation. Missing
legacy voxel chunks retain unknown semantics. No per-world-cell Tile rows exist.

`terrain_overview_chunk`, indexed by `(lod,cut_z,chunk_x,chunk_y)`:

```
id:u64, generation_id:u64, revision:u32, lod:u8, cut_z:i32
chunk_x:i32, chunk_y:i32, surface_z:Vec<i16>, material:Vec<u16>
soil_fertility:Vec<u8>, forest_density:Vec<u8>, moisture:Vec<u8>
```

All arrays have **256 elements**, index `local_x+16*local_y`. LODs are exactly
**3,5,7,9**, stride=`1<<lod`. Representative XY is
`((chunk_x*16+local_x)*stride+stride/2, similarly Y)`. Actual first opaque material
at/below cut supplies surface_z/material. No exposed surface/out-of-bounds is
`surface_z=min_z-1,material=0`, not unknown. These samples are **never picking or
placement geometry**. Packed ID=`(lod<<56)|((cut_z+16)<<48)|(chunk_y<<24)|chunk_x`
using u64 operations; one row per cut -16..15. Missing resident rows are pending.

Voxel edits track exact changed columns. Unsampled columns cause no overview
writes; sampled columns recompute against current compact+override geometry and
increment only changed overview-row revisions, atomically with the edit.

## Lifecycle, centering and limits

Init creates auth, target descriptor/bounds/seed and paused Config, but no Colony,
colonists or operational tiles. Public counters report actually committed work:

1. Preparing removes old terrain in batches (<=64 column,64 overview,64 voxel rows).
2. Terrain stores16 complete32² chunks/transaction, row-major.
3. Overview stores one horizontal overview tile's32 cut rows/transaction.
4. Validating checks64 committed source/overview rows/transaction; source arrays
   must match the deterministic generator and overview/cut/material invariants hold.
5. Founding atomically installs colony/resources/orders/clock and finite fixture,
   then Ready. The starter origin is **(1012,1012)**, midpoint(1024,1024), with
   protected flat/apron XY **1008..1039**. Tile IDs1..576 and colonist IDs1..8 remain
   stable. The fixture remains48 stone blocks at starter-relative22..23,8..11,0..5.

All Operator-authorized gameplay mutations share the readiness guard, including
room construction/free zones. Tick checks before loading; Admin speed control
records intended ready-world speed without enabling early play. Default init
requests ordinary speed; explicit large reset requests paused ready state.

`advance_world_generation(task)` is Scheduler-only: actual sender must be the
database identity. Private control stores generation nonce and expected task ID;
stale/duplicate tasks are no-ops. Successor scheduling and counters commit together.
No global/static state controls correctness; phase/counters survive runtime restart.
Validation errors persist Failed/error. Admin-only `retry_world_generation()`
resumes the same phase/counters and supersedes pending tasks. Runtime traps roll
back a batch and cannot commit a Failed message; a stalled task can be retried.
Unresolved missing sources never become falsely Ready.

Admin-only **`reset_world_large(width:i32,height:i32,seed:u64)` is destructive**:
validate before mutation, clear colony/buildings/intents, and generate a centered
replacement. Bounds are currently **64..8192 per axis**; representation is not tied
to2048, but larger production limits require measured review. Resetting live state
is an explicit parent deployment decision, never an automatic update. No live
reset/deployment was performed in this branch.

Compact expansion is not yet supported. Legacy `expand_world`/`expand_world_varied`
retain <=256 grow-only compatibility and reject compact mode.

## Loading and honest scaling limitations

Geometry's material/contains/solid/clear/supported/can_step/set capability API stays
compatible. Spatial loaders use indexed exact XY coverage aligned to16³ override
chunks, prove all overrides loaded, and never substitute an unloaded edit with
baseline. Outside partial coverage is unknown; partial reducer snapshots never
repair actor hops. Build/room/zone limits remain4096 cells; excavation requests
are capped at262144 target voxels before allocation.

Ticks currently load the **entire compact physical baseline plus all overrides**
to preserve exact goals/simulation semantics. Immutable baseline arrays are Rc
shared across snapshot clones; queries cannot mutate them. This avoids unsafe
coverage truncation, but full compact tick loading and existing whole-colony entity/
intent loads remain **production-scaling limitations**, not bounded-working-set
claims. Navigation and bounded client residency/rendering are separate worker work.

2048² has4096 column rows: **24MiB raw arrays** (12MiB physical+12MiB ecology), versus
256MiB dense voxel material. 8768 overview rows add15712256 raw array bytes (~15MiB).
A9×9 compact viewport has497664 raw array bytes. Rust BSATN serialization checks
6192 bytes per column row and1845 per overview row (501552 bytes for9×9 columns),
excluding protocol framing/compression; these are **not measured wire-frame sizes**.
At8192² column arrays are384MiB
durably while generation batches stay fixed; full tick loading must be optimized
before claiming that production size practical. Clients must subscribe only to
visible compact/override rectangles and chosen overview LOD/cut, never all terrain.

## Verification and measurement

Mandatory: `just test`, `just fmt-check`, `just wasm`; no golden fingerprints changed.
Fresh-world release does not require preservation of existing saves. A live reset
is permitted only by the parent's explicit post-review decision, not by this worker.
`scripts/internal/test-world-generation.py` owns a private installed 2.10 runtime,
checks full arrays/centered IDs/clock/fixture,
auth/early-play guards, rollback, real excavation/overview revisions, room/free
zone placement and restart/retry. Fresh-world proof is now the default; upgrade
comparison of canonical serialized SQL rows runs only when CONTINUUM_BASELINE_WASM
is supplied and is not a release requirement. Evidence stays in ignored target directories.

Optional private **`generation-test-probes` Cargo feature is NEVER for deployment
or bindings**. It injects/repairs a missing source and profiles snapshots/routes.
Supply its artifact via CONTINUUM_GENERATION_PROBE_WASM. Set
CONTINUUM_REQUIRE_FAR_ROUTE=1 to make failed far navigation a blocking gate.

Initial actual compact-WASM observations with navigation04a4350+f690786: full
publish-to-Ready8.49s; active-fixture scheduled tick and real excavation pass;
CLI-inclusive snapshot probes369–408ms; nearby route including load0.99s. Far
corner **exhausted module energy budget (402) after28.5s**. Nearby success is not
a full-map-playability claim. A later run measured5.51s generation,235–242ms
CLI-inclusive snapshot loads,34ms indexed room placement,0.615s nearby route and
another far energy failure after21.94s. Snapshot probe's actual WASM linear-memory
allocation was14286848 bytes (~13.63MiB), not a peak RSS estimate. Private-server
peak RSS (up to~683MiB) includes three
databases/Wasmtime/storage/compilation caches and failed far search; it is NOT
module linear-memory usage. Final integration report carries later measurements.

With navigation dependency **f7d71df**, the strict real-terrain far gate passes:
publish-to-Ready5.50s, snapshot probes235–240ms, indexed room placement33.75ms,
nearby route0.417s and far corner0.435s (all RPC measurements include CLI/load).
Successful route probes measured14614528/14680064 bytes of actual WASM linear
memory (far=14MiB). Native opt-level=z pure generation of the full physical2048
snapshot took631–637ms across five repeats, excluding persistence/network.
The previous energy failures remain useful regression evidence; remote disconnected
or heavily edited worst cases can still reach exact fallback CPU limits. These are
shared-host observations, not universal fuel/time guarantees. Final strict evidence:
`backend/spacetimedb/target/world-generation-evidence-a8njxqy4/evidence.json`.

The final fresh-only rerun (baseline=null) also passes all strict gates: generation
5.82 s; snapshot RPCs 248–254 ms; room placement 32.15 ms; nearby/far routes
0.443/0.458 s. Evidence:
`backend/spacetimedb/target/world-generation-evidence-ome1i1jl/evidence.json`.
Final mandatory checks passed 204 unit tests plus 5 gameplay tests, formatting,
and production WASM compilation. No live reset or deployment was performed.
