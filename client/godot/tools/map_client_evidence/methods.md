# Map client performance evidence

Baseline: reviewed `1d636d4`; changes are confined to `perf/map-client`.
Godot 4.7.2 (debug), Linux. No server connection/reducer calls, desktop input,
production process termination, SDK/generated-binding/RTT/art changes.

## Repeatable runs

```sh
godot --headless --editor --path client/godot --import
python client/godot/tools/map_client_checks.py --gpu --profile
```

The GPU runner uses an **isolated Xvfb**, not the user's display. Install Xvfb
or unpack its binary into `client/godot/build/map-client/usr/bin/Xvfb`.
The recorded driver is Mesa llvmpipe OpenGL compatibility (software GL), not
a measurement of the user's physical GPU. All commands ran in the foreground.
Ordinary runs retain new output under ignored `build/map-client/`, without
overwriting the recorded comparison logs. Add `--record-evidence` explicitly
when intentionally replacing the tracked evidence after reviewing the results.

`map_client_profile.tscn` generates real binding rows for a 24/128 square map,
two terrain depths, eight workers, 32 vertical layers, and a 1280x720 viewport.
It times synchronous work in milliseconds: one initial refresh, five full
unchanged refreshes, descriptor/visibility queries, 10x1000 field lookups,
180 idle process calls, and 180 moving calls (10 on 128, since the original
implementation took ~1.6 seconds per call). GL runs then capture 180 frames.
Baseline measurements were saved **before** production script edits. The
after-only ordinary-tick measurement passes table invalidations, matching Main.
Full `refresh()` deliberately remains a force-resnapshot API for callers/tests.

UI-only comparison uses the same optimized/cached map on both sides, isolating
Main rather than counting the terrain fix twice:

```sh
git show ee363169d6a196930f25396fb93a394f70c44b7d:client/godot/scripts/main.gd > client/godot/build/map-client/main-before.gd
godot --headless --path client/godot --scene res://tools/map_client_ui_profile.tscn -- --main-script=res://build/map-client/main-before.gd --settings-file=res://build/map-client/ui-profile-before.cfg --workspace-file=res://build/map-client/ui-profile-before.json
godot --headless --path client/godot --scene res://tools/map_client_ui_profile.tscn -- --settings-file=res://build/map-client/ui-profile-after.cfg --workspace-file=res://build/map-client/ui-profile-after.json
```

UI timings exclude deferred node deletion (cleanup occurs between samples).
`created_nodes` counts newly instantiated People/Alerts/Excavation subtrees by
instance identity, not Godot's frame-delayed object-count monitor.

## Results (mean milliseconds, saved logs)

| Work | Before | After |
|---|---:|---:|
| 24 initial map refresh | 94.538 | 5.270 |
| 24 moving process | 64.620 | 0.071 |
| 24 descriptor rebuild | 63.598 | 0.060 |
| 128 initial map refresh | 2430.980 | 86.099 |
| 128 moving process | 1601.947 | 0.078 |
| 128 descriptor rebuild | 1693.319 | 0.070 |
| 128 ordinary replicated tick | original full refresh: 1644.786 | 0.144 |
| 128 full resnapshot (explicit `refresh()`) | 1644.786 | 28.505 |
| 1000 object field lookups (24 fixture) | 28.909 | 0.351 |
| UI tick with colonist invalidation | 12.891 | 0.414 |
| UI config-only tick | 12.560 | 0.146 |
| New UI nodes across 30 ticks | 6030 | 0 |
| 24 software-GL idle frame p95 | 12.381 | 5.559 |

**Measured CPU stalls:** moving-process maxima fell from 73.790ms to 0.128ms
(24), and 1648.231ms to 0.108ms (128). Idle-process maxima fell from 66.276ms
to 0.110ms and 1626.890ms to 0.167ms respectively. The old idle animation
clock needlessly refreshed all entities even when nobody was moving.

128 requested entity buffers fell from **4096x4096** to **640x640** in the fixture.
Every texture edge is capped at 2048, and each terrain/entity pass family has
an aggregate 8,388,608-pixel (32MiB RGBA8) budget, excluding tiny disabled
2x2 viewports and visibility masks; this is not a total-memory measurement.
The 128/256 budget regressions cover all 32 terrain bands (8,388,608 pixels)
and 31 exposed entity bands (7,976,800 pixels) simultaneously. Actual 128/256
GL fit views have a largest terrain texture of 2048x2048 and use 8,388,608
terrain pixels and 409,600 entity pixels in the two-depth camera fixture.
Lower fit-view texture resolution
keeps blur in world-cell units. Sparse whole entities retain native 32px detail
independently of terrain's resolution; their crops have a separate budget.

