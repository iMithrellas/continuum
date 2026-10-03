# Sparse navigation prerequisite

Navigation no longer scans world bounds, decodes all material chunks, builds
global components, or allocates `width * height * z` lookup/clearance arrays.
Each body graph starts empty. Ordered BFS lazily caches outgoing edges by
supported `Cell`; each actor stores only discovered cells, canonical parents,
first hops, and its resumable FIFO. It finishes expanding a node before pausing,
so query order cannot change cardinal (`+x,+y,-x,-y`) or ascending-dz ties.
Saved alternate shortest hops use the same graph and an exact temporary BFS.

The existing body/actor cache count limits, durable actor keys, route reuse,
and terrain epoch invalidation remain. Every actual voxel write discards the
navigation snapshot and all derived caches on the next query. Existing handles
remain immutable snapshots, not views of newly changed terrain. Actor scheduling,
intent execution, persistence, and public database schema are untouched.

## Geometry integration seam

`navigation/terrain.rs` delegates support and sweep checks to
`Geometry::supported` and `Geometry::can_step`; these in turn preserve material,
contains, clearance, footprint, cave, and arbitrary step semantics. Navigation
does not read `Geometry::chunks` or infer air from missing chunks. Generation's
compact authored columns/deltas can therefore replace chunk storage without
changing this navigation implementation, provided query semantics and
`nav_epoch` invalidation remain intact.

**Loading contract:** load the full compact physical source (authored 32-square
column chunks) and all authoritative dense voxel overrides before constructing
the Geometry queried by navigation. A generated-but-unloaded column is not an
unknown legacy missing chunk. The existing `Option<material>`/boolean APIs
cannot distinguish those cases; this implementation must not be paired with a
spatially cropped loader. Partial loading requires an explicit coverage and
Pending/retry contract above these queries, rather than reporting an unloaded
route as unreachable. The current full-source recommendation trades roughly
12 MiB of compact physical source plus decode/metadata for correct queries; it
does not authorize simulation-wide Pending state changes.

One `Rc<Geometry>` is cloned lazily per navigation epoch and shared across all
bodies and actors (including body-cache eviction/rebuild); no per-actor full
geometry clone is performed. **This clone still costs the size of Geometry's
stored data**, including job metadata. Compact/COW geometry storage or a cheap
immutable material-only snapshot is necessary if that cost is too high after
generation merges. No new Geometry method or schema is required here.

## Exact low-memory oversized-query fallback

