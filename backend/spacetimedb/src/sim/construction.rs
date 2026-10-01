//! Bounded, atomic facility-block planning from narrow geometry/tile inputs.
//! No database writes, world cloning, navigation or growing-row rescans.
use super::geometry::{Body, Cell, Geometry};
use super::{Tile, TileKind, FACILITY_BUILD_WOOD_COST};

/// Inclusive cell-area cap for both block-build reducers, at every elevation.
/// A block build is one atomic intent, never silently split into smaller builds.
/// Excavation designations, single-footprint placement and existing facilities
/// are NOT subject to this block cap.
pub const MAX_ATOMIC_BUILD_CELLS: u64 = 4096;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BlockRect {
    pub min_x: i32,
    pub min_y: i32,
    pub max_x: i32,
    pub max_y: i32,
}
impl BlockRect {
    pub fn cells(self) -> Result<u64, String> {
        let width = i64::from(self.max_x) - i64::from(self.min_x) + 1;
        let depth = i64::from(self.max_y) - i64::from(self.min_y) + 1;
        if width <= 0 || depth <= 0 {
            return Err("invalid construction rectangle".into());
        }
        (width as u64)
            .checked_mul(depth as u64)
            .ok_or_else(|| "construction area overflow".into())
    }
}

pub fn validate_cost(wood: f32, cost: f32) -> Result<(), String> {
    if !wood.is_finite() || !cost.is_finite() || cost < 0.0 || wood < cost {
        return Err(format!("building requires {cost} stored wood"));
    }
    Ok(())
}

/// Run before loading the world or allocating any planning data. Both rejection
/// paths are independent of requested area and of the number of existing rows.
pub fn preflight_block(rect: BlockRect, kind: TileKind, wood: f32) -> Result<f32, String> {
    if kind == TileKind::Empty {
        return Err("empty tiles are not constructible".into());
    }
    let cells = rect.cells()?;
    let cost = cells as f32 * FACILITY_BUILD_WOOD_COST;
    validate_cost(wood, cost)?;
    if cells > MAX_ATOMIC_BUILD_CELLS {
        return Err(format!("one atomic construction block supports at most {MAX_ATOMIC_BUILD_CELLS} cells (requested {cells})"));
    }
    Ok(cost)
}

/// Axis-aligned integer volume intersection is equivalent to checking every
/// reserved voxel, including footprint interiors and partial z overlap. Use
/// widened endpoints so malformed/outside legacy rows cannot overflow queries.
pub(crate) fn volumes_overlap(a: &Tile, b: &Tile) -> bool {
    fn interval(a: i32, aw: u16, b: i32, bw: u16) -> bool {
        aw > 0
            && bw > 0
            && i64::from(a) < i64::from(b) + i64::from(bw)
            && i64::from(b) < i64::from(a) + i64::from(aw)
    }
    a.kind != TileKind::Empty
        && b.kind != TileKind::Empty
        && interval(a.x, a.width, b.x, b.width)
        && interval(a.y, a.depth, b.y, b.depth)
        && interval(a.z, a.clearance_height, b.z, b.clearance_height)
}

#[derive(Clone, Debug, PartialEq)]
pub struct BlockPlan {
    /// Only changed/created rows, in y/x order, with durable IDs already assigned.
    pub tiles: Vec<Tile>,
    pub cost: f32,
}

/// Plan at most 4096 one-cell facilities with four-cell clearance. For E existing
/// rows, A requested cells and C material chunks, planning is O(E + A log C): one
/// existing-row pass, bounded anchor/output vectors and at most five material
/// lookups per cell. Loading/persistence costs are outside this pure planner.
pub fn plan_block(
    geometry: &Geometry,
    existing: &[Tile],
    rect: BlockRect,
    z: i32,
    kind: TileKind,
    wood: f32,
) -> Result<BlockPlan, String> {
    let cost = preflight_block(rect, kind, wood)?;
    let top = z
        .checked_add(3)
        .ok_or("facility clearance outside world bounds")?;
    if !geometry.contains(Cell(rect.min_x, rect.min_y, z))
        || !geometry.contains(Cell(rect.max_x, rect.max_y, top))
    {
        return Err("facility clearance outside world bounds".into());
    }
    let width = (i64::from(rect.max_x) - i64::from(rect.min_x) + 1) as usize;
    let depth = (i64::from(rect.max_y) - i64::from(rect.min_y) + 1) as usize;
    let area = width * depth; // preflight bounded this to 4096
    let slab = Tile {
        id: 0,
        x: rect.min_x,
        y: rect.min_y,
        z,
        kind,
        enabled: true,
        width: width as u16,
        depth: depth as u16,
        clearance_height: 4,
    };
    let mut anchors = vec![None; area];
    let mut max_id = 0;
    // All requested one-cell volumes form this single prism. One existing-row
    // pass detects ANY reservation overlap and indexes reusable base anchors.
    // New rows are disjoint by construction, so never scan a growing plan.
    for tile in existing {
        if volumes_overlap(tile, &slab) {
            return Err("facility volumes overlap".into());
        }
        max_id = max_id.max(tile.id);
        if tile.z == z
            && tile.x >= rect.min_x
            && tile.x <= rect.max_x
            && tile.y >= rect.min_y
            && tile.y <= rect.max_y
        {
            let at = (tile.x - rect.min_x) as usize + width * (tile.y - rect.min_y) as usize;
            // Preserve the historical first-base-row lookup if a fixture has
            // duplicate coordinate anchors. Persisted tile IDs stay authoritative.
            anchors[at].get_or_insert(tile.id);
        }
    }
    let added = anchors.iter().filter(|id| id.is_none()).count() as u32;
    max_id.checked_add(added).ok_or("tile ID exhausted")?;
    let mut next_id = max_id;
    let mut tiles = Vec::with_capacity(area);
    for y in rect.min_y..=rect.max_y {
        for x in rect.min_x..=rect.max_x {
            let p = Cell(x, y, z);
            if !geometry.supported(
                p,
                Body {
                    width: 1,
                    depth: 1,
                    height: 4,
                    step: 0,
                },
            ) {
                return Err(
                    "facility needs positive dimensions, full clearance and solid support".into(),
                );
            }
            let at = (x - rect.min_x) as usize + width * (y - rect.min_y) as usize;
            let id = anchors[at].unwrap_or_else(|| {
                next_id += 1;
                next_id
            });
            tiles.push(Tile {
                id,
                x,
                y,
                z,
                kind,
                enabled: true,
                width: 1,
                depth: 1,
                clearance_height: 4,
            });
        }
    }
    Ok(BlockPlan { tiles, cost })
}

#[cfg(test)]
mod tests;
