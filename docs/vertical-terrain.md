# Vertical Terrain

## Physical coordinates

All three axes use integer **0.5 m cells**. A solid cell is one complete
material block, with a volume of **0.125 m³**. There are no fractional blocks,
thin floor slabs, or globally aligned storeys. A position's `z` is its base
(feet) layer; the supporting solid cell is at `z - 1`.

Floor, wall, and ceiling are adjacency roles of the same geometry. A floor is
the upper surface of a solid block beneath empty space, not a separate block
type. Excavating a supporting block changes the geometry and therefore changes
which surfaces exist.

Fresh/reset worlds span 128 × 128 cells (64 × 64 m), with a 24 × 24 starter
colony and the finite hillside fixture. Elevation remains `z = -16 .. 15`.
Publishing an upgrade preserves initialized dimensions; old missing-geometry
colonies initialize as flat 24 × 24 worlds. The admin-only `expand_world(width,
height)` reducer explicitly grows the horizontal bounds up to 256 cells per
axis, preserving all existing terrain and colony state. New land is flat soil
over stone with air above, not a procedural landscape generator.

Colonists default to a 1 × 1 cell footprint and four clear cells (2 m) of
standing height. Facility footprints and clearance volumes are integer cell
dimensions, allowing multi-cell furniture and tall equipment. Normal room and
tunnel designations default to six clear cells (3 m); their base elevation and
height are independent, not a storey number.

## Authority and derived data

SpacetimeDB holds authoritative material-ID terrain chunks and persistent
player excavation intent. Terrain cells are **not** individual ECS entities.
Each chunk contains a 16 × 16 × 16 dense material array, indexed by
`local_x + 16 * (local_y + 16 * local_z)`. Chunk coordinates use Euclidean
division, including below elevation zero. Material ID zero is air.

Entity position, body/footprint, movement, and work state are composed
capabilities. Operational facility IDs and existing stack IDs remain distinct
from terrain coordinates. Geometry queries derive support and clearance;
navigation and view caches are disposable results, not alternative geometry.

Material definitions include density (kg/m³), strength (Pa), thermal
conductivity (W/(m·K)), and specific heat capacity (J/(kg·K)). These properties
prepare the data model for later physics; this change does not implement
structural collapse, heat transfer, or temperature simulation.

The prototype's facilities reserve supported clear volumes and are traversable
room/work capabilities, not blocking furniture colliders. Soil and stone both
yield one prototype stone unit per mined block; material-specific inventories
and mass-limited carrying are deferred.

## Excavation and movement

An excavation designation contains an inclusive horizontal rectangle, a base
`bottom_z`, and a positive integer `height`. Its target volume is
`bottom_z .. bottom_z + height - 1`. Mining consumes actual solid cells rather
than producing indefinitely from a facility marker. Worker access, reach,
support, and standing clearance must be validated against the current geometry.

Terrain changes invalidate derived traversal data. Navigation must find a
supported path with clearance for the moving body's entire footprint and
height. A visible hole is not automatically a walkable destination. Placement
similarly validates every cell of the requested volume and its support, rather
than just the anchor cell. Inaccessible excavation remains pending instead of
teleporting a worker or removing remote blocks.

The legacy two-dimensional facility reducers refer to elevation zero only.
Layer-aware reducers explicitly include `z`; selecting one floor must not
toggle, build over, or issue work orders to a hidden floor in the same column.

## Cut-height presentation

The selected integer elevation is an inclusive **cut layer**, stepped in exact
0.5 m increments. Geometry above it is hidden. For each `(x, y)` column, the
view scans downward through air to the first opaque block, even if that block
is many layers below the cut. A solid intermediate floor stops the ray; an
open shaft reveals the lower surface.

The view retains each surface's real `(x, y, z)` coordinate. Rock at the cut is
an excavation target at that rock's layer; an exposed walking floor corresponds
to base elevation `surface_z + 1`. Interaction must never substitute the cut
layer for a lower visible surface's coordinate. Rectangle operations need a
single explicit base elevation, and placement must not silently cross uneven
floors.

Layer navigation is always available in the persistent toolbar, including for
Viewer users and with workspace panels hidden. The readout shows integer z and
its elevation in metres (0.5 m per layer); arrows or PageUp/PageDown / `]`/`[` with
map focus change it. Wheel zoom anchors at the cursor, middle-drag pans, `Fit`
fits the full world, and `1:1` restores native 32px cells. Picking and sharp
overlays use the same invertible world/screen transform; camera gestures cancel
unfinished editing drags rather than dispatching a shifted selection.

Animation and ordinary replicated ticks use cached exposure, sparse entity
indexes and changed-table invalidation instead of rescanning all world tiles.
Terrain and entity pass families each have an 8388608-pixel budget with texture
edges capped at 2048. Initial snapshots and terrain/cut changes remain
synchronous; this is bounded rendering, not background terrain streaming. The
fixture profiling demonstrates reduced CPU stalls, not a guarantee that SDK,
network or production GPU stalls are eliminated.

Depth below the cut progressively darkens and blurs the world presentation.
Selection and designation overlays are drawn separately and remain sharp.
Visible colonists and facilities are complete sprites, drawn once, rather than
one slice per occupied layer. Solid terrain between an entity and the cut
occludes it. Render interpolation uses the authoritative next navigation hop,
not an assumed X-first path toward the final destination.

The layered presentation uses compact entity/resource icons. The historical flat
view's persistent captions, numeric crate labels, work-order badges, and delivery
guides are not duplicated into the cut-height renderer; use tooltips, inspection,
and colony panels for detailed values and task state.

Floor-to-floor shortcuts, if added later, are a separate convenience from exact
single-layer navigation.

## Verification

- `just test`, `just fmt-check`, and `just wasm`: backend simulation/module gates.
- `just test-terrain-view`: backend-free cut visibility, picking, navigation
  controls, footprint/height interaction, permission, and font/layout tests.
- `just test-terrain-render`: real GPU blur/darkening, whole-entity rendering,
  near-floor occlusion, and sharp-overlay tests in the composed map.
  This opens a short-lived window and requires a display; the headless dummy
  renderer cannot validate shader output.
- `just test-map-client` and `just test-map-client-render`: camera/HUD/cache,
  narrow/font-scaled Viewer controls, sparse-cell interaction and 24/128/256
  software-GL composition. The render recipe uses isolated Xvfb.
- `just profile-map-client`: repeatable client CPU/frame/UI fixtures. New output
  is ignored build evidence; replacing saved comparison logs requires an explicit
  `--record-evidence` flag to the Python runner.
- `just test-vertical-terrain`: real mining, viewer authorization, conservation,
  and failed-intent rollback against an exclusively owned native server. Set
  `SPACETIME_CLI`/`SPACETIME_RUNTIME` if the pinned native executables are not
  installed in Continuum's normal cache. Set `CONTINUUM_BASELINE_WASM` to a
  previous module artifact to additionally check a non-destructive upgrade.