The follow-up bounds a normal actor search at 4096 discoveries (plus the final
node's at-most-252 neighbors for the current 32-z-band world), and body adjacency
caches at 1024 expanded nodes. Cache eviction changes work, never results.
On crossing the actor budget, FIFO capacity is freed and the bounded canonical
prefix is frozen for repeated local queries. Uncached targets use a disposable
exact packed BFS; at most 128 target distance/first-hop/unreachable answers are
retained per actor. There is no search
radius, truncation, or reachable-as-unreachable approximation.

`navigation/packed.rs` allocates parent-code pages **on discovery**, keyed by
32x32 XY chunk and individual z plane. Air/solid/unqueried planes do not get
pages. A byte records unvisited/root or the exact parent cardinal/dz direction
when the clamped step is at most 31; wider steps use u32 codes. No per-visited-cell
B-tree node, distance array, first-hop array or cached adjacency is created.
The FIFO frontier uses u32 addresses in 1024-entry blocks freed as consumed:
it retains only the live wave-ordered frontier, not every previously queued node
or two rounded-up high-water wave allocations. Distance and first hop are traced
through parents without constructing a full route. Route queries construct only
the returned route; routes longer than 4096 cells are not retained in actor caches.

Every fallback starts at the same source and uses the exact canonical cardinal
and dz order. A target's first discovery therefore gives the same parent, distance,
first hop and route as the original BFS, regardless of preceding query order.
Alternate saved-hop searches use this same fallback when oversized. The packed
search never adds edges to the shared graph and its pages are freed after each
query, so 32 actors cannot retain 32 copies of global search state.

## Optional bounded canonical IDA* accelerator

Before allocating packed BFS pages (after the existing small reverse-component
check), `navigation/ida.rs` tries IDA* in canonical `+x,+y,-x,-y`, ascending-dz
order. It uses an **explicit iterative stack**, not recursive DFS, and only
path-cycle pruning: there is no global visited/transposition map and no heuristic
queue-tie substitution. The heuristic is
`max(ManhattanXY, ceil(abs(target_z-current_z)/clamped_step))`; with step zero
only the XY term is used. All actual edges still use authoritative support/sweep
queries, so footprints, caves, directed steps and unknowns retain their semantics.

### Canonical route proof (unit-cost navigation, not weighted travel length)

1. A legal edge changes XY Manhattan distance by at most one and z by at most
   the clamped step. Both heuristic terms, and their maximum, are admissible and
   consistent even when edges are directed or terrain blocks possible routes.
2. Ordered FIFO BFS first discovers a target through the lexicographically first
   shortest edge sequence. Every prefix of a shortest route is itself shortest;
   BFS's visited pruning therefore cannot discard a lexicographically earlier
   shortest target route in favor of a later one.
3. IDA* starts at `h(start)`. It advances a threshold only after fully exhausting
   that threshold, to the minimum exceeded `g+h` among valid non-cycle edges.
   While below optimal distance, the first cut along any optimal route has
   `g+h <= optimal`; the next threshold therefore cannot skip above optimal.
4. At the first successful threshold, all optimal paths remain eligible by
   admissibility, and no shorter path exists. Canonical DFS traverses eligible
   paths in lexicographic order, so its first goal is exactly BFS's canonical
   shortest route, including parents and first hop. A shortest route has no cycle;
   path-cycle pruning cannot remove it. This argument does not require undirected
   edges or equal physical/Euclidean movement lengths.
5. Budget limits do not make the search appear exhausted: every uncertain exit
   returns **fallback**, never unreachable. Packed BFS remains the authoritative
   exact fallback and saved alternate hops are still validated by exact distance.

The default cap is **65,536 work units total across thresholds**, counting BOTH
entered nodes and every candidate probe (including rejected/out-of-bounds edges),
**8192 path cells**, and **16 threshold iterations**. Scratch storage is bounded
by path length, independent of map area: stack frames plus a path-membership
B-tree, with no graph adjacency caching or global node map. The accelerator adds
at most this bounded work before the existing fallback; large mazes/footprints
or steps may hit a cap. Actual geometry-query cost per probe is not constant for
arbitrary bodies. No reducer-time guarantee or real compact-source/WASM speed
claim follows from the synthetic fixture timings.

Before a large forward search, an at-most-1024-position reverse flood can prove
a small isolated target unreachable. It follows **incoming** valid steps, so its
proof does not assume symmetric edges. Exhausting it without finding source
proves no route exists; hitting its budget is merely inconclusive and invokes
full exact forward BFS. This accelerates islands without misclassifying large
components. Unknown legacy targets still reject immediately. Authored compact
columns must still be fully loaded under the contract above.

## Remaining scaling risks and accepted scope

Performance/memory fixtures cover 2048x2048, 32 z bands, and the ordinary walking
body. When packed BFS is needed, open four-million-position land uses 4 MiB of parent payload, rather than
millions of tree records; a half-map separated component uses 2 MiB. Multi-level
caves can touch more z-plane pages; parent payload is at most 128 MiB within these
bounds, plus page-map metadata. Frontier and returned-route memory depend on
actual frontier/path size, not logical volume. No universal memory/runtime claim
is made for pathological mazes, arbitrarily small/tall bodies, extreme job metadata,
or larger worlds. Packed addresses require a positive voxel-address space fitting
u32 (including all current 2048/32 bounds). Beyond representable bounds the original
sparse exact search remains available; that is not a larger-world scaling guarantee.

Unaccelerated far/unreachable queries may still traverse millions of cells, repeatedly
if queried repeatedly, and can exceed a reducer CPU budget. The reverse accelerator
does not reject two large disconnected components cheaply. A targeted shortest
search based only on heuristic queue ties is not justified by canonical
BFS-parent parity. The bounded IDA* optimization instead has the proof above;
future accelerators must preserve that contract. Geometry writes can repeat snapshot/search work;
large footprints/step ranges multiply per-node authoritative geometry-query cost.
Actual compact-source WASM query/tick timing remains a generation-integration gate,
not something proven by synthetic navigation fixtures. No Pending-state changes
or Geometry/schema API changes are introduced.

## Verification and reproducible local-work profile

Run the full existing gates (golden fingerprints are not regenerated):

```sh
just test
just fmt-check
just wasm
cargo test --manifest-path backend/spacetimedb/Cargo.toml --features native-parallel-intents
cargo test --release --manifest-path backend/spacetimedb/Cargo.toml nearby_work_and_storage -- --nocapture
cargo test --release --manifest-path backend/spacetimedb/Cargo.toml packed_2048 -- --nocapture --test-threads=1
```

The profile/test uses identical two-chunk 16-square authored regions translated
to centered colonies in logical 128, 256 and 2048 worlds. It never generates the
full large world. A five-hop nearby route prints expanded/discovered cells,
FIFO allocation capacity, cached edge records, stored hops and hop capacity,
plus snapshot chunk count. All work/storage counters must be identical at all
three sizes. These are allocation-driving record/capacity counters, not a global
allocator byte measurement (B-tree overhead and allocator metadata are excluded).
Timing is observational, not a threshold or WASM budget claim.

Observed native release profile (opt-level=z, shared host):

| Logical edge | Nearby query + route µs | Expanded | Discovered | FIFO capacity | Edge records | Hops / capacity | Snapshot chunks |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 128 | 194 | 27 | 45 | 64 | 27 | 108 / 108 | 2 |
| 256 | 139 | 27 | 45 | 64 | 27 | 108 / 108 | 2 |
| 2048 | 130 | 27 | 45 | 64 | 27 | 108 / 108 | 2 |

Packed-memory follow-up native release stress profile **before IDA***
(2048 square, 32 z bands):

| Scenario | ms | Forward expanded | Discovered | Parent pages / payload | Peak FIFO payload | Reverse visited |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Opposite corners, distance 4094 | 5034 | 4,194,302 | 4,194,304 | 4096 / 4 MiB | 12 KiB | 1024 |
| Two large separated components | 2344 | 2,097,152 | 2,097,152 | 2048 / 2 MiB | 12 KiB | 1024 |
| Isolated 16-square target island | <1 | 0 | 0 | 0 / 0 | 0 | 256 |

The test process's observed peak RSS over all three scenarios was **10,024 KiB**,
measured by spawning the final release test executable directly with Python
`os.posix_spawn` and collecting `os.wait4(...).ru_maxrss` (no compiler included).
RSS includes the test harness/process launch overhead; payload counters omit
B-tree/allocator metadata and the bounded reverse flood. The generated-column
physical query fixture is synthetic and immutable, with no full-world voxel
initialization; its footprint/clearance/step/path behavior is cross-checked
against real material Geometry on smaller worlds. This isolates navigation
memory and does **not** measure full compact-source load/decode/clone overhead
or real source-query WASM performance. Timings under concurrent build/test load
were higher (7.1 seconds for the same open-map query), so no reducer budget is claimed.

### Bounded IDA* CPU follow-up evidence

Same synthetic native release fixture, with the optional accelerator enabled:

| Scenario | ms | IDA entered nodes / units | Thresholds | Peak path / stack allocation | Packed expanded / parent payload |
| --- | ---: | ---: | ---: | ---: | ---: |
| Flat opposite corners, distance 4094 | 3 | 4095 / 18,424 | 1 | 4095 / 64 KiB | 0 / 0 |
| Terraced opposite corners, final z=12 | 3 | 4095 / 18,436 | 1 | 4095 / 64 KiB | 0 / 0 |
| Large separated components, capped IDA | 2636 | 6703 / 65,536 | 1 | 3032 / 64 KiB | 2,097,152 / 2 MiB |
| Small isolated target, reverse proof | <1 | 0 / 0 | 0 | 0 / 0 | 0 / 0 |

Stack allocation excludes the bounded path-membership B-tree and returned route.
The reverse flood visits at most 1024 positions in the first three cases and
256 in the island case. The process's measured peak RSS across all four cases
was 10,220 KiB using the same direct-executable `posix_spawn`/`wait4` procedure.
Under concurrent full test/build load, the separated-component fallback took
5491 ms; the flat/terraced accelerated cases remained 3 ms. These are synthetic
query timings, not real compact-source loading or WASM measurements. Flat and
terraced fixture semantics are checked against real material Geometry on smaller
worlds; no full-volume source fixture is initialized at 2048.

New oracle tests exhaust **512** 3x3 floor masks over every source/target pair
and **256** directed 2x2 edge sets over every source/target pair. Differential
cave tests cover multi-cell bodies, tall clearance, large steps, explicitly
directed vertical edges and unknown legacy chunks. Every returned full route is
compared to an independent complete canonical BFS and to disabled-accelerator
packed BFS. Separate detour tests exercise fully exhausted increasing thresholds
and forced work/path/iteration caps; caps always fall through to the same exact
route, never a false-unreachable result. Existing query-order, saved-alternate
hop, invalidation, intent parity and golden tests remain unchanged in expectations.

CPU follow-up gates passed: `just test` and full `native-parallel-intents` each
passed **185 unit + 5 gameplay integration tests**, including unchanged golden
traces and native worker/cache parity. `just fmt-check` and `just wasm` passed.
The same per-worker on-disk build-cache environment was used; no live/backend
deployment or generated schema changes were made.

An additional fully authored logical-2048 near-colony fixture, rather than just
two known legacy chunks, verifies the same 27 expansions, 45 discoveries,
64-entry local FIFO capacity and 27 cached edge records, with no packed pages.
Forced fallback queries match complete oracle routes/distances/first hops across
multi-cell bodies, caves, steps and unknown chunks, including wide parent codes;
transition/query-order tests preserve legitimate alternate shortest saved hops.

Follow-up `just test` and full `native-parallel-intents` runs each passed 180 unit
tests and 5 gameplay integration tests, including unchanged goldens and native
worker-count/cache-work parity; `just fmt-check` and `just wasm` passed. Builds used
`CARGO_TARGET_DIR=/home/mithrel/.cache/opencode-continuum-build-cache/navigation`,
`CARGO_INCREMENTAL=0`, four build jobs, and zero debug info for debug tests.

The first commit's `just test` and full `native-parallel-intents` run each passed 174 unit
tests and 5 gameplay integration tests, including the original golden trace
and native worker-count/cache-work parity; `just fmt-check` and `just wasm` also passed. The
initial default builds hit shared `/tmp` disk quota before module compilation;
successful runs used isolated `CARGO_TARGET_DIR` paths in `/dev/shm`,
`TMPDIR=/dev/shm`, `CARGO_INCREMENTAL=0`, four build jobs, and (for debug tests)
`CARGO_PROFILE_DEV_DEBUG=0 CARGO_PROFILE_TEST_DEBUG=0`.

Tests also compare exact distances/first hops to `Geometry::reachable`, complete
canonical paths to an independent ordered path oracle, supported positions and
steps across bodies and unknown chunks, query-order parity, saved alternate
hops, immutable snapshot sharing/invalidation, and exact exhaustion of a local
256-position component for a disconnected supported target in a 2048 world.
