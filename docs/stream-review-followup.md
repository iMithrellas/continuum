# STREAM review follow-up (S1–S6)

## Final ordinary-world follow-up (2026-10-03)

Combined candidate: own `836e003` (optional exact ecology), `884763f`
(disconnect/timer/retired transport safety plus strict detail axis chooser),
`84a1099` (local exposure invalidation, no-op snapshots, bounded progressive
detail, lower ordinary Fit budget and real runtime measurements).
Art dependency `eaeb746db291d473f480369dea2406c0f51902af` is integrated as
`edee16e`; parent already has it at `c81c67a`, so **skip this dependency**.
Earlier dependency/commit inventory below remains historical.

### Actual private production runtime evidence

`client/godot/build/stream-live/1791060513768371420/` contains fresh, restart,
disconnect-loading and runtime logs. Uses parent's read-only production WASM,
actual Main/generated SDK, private Xvfb/llvmpipe and owned random loopback runtime.

| Ordinary action | Fresh | Runtime restart |
| --- | --- | --- |
| Nearby playable readiness | 4.399s | 1.214s |
| Far detail jump: 32 sources, 27,360 exact cells | 7.298s | 7.473s |
| Detail frame submissions / ray queries | 8 / 30,583 | 8 / 30,781 |
| Fit: LOD5, 16 rows, 4,096 representative samples | 1.860s | 3.187s |
| Fit frame submissions | 4 | 5 |

Both settled detail and Fit have **zero pending samples**. Fresh/restart each
pass20 assertions; actual loading Disconnect passes2 assertions, including waiting
16 seconds through the freed bootstrap timer deadline. No closed-WebSocket,
freed-object or polygon triangulation diagnostics occur in this final run.
These are software-GL measurements, not hardware performance or visual approval.

Physical exposure invalidation now touches only the changed32x32 source or16x16
edit footprint. Repeated completeness/source/edit no-ops preserve caches;
unrelated selection provenance remains valid. Missing acknowledged compact source
coverage emits pending without re-querying unknown rays on every progressive frame.
Full cut/material/geometry changes still clear exposure. Detail growth batches8;
camera/cut/completion, material changes and existing coverage changes/loss bypass
growth batching. Source/overview packed arrays are detached before installation.

Normal overview target is16,384 samples with the existing65,536 hard ceiling;
2048 Fit chooses existing authored LOD5. Ceiling tests explicitly opt into65,536.
No schema/backend LOD or client physical generation changes. The physical stream
also chooses overview if either detail axis exceeds256, even with small area;
300x32 and32x300 tests cover this, while256x256 remains valid detail.

### Final regression gates

- `timeout 240 just test-ui`: all31 pass; `stream-final-ui.log`.
- `timeout 240 just test-gameplay-client`: pass; `stream-final-gameplay.log`.
- Targeted: foundations39, Main/wire56, normalized validation51, actual SDK
  cache14, local exposure/ecology/chooser13; ceiling burst256 remains one frame.
- Production schema-cache and strict world-bindings/high-bit u64 gates pass.
  Standalone `world_bindings_wire_test.gd` was invoked without its required owned
  endpoint arguments and stopped at its explicit-endpoint assertion (bounded
  timeout); it is not counted as a pass. Actual wire coverage here is the private
  Main fresh/restart gate above, not that standalone invocation.
- Private GPU: legacy34, world-art2086, art-review164, ecology-art869,
  Main/wire56, local13, composed occlusion, depth and map-client rendering pass.
  Logs are `client/godot/build/stream-final-*.log`.
- Optional ecology is forwarded only for finite normalized exact/representative
  surface values; resolved-empty/pending samples invent no metadata. Art retains
  strict validation and owns bounded exact tooltip fallback/tiny hatch rendering.

This supersedes the historical remaining polygon diagnostic below. No shared
desktop changes, parent/backend edits, production reset, push or visual sign-off.

Worktree: `/tmp/opencode/continuum-world/map-client`, branch
`feature/large-map-client-followup`. No shared backend, desktop, live reset,
parent source edits, schema generation or production deployment.

## Own commits (in order; parent already has the earlier 08d3412/7aee8e9)

| Commit | Scope |
| --- | --- |
| `db72917` | S2: bootstrap timeout/end terminal for that subscription; late applied/Ready cannot revive input/readiness |
| `d1a790c` | S6: separate subscribe/unsubscribe phase clocks |
| `635b65c` | S3: retained retired handles, shared outstanding/releasing budgets across replacements, latest intent only |
| `fb38d44` | S4: strict normalized metadata/arrays/ranges/materials/cut/bounds, monotonic resident revisions, atomic rejection |
| `a31cbee` | S5: deleted/rejected overview refresh becomes pending; retain resident revision high-water |
| `234828a` | One deferred authored frame per synchronous acknowledgement burst |
| `18da86c` | S1 integration gate: production stream/adapter plus actual SDK cache and serialized dropped-row flag |
| `75939c9` | S2: cold retry remains usable; ended subscription cannot Resume |
| `5a842e3` | Generated typed DB/table/row fixtures; no duplicate DB fields; real menu bootstrap plus dense acknowledgement |
| `d8ed551` | S4: rectangular source padding must be min_z/zero |
| `86ca4d1` | Reconcile changed coordinates only; progressive Fit growth batches32 (camera/cut/final completeness immediate) |
| `4b22820` | Actual Main/generated SDK/private production runtime and restart gate |
| `1f312f1` | Existing overview updates/loss bypass growth batching; immediate physical selection revocation; terminal callback disposal |
| `121c3c9` | S4: installed edit bytes are detached from mutable typed rows |