## Measured causes versus unconfirmed suspects

- The reviewed map rescanned every Tile row and reran reflective property-list
  lookups / column visibility rays when rebuilding descriptors. The measured
  moving hot path costs ~65ms at 24 and ~1.6s at 128; even idle animation-clock
  changes triggered that same work. Cached exposure, sparse indexes, validated
  field lookups, and unchanged-actor fast paths remove those measured CPU stalls.
- Main forced a full map refresh on ordinary replicated ticks and recreated
  People/Alerts/Excavation nodes. The actual Main `_refresh()` comparison above
  confirms the UI cost and 6030 newly instantiated nodes per 30-tick sample;
  changed-table invalidation and persistent cards remove that churn.
- Full-world `UPDATE_ALWAYS` entity passes also did unnecessary render work.
  The actual GL draw-call comparison verifies that the new on-demand passes
  stop rendering when idle. The recorded 24 software-GL frame p95 improves,
  but this does not isolate physical-GPU memory pressure as a production cause.
- No live reproduction of the user's freezes was available: the original
  client process was already absent. Backend planning/tick costs, SDK decode,
  network stalls, and production GPU/driver behavior remain unconfirmed here;
  these client fixtures do not establish that every game freeze is fixed.

## Regression evidence

`checks.log`: 17 final regression runs pass, with missing success markers,
runtime script errors, and unexpected engine errors treated as failures.
`profile-validation.log`: five final profile smoke runs also pass; the original
recorded comparison logs and values above were retained rather than overwritten.
New CPU coverage: 699 assertions; existing terrain:
125 assertions. Coverage includes camera anchors/inverses, global pan/local
picking, complete-facility precedence, focus/menu/panel drag cancellation, Viewer layer controls,
360px HUD at every font size 10..24, cache/resource/node identity stability,
unknown chunks/materials, scalar swept movement, session replacement, legacy UI,
workspace, menus, font settings, history, subscription lifecycle, diagnostics.
Actual Main input/controller tests also cover sparse known physical cells without
empty Tile rows beyond 24x24: build, whole-facility placement, excavation,
durable facility IDs and work/block controls. Geometry growth to 256 leaves
unreplicated cells unknown; same-generation/revision/size database replacement
clears stale camera, selection, actor, tile-index, and terrain caches.

GL tests cover the existing shader/composed regressions plus actual 24/128/256 map
cameras. Deep/near-floor pixel difference is **0.000000**, whole actor presence
changes **944 pixels**, and idle render draw calls are **5 vs 10** when entity
passes are deliberately forced back to `UPDATE_ALWAYS`. This verifies that
`UPDATE_ONCE` stops actual rendering even though Godot retains that requested
mode in the SubViewport property getter. Captures are in ignored
`client/godot/build/map-client/{camera,fit}-{24,128,256}.png`.

## Remaining limits

- Initial 128-map install (~86ms headless/~126ms GL), terrain/cut changes, and
  first explicit full-world visibility queries are still synchronous, not
  background streamed. No whole-world tile scans occur on layered animation frames or
  ordinary colony/colonist/config ticks. An explicit full resnapshot costs ~29ms.
- These synthetic measurements do not cover SDK decode/transport stalls or
  production hardware frame times. Those unrelated modules were not edited.
  The reviewed 128 software-GL baseline was not run with giant full-world passes;
  its buffer dimensions above are headless requested sizes, not a GPU allocation
  or before/after physical-GPU benchmark. 256 is regression coverage, not a
  recorded production performance comparison.
- Live PID 2196526 was already absent on the first read-only process check.
  Server PID 1532 remained running, ~0% CPU; it was never stopped or mutated.
- No backend contract change is required: authoritative geometry dimensions,
  chunk/material revisions, actual xyz, and layer bounds are reused as-is.
- No merge/push or independent integration review was performed. Parent must
  still obtain reviewer confidence >=0.92 with no fatal issues before integration.
