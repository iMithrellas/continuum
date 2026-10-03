# World art and bounded terrain frames

## Art direction

An illustrated field-guide colony: olive loam, cool fractured stone, warm timber,
cream work caps, teal coats, layered broadleaf crowns and clearly planted beds.
Silhouettes carry facility identity at native map scale. UI plates, selection,
destination brackets and critical pins retain the project's accessible UI tokens.

`assets/world/materials.png` has six original seamless material families: soil,
stone, sand, clay, gravel/unknown and turf. The first two are the current server
materials. Name lookup uses replicated material metadata, not assumed IDs. The
soil treatment is an artistic substrate, not a claim about fertility or yield.
No terrain height, material identity, ecology value or tree facility is generated
by the runtime renderer. The world-coordinate noise only modulates pigment.

The seven illustrated facility sheets have crops, irregular tree crowns,
trestle tables, canvas shelters, a well/garden, mining outcrops and braced crates.
The worker sheet replaces the earlier robot-like test sprite with an animated
field worker. Original sheets are generated reproducibly by
`client/godot/tools/generate_world_art.py` (Pillow + numpy); no third-party art.

Material transitions borrow pigment only from a **known, same-z exposed surface**.
Unknown rays, floorless rays, cliffs and cuts cannot supply blended colour.
Actual height changes receive narrow contact shade and light-facing rims.
Overview representatives omit those physical-looking cliff rims. World UVs are
independent of camera crops, chunk boundaries, page allocation and sample stride.
Mipmapped filtering removes texture detail with distance and depth; the existing
whole-entity depth blur and exact exposure masks remain intact.

## Labels

Thresholds use screen-cell pixels multiplied by UI scale, not fit-relative zoom:

| Routine label | Minimum cell |
| --- | ---: |
| Region title/count | 22 px |
| Work/excavation status | 36 px |
| Routine nameplate policy | 28 px |

The existing map only draws names for the selected actor; these remain visible.
Hover/selected regions bypass routine-label thresholds. Tiny sites reveal their
label on focus; automatic forest labels need at least 12 cells. Routine grid dots
are removed; a subtle placement grid appears only while editing at >=24px/cell.

## Streaming integration API (locked 2048 contract)

The visual adapter is explicit:

```gdscript
map.set_terrain_frame(frame) # returns bool; installs visual data only
# or, for a renderer without ColonyMap:
terrain_view.rebuild_frame(exact_model, frame) # returns bool
```

```gdscript
{
    "region": Rect2i(...), # logical world coverage, aligned to stride
    "stride": 1,          # detail=1; overview=8,32,128,512 (LOD 3,5,7,9)
    "cut": exact_model.cut,
    "revision": visual_revision,
    "mode": "detail",     # or "overview"
    "samples": {
        Vector2i(world_x, world_y): {
            "known": true,
            "surface_z": actual_exposed_z,
            "material": replicated_material_id,
        },
        # known=false OR missing key = pending
        # known=true, material=0, surface_z=min_z-1 = resolved empty ray
    },
}
```

Keys are **footprint origins**, not representative source points. For overview
row sample `(lx,ly)`, key is `(chunk_xy*16 + local_xy) * stride`; its supplied
values came from the contract's representative point `key + stride/2` on the
server. This adapter performs no source/override decoding. `exact_model` supplies
bounds, material rows and, in detail mode only, whole-body exposure queries.
Overview values never enter the exact model or authorize entity occlusion.

Both sample dictionary and `region.area / stride²` are limited to 65,536.
Detail coverage must also fit 2,048 logical cells per axis. Unsupported strides,
misaligned frames, stale cuts and over-budget detail frames return `false`.
The streaming owner chooses a coarser authoritative LOD before calling the API.
Pass a one-sample halo in `samples` when available for crop-edge continuity;
the dictionary including its halo must stay inside its sample budget.
Advance `revision` when sample data, coverage or pending state changes. Every
input, including cache-key hits, is type-checked: present samples require boolean
`known`; known samples require integer `surface_z` and `material`. Opaque samples
must reference a registered material whose `opaque` field is boolean `true`, with
height in `[min_z, cut]`. Resolved-empty samples require registered nonopaque air
(`material=0`) and exactly `surface_z=min_z-1`. Pending samples may omit both value
fields or supply that same empty sentinel, never an exposed-surface payload.

The renderer retains a primitive-only, recursively read-only snapshot. Mutating
the caller's dictionaries cannot change an accepted frame. A reused key with
different valid rendering samples is rejected; identical valid samples reuse
their textures and mask allocations. Model identity/revision, geometry/cut and
registered opacity changes invalidate the accepted context. Its pages, metadata
bindings, masks and entity passes are immediately suspended and released, leaving
pending coverage until a valid current frame arrives. `layout`, entity updates and
visibility toggles cannot revive that stale frame or fall back to exact queries.

`presentation_changed` notifies independent map children when their cached draw
commands must change. External room envelopes check both `is_overview()` and
`is_frame_suspended()`; their physical detail drawing returns with a valid detail
frame. The frame API returns `false` for malformed input without replacing an
otherwise compatible accepted frame.

**Caller integration:** compact mode must call the frame API instead of the
legacy `terrain_view.rebuild(model)` call in `ColonyMap.refresh`. Install the
frame after updating the exact resident model. Use existing `camera_changed`
and cut signals to request the new viewport. The stream/picking owner must make
overview clicks focus/zoom into detail before selection, placement or exact
inspection, as required by the large-world contract. No subscription or picking
architecture is changed by this art branch.