### Dependencies — do not duplicate in parent

- Art `27dd6ed4f17cc194368cb077970cf1fa45def55b`, local `9a42b60`.
- SDK cache `194185143b9423dc965c2e3e95228b7790896c5d`, local `a2d9f5a`.
- Production bindings `e941d55988cc307c32b7c5bc816b188520537272`, local `2eee0cf`.
- SDK u64 `2616e10`, local `caf8632`.

No renderer validation or SDK/generated implementation edits were made by this
worker. Normalized adversarial tests use a separate wrapper; actual Main uses
subclasses of the generated typed tables, without shadowing production DB fields.
Consumed normalized coordinate/generation/revision/array fields are mandatory;
durable row IDs are not used to authorize physical geometry.

## Validation

- `timeout 240 just test-ui`: **all31 checks pass**, including import, Main/menu,
  Viewer Settings/Resume, composition, export-import, export-pack and packed widgets.
  Log: `client/godot/build/stream-followup-ui.log`.
- `timeout 240 just test-gameplay-client`: **pass**, no hung/unloadable scene.
  Log: `client/godot/build/stream-followup-gameplay.log`.
- Typed/normalized targeted gates: foundations39, Main/wire55, strict validation49,
  terrain SDK cache13, production schema cache and strict world bindings (including
  full high-bit u64 seed). SDK subscription-cache wire/overlap/bounded-pan gate passes.
- Private-Xvfb software-GL gates pass: Main/wire55, legacy34, world-art2086,
  art-review164, composed occlusion, depth rendering, map-client rendering.
- 256-row synchronous burst: **one frame**, about2.36s including fixture typed-row
  construction at every table iteration (the original normalized fixture measured
  about0.44s). One changed row reconciles one coordinate. Losing previously drawn
  coverage during partial growth forces **one immediate pending frame**,256 pending
  samples; growth batching does not preserve stale representatives.
- Independent physical probe38 and bounds probe19 pass. Compact GPU17 passes at
  both1280x720 and1920x1080. Typed fixture Fit ack phases measured about2.45s/2.37s,
  versus the reviewed164–167s; these are not hardware/server performance benchmarks.

### Independent probe reproduction notes

The complete review was read and probes copied only into this tree's ignored
`client/godot/build/review-stream-28df909/`. Original stream source is preserved as
`stream_probe_original.gd`. Three fixture corrections were needed after fixes:

1. Restore a valid newer source after the deliberate source rollback test, before
   edit-only tests. Otherwise atomic rejection correctly rejects every later edit.
2. The SDK fixture's overriding `unsubscribe()` default must match the new
   SendDroppedRows API; the old override hard-codes0 and bypasses the SDK fix.
3. Its server ack must include the reported dropped edit. The SDK deliberately
   does not infer/delete ownership from an empty Default-style ack. The bounds
   probe's late-unsubscribe assertion was correspondingly changed from flag0 to1.

With those protocol/setup corrections, stream42 passes; no product assertion was
removed. The unchanged lifecycle15 probe passes the fresh compact S2 checks, but
still reports its single out-of-release-scope D2 legacy recreation diagnostic.

## Actual private fresh/restart core gate and remaining visual diagnostic

Run with the read-only production WASM supplied by parent:

```sh
PATH=/tmp/opencode/ux-panels-evidence/usr/bin:$PATH \
CONTINUUM_STREAM_WASM=/tmp/opencode/continuum-slice/integration/backend/spacetimedb/target/wasm32-unknown-unknown/release/continuum_module.wasm \
  python3 scripts/internal/test-large-map-live.py
```

Runtime/data/JWT/CLI/Godot home/logs are exclusively owned under
`client/godot/build/stream-live/<run>/`, random loopback port, never3001. Runtime
is terminated/waited in finally. No production test-probe artifact or generated
binding workaround is involved.

**17 core assertions pass fresh and17 after private runtime restart**: generated
2048 Ready/center/Membership, operational ecology, nearby exact snapshot and apron,
actual Fit representative subscriptions, SDK residency, rapid cut pending budget,
overview entity suppression and return to exact detail. Fresh observed phases:
Connecting, Validating world, Founding colony, Loading nearby terrain, Ready.
Restart observed Connecting, Loading nearby terrain, Ready. The parent owns the
full earliest-phase generation/planning visual gate; no screenshot approval or
hardware performance claim is inferred here.

Latest evidence: `client/godot/build/stream-live/1791057994978900769/{fresh,restart}.log`.
Both runs report seven **artist-owned excavation hatch triangulation errors** at
`scripts/map_paint.gd:91` via `colony_map.gd:1425` in actual full-world Fit drawing.
The core gate is explicitly labeled `PRIVATE_STREAM_LIVE_CORE_PASS`, not clean
runtime/GPU approval. Artist/parent should resolve this diagnostic before release;
their draw functions were not edited or their fixtures weakened.
