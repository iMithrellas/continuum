# Large-map client integration

The client follows the locked storage-version-1 contract: persisted 32×32
columns, complete 16³ overrides, and server-authored per-cut overview rows at
LOD 3/5/7/9. It does not generate geometry from seeds.

## Renderer interface (art integration)

Production uses `model.render_frame(rect, budget=65536)` and
`map.set_terrain_frame(frame)` (bool success), matching `docs/world-art.md`.
The frame has `region`, `stride`, `cut`, `revision`, string `mode`, and a sample
dictionary keyed by footprint origins. Values are `{known, surface_z, material}`.
Overview representative points are translated back by `stride/2`; resolved empty
samples use `material=0, surface_z=min_z-1`; pending samples have `known=false`.
Compact lifecycle never calls legacy `terrain_view.rebuild(model)`.

`map.terrain_model.frame_samples(world_rect, stride=1, budget=65536)` and alias
`visible_surfaces(...)` return:

```
{ rect: Rect2i, stride: int, cut: int, revision: int,
  mode: &"detail" | &"overview", truncated: bool, samples: Array[Dictionary] }
```

Each sample has `xy:Vector2i`, `surface:Vector3i|null`, `material:int`, and
`state:&"pending"|&"resolved_empty"|&"surface"`. Stored ecological values, when
available, are `soil_fertility`, `forest_density`, `moisture`, normalized 0..1.
Detail samples are exact rays. Overview sample coordinates are the server's
representative points; a rendered sample spans `stride` world cells. Overview
samples NEVER populate `material_at`, support, clearance, picking, or occlusion.

The renderer iterates samples, NOT every cell in `rect`. Art dependency
`44a313d06f1f8d03396fa291a1a935cb8b8e5d9e` supplies bounded pages and overlays.
`presentation_mode` selects overview; `overview_frame_provider` is attached by
the session helper. Revision is meaningful together with mode, rect, stride and
cut. Ordinary redraws can reuse the frame until those inputs change.

## Lifecycle and subscription integration

`LargeWorldSession.attach(map)` installs camera/cut hooks.
`bootstrap_queries(db, legacy_queries)` drops unrestricted terrain subscriptions
when the new capability is present. After bootstrap acknowledgement,
`start(client, session_epoch)` returns whether the helper owns readiness.
`ready` only fires after server Ready AND nearby acknowledged physical coverage.
`mark_changed(table)` queues resident reconciliation; `tick(delta)` coalesces
requests and checks acknowledgement deadlines. `stop()` invalidates callback
ownership before releasing live subscriptions (or discarding offline handles).

Main's narrow hooks call these methods and show WorldLoadingOverlay immediately
after bootstrap, not after playable readiness. Loading processing precedes
ordinary colony/colonist UI refresh. Keyboard map input and mutation readiness
stay disabled during generation. Auth/status remain available. Cancel disconnects
the current client and returns through the existing leave-session path; it does
not stop native hosting or shared server generation.

New bindings with no generation row are legacy only when geometry AND colony
already exist. They request and acknowledge dense terrain separately. Missing
status on an uninitialized database is an actionable error. Already-ready worlds
skip generation presentation and wait only for real nearby snapshots.

## Bounds and cache semantics

- Exact source subscription residency: 64 chunks; pending snapshots: 4.
- Each source query includes corresponding complete edit chunks across all z.
- Override absence becomes baseline fallback ONLY after snapshot acknowledgement.
- Cached exposure: at most 65536 queried columns; cut changes clear this cache
  without scanning world dimensions. Reconciliation scans replicated resident
  rows, not server-wide data. Initial generation does not subscribe partial data.
- Selections: at most 4096 cells. Bounded source pins preserve existing exact
  selections across overview/panning. Eviction, pending geometry, cut changes,
  changed physical surfaces/materials, or database switches invalidate targets.
- Overview: at most 256 rows / 65536 representative samples; per-cut/LOD requests
  have the same session/client/world-generation and request-serial guards.
- Initial camera focuses `starter + (12,12)` at the existing native tile token.
  Zero-sized initial viewports defer camera initialization and streaming.

## Verification

```
godot --headless --path client/godot --script res://tools/large_map_foundations_test.gd
godot --headless --path client/godot --scene res://tools/large_map_wire_test.tscn
```

The wire fixture extends the old generated DB with normalized new table rows,
so it exercises the locked adapters and actual Main/menu join without guessing
unfinished generated class names. Final combined binding generation and a real
server wire/GPU composition gate remain parent integration work.

Current branch evidence: foundations 30 assertions; locked-wire/actual-menu/art
integration 36 assertions; terrain 126; inspector 43; world-art 2075 headless.
Terrain UI, Main menu, session handoff/switch, subscription lifecycle and operator
access also pass. A fresh isolated GPU rerun was attempted but blocked because
neither PATH nor the worktree's unpacked dependency contains Xvfb; no shared
desktop was used, and no new GPU-performance claim is made.
