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

Depth below the cut progressively darkens and blurs the world presentation.
Selection and designation overlays are drawn separately and remain sharp.
Visible colonists and facilities are complete sprites, drawn once, rather than
one slice per occupied layer. Solid terrain between an entity and the cut
occludes it. Render interpolation uses the authoritative next navigation hop,
not an assumed X-first path toward the final destination.

Floor-to-floor shortcuts, if added later, are a separate convenience from exact
single-layer navigation.