Missing frame samples show dark diagonal loading paper with a readable pending
caption. Resolved empty rays keep the exact deep backing. Overview shows
“Terrain overview · zoom in to inspect” and suppresses physical map overlays and
entity descriptors. Detail resumes exact selected/hover/critical cues.

## Allocation and cache behavior

Legacy detail rendering indexes **replicated exposed cells**, not the logical
bounds rectangle. Streaming rendering indexes only the bounded frame samples.
Camera queries then visit occupied spatial pages. Pages are 128 samples/edge;
a compact camera crop can use one page up to 256 samples/edge. Metadata includes
one sample of halo. Geometry masks are one texel/sample and share the terrain
source texture with **nearest filtering on both bindings** (important for GL
Compatibility: linear source sampling can otherwise round off mask corners).

There is no per-cell image write or texture allocation for 2048² logical cells at
Fit. Representative stride expands sample footprints in world space. At current
32 depth bands, a maximum frame needs <=2,097,152 mask texels plus <=65,536 RGBAF
metadata texels and halos, below the existing 8,388,608-texel terrain budget.
The shared material atlas is 1536×256 with mipmaps. Whole-entity passes keep their
independent 8,388,608-pixel budget and 2048 edge cap. Inactive page texture/mask
references are released. Idle ticks and unchanged frames keep resource identities.

`terrain_view.terrain_layers()` enumerates all spatial-page terrain rectangles;
the old `layers` array remains the first page's depth-indexed compatibility view.
Code summing memory or inspecting **all** rendered terrain must use the method.

## Tests and evidence

Private Xvfb OpenGL captures use **Mesa llvmpipe**, not hardware-GPU performance.
No shared desktop, native backend, external account or production world was used.
All screenshots are actual `ColonyMap` + generated rows + depth compositor.
The same 128/256 voxel fixtures were captured before and after at 40/16/4 px
cells and 1280×720 / 1920×1080. Original before captures use base `705a72c`.

2048 captures use a centered, resident 128² voxel patch with 2048² logical bounds,
plus contract-shaped representative overview samples derived from that same
persisted fixture cache. Missing areas remain pending. The staged sparse fixture
bypasses the old dense model rebuild: it proves renderer behavior, **not** the
new server generator or new subscription/model implementation. Production
streaming end-to-end evidence belongs to the parent integration pass.

Full-resolution files and measurement logs are in this worktree's ignored
`client/godot/build/world-art/`; committed contact sheets accompany this document.

- [128 world, 720p before/after](evidence/world-art-128-1280x720.png)
- [128 world, 1080p before/after](evidence/world-art-128-1920x1080.png)
- [2048 bounds, 720p detail/overview](evidence/world-art-2048-1280x720.png)
- [2048 bounds, 1080p detail/overview](evidence/world-art-2048-1920x1080.png)
- [Unabridged measurement logs](evidence/world-art-metrics.txt)

Observed frame p50 milliseconds (near / mid / far), same private llvmpipe driver:

| World | Resolution | Before | After |
| --- | --- | --- | --- |
| 128 | 1280×720 | 24.89 / 61.74 / 33.15 | 58.92 / 57.17 / 16.11 |
| 128 | 1920×1080 | 89.36 / 109.83 / 34.34 | 80.54 / 78.43 / 14.14 |
| 256 | 1280×720 | 26.09 / 60.24 / 43.07 | 17.12 / 38.50 / 21.15 |
| 256 | 1920×1080 | 91.24 / 109.95 / 50.51 | 71.69 / 77.79 / 25.07 |

These shared-host timings include load variability (notably the 128/720 near
capture); they are not a universal speedup or a hardware frame-rate guarantee.
2048 sparse-frame p50 is 17.60 / 38.20 / 17.79 ms at 720p, and 70.15 / 76.89 /
30.95 ms at 1080p. At 1080p the 4px-cell camera exceeds the detail sample budget,
so that far view correctly uses authoritative representative LOD. A 0.5px-cell
2048 overview is 13.49 ms at 720p / 17.68 ms at 1080p. All captures report **zero
idle terrain rebuilds and zero idle mask rebuilds**. Terrain mask texture counts
at 256/1080 are 14,976 / 98,208 / 720,896 texels versus the 8,388,608 budget.

Capture reproduction:

```sh
python3 client/godot/tools/map_client_x11.py \
  --scene res://tools/world_art_evidence.tscn -- --phase=after --edge=2048
godot --headless --path client/godot --scene res://tools/world_art_test.tscn
python3 client/godot/tools/map_client_x11.py --scene res://tools/world_art_test.tscn
```

`world_art_test` checks material distinction, negative-coordinate/crop metadata,
all four overview LODs, empty-versus-pending semantics, zero overview physical
queries, zoom-label focus overrides, 128/256/2048 budgets and idle caches. Its GL
path compares camera crops and split pages pixel-for-pixel, checks soft material
edges, cliff pigment isolation, exact opaque mask corners, empty holes and
representative pending pixels. Existing terrain, map interaction, sparse picking,
feedback, asset split/crop continuity and composed-occlusion suites also pass.

The follow-up `world_art_review_test.tscn` reproduces independent-review R2–R4:
malformed and contradictory samples at reused/fresh cache keys; immutable cache
ownership; every page and retained shader TextureRef at the maximum sample
budget; actual old-cut → rejection → pending → new-cut pixels; whole-entity mask
release/restoration; and external room detail → overview → detail at 1280×720 and
1920×1080. Run it headless for validation/allocation checks or through the same
private Xvfb runner for pixel checks. Evidence is written to
`client/godot/build/art-review-fixes/`.
