//! Free operational usage planning. Buildings are orthogonal and are not inputs.
use super::construction::{volumes_overlap, BlockRect, MAX_ATOMIC_BUILD_CELLS};
use super::geometry::{Body, Cell, Geometry};
use super::{Tile, TileKind};

pub fn preflight_zone(rect: BlockRect, kind: TileKind) -> Result<usize, String> {
    if kind == TileKind::Empty {
        return Err("choose a usage designation; use clear_zone to clear".into());
    }
    let cells = rect.cells()?;
    if cells > MAX_ATOMIC_BUILD_CELLS {
        return Err(format!(
            "one designation supports at most {MAX_ATOMIC_BUILD_CELLS} cells"
        ));
    }
    Ok(cells as usize)
}

/// O(E + A log C), one existing-row scan and a bounded output; no growing rescans.
/// Same-kind one-cell rows preserve IDs, clearance and enablement. A multi-cell
/// legacy reservation must be cleared explicitly, never rewritten partially.
pub fn plan_zone(
    geometry: &Geometry,
    existing: &[Tile],
    rect: BlockRect,
    z: i32,
    kind: TileKind,
) -> Result<Vec<Tile>, String> {
    let area = preflight_zone(rect, kind)?;
    let top = z
        .checked_add(3)
        .ok_or("zone clearance outside world bounds")?;
    if !geometry.contains(Cell(rect.min_x, rect.min_y, z))
        || !geometry.contains(Cell(rect.max_x, rect.max_y, top))
    {
        return Err("zone clearance outside world bounds".into());
    }
    let width = (i64::from(rect.max_x) - i64::from(rect.min_x) + 1) as usize;
    let depth = (i64::from(rect.max_y) - i64::from(rect.min_y) + 1) as usize;
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
    let mut anchors: Vec<Option<&Tile>> = vec![None; area];
    let mut max_id = 0;
    for tile in existing {
        max_id = max_id.max(tile.id);
        if volumes_overlap(tile, &slab)
            && !(tile.kind == kind && tile.z == z && tile.width == 1 && tile.depth == 1)
        {
            return Err("conflicting usage volume; clear existing zone first".into());
        }
        if tile.z == z
            && tile.x >= rect.min_x
            && tile.x <= rect.max_x
            && tile.y >= rect.min_y
            && tile.y <= rect.max_y
        {
            let at = (tile.x - rect.min_x) as usize + width * (tile.y - rect.min_y) as usize;
            if anchors[at].replace(tile).is_some() {
                return Err("duplicate operational anchors".into());
            }
        }
    }
    let added = anchors.iter().filter(|t| t.is_none()).count() as u32;
    max_id.checked_add(added).ok_or("tile ID exhausted")?;
    let mut next_id = max_id;
    let mut planned = Vec::with_capacity(area);
    for y in rect.min_y..=rect.max_y {
        for x in rect.min_x..=rect.max_x {
            let at = (x - rect.min_x) as usize + width * (y - rect.min_y) as usize;
            let tile = match anchors[at] {
                Some(tile) if tile.kind == kind => tile.clone(),
                anchor => Tile {
                    id: anchor.map(|t| t.id).unwrap_or_else(|| {
                        next_id += 1;
                        next_id
                    }),
                    x,
                    y,
                    z,
                    kind,
                    enabled: true,
                    width: 1,
                    depth: 1,
                    clearance_height: 4,
                },
            };
            if tile.clearance_height < 4 {
                return Err("zone requires at least four clear cells".into());
            }
            if !geometry.supported(
                Cell(x, y, z),
                Body {
                    width: tile.width,
                    depth: tile.depth,
                    height: tile.clearance_height,
                    step: 0,
                },
            ) {
                return Err("zone needs full bounds, clearance and solid support".into());
            }
            planned.push(tile);
        }
    }
    Ok(planned)
}

/// Retain the durable anchor and its geometry; clearing is not demolition.
pub fn cleared_zone(tile: &Tile) -> Tile {
    let mut cleared = tile.clone();
    cleared.kind = TileKind::Empty;
    cleared.enabled = true;
    cleared
}

#[cfg(test)]
mod tests;
