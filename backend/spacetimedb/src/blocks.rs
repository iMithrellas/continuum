//! Atomic operator operations over inclusive rectangular tile blocks.

use crate::auth::{authorize, RequiredRole};
use crate::events::log_event;
use crate::schema::{tile, work_order, world_geometry, Severity, Tile, WorkOrder};
use crate::sim::{self, TileKind, WorkType, FACILITY_BUILD_WOOD_COST};
use spacetimedb::{reducer, ReducerContext, Table};

/// Existing `WorkType` is the wire-level work-kind primitive.
pub type WorkKind = WorkType;

pub(crate) use sim::construction::BlockRect as Rect;

fn normalize_rect_in_bounds(
    start_x: i32,
    start_y: i32,
    end_x: i32,
    end_y: i32,
    width: i32,
    height: i32,
) -> Result<Rect, String> {
    let rect = Rect {
        min_x: start_x.min(end_x),
        min_y: start_y.min(end_y),
        max_x: start_x.max(end_x),
        max_y: start_y.max(end_y),
    };
    if rect.min_x < 0 || rect.max_x >= width || rect.min_y < 0 || rect.max_y >= height {
        return Err("rectangle must be inside the colony grid".into());
    }
    Ok(rect)
}

pub(crate) fn reducer_rect(
    ctx: &ReducerContext,
    start_x: i32,
    start_y: i32,
    end_x: i32,
    end_y: i32,
) -> Result<Rect, String> {
    let (width, height) = ctx
        .db
        .world_geometry()
        .id()
        .find(0)
        .map(|g| (g.width, g.height))
        .unwrap_or((sim::GRID_W, sim::GRID_H));
    normalize_rect_in_bounds(start_x, start_y, end_x, end_y, width, height)
}

pub(crate) fn validate_elevation(ctx: &ReducerContext, z: i32) -> Result<(), String> {
    let (min_z, max_z) = ctx
        .db
        .world_geometry()
        .id()
        .find(0)
        .map(|g| (g.min_z, g.max_z))
        .unwrap_or((-16, 15));
    if !(min_z..=max_z).contains(&z) {
        return Err("elevation outside world bounds".into());
    }
    Ok(())
}

/// Historical rectangle fixtures are intentionally still 24x24.
#[cfg(test)]
pub(crate) fn normalize_rect(
    start_x: i32,
    start_y: i32,
    end_x: i32,
    end_y: i32,
) -> Result<Rect, String> {
    normalize_rect_in_bounds(start_x, start_y, end_x, end_y, sim::GRID_W, sim::GRID_H)
}

pub(crate) fn rect_area(rect: Rect) -> u64 {
    rect.cells().expect("validated rectangle")
}

pub(crate) fn block_cost(rect: Rect) -> f32 {
    rect_area(rect) as f32 * FACILITY_BUILD_WOOD_COST
}

fn to_sim_tile(tile: &Tile) -> sim::Tile {
    sim::Tile {
        id: tile.id,
        x: tile.x,
        y: tile.y,
        kind: tile.kind,
        enabled: tile.enabled,
        z: tile.z,
        width: tile.width,
        depth: tile.depth,
        clearance_height: tile.clearance_height,
    }
}

#[cfg(test)]
pub(crate) fn validate_empty_block(
    tiles: &[sim::Tile],
    rect: Rect,
    kind: TileKind,
    stored_wood: f32,
) -> Result<Vec<u32>, String> {
    if kind == TileKind::Empty {
        return Err("empty tiles are not constructible".into());
    }
    let mut ids = Vec::with_capacity(rect_area(rect) as usize);
    for y in rect.min_y..=rect.max_y {
        for x in rect.min_x..=rect.max_x {
            let tile = tiles
                .iter()
                .find(|tile| tile.x == x && tile.y == y && tile.z == 0);
            let Some(tile) = tile else {
                return Err("rectangle contains missing grid cells".into());
            };
            if tile.kind != TileKind::Empty {
                return Err("every tile in the rectangle must be empty".into());
            }
            ids.push(tile.id);
        }
    }
    let cost = block_cost(rect);
    if !stored_wood.is_finite() || stored_wood < cost {
        return Err(format!(
            "building requires {cost:.0} stored wood; colony has {stored_wood:.1}"
        ));
    }
    Ok(ids)
}

pub(crate) fn compatible_tile_ids(
    tiles: &[sim::Tile],
    rect: Rect,
    work: WorkType,
) -> Result<Vec<u32>, String> {
    let definition = work
        .definition()
        .ok_or("work orders require a producing job")?;
    Ok(tiles
        .iter()
        .filter(|tile| {
            tile.x >= rect.min_x
                && tile.z == 0
                && tile.x <= rect.max_x
                && tile.y >= rect.min_y
                && tile.y <= rect.max_y
                && tile.kind == definition.facility
        })
        .map(|tile| tile.id)
        .collect())
}

fn validate_priority(priority: u8) -> Result<(), String> {
    if (1..=3).contains(&priority) {
        Ok(())
    } else {
        Err("work order priority must be between 1 and 3".into())
    }
}

/// Legacy z=0 entry point: the same atomic 4096-cell cap and fast cost preflight
/// as `build_tile_block_at`, with no implicit subdivision of larger rectangles.
#[reducer]
pub fn build_tile_block(
    ctx: &ReducerContext,
    start_x: i32,
    start_y: i32,
    end_x: i32,
    end_y: i32,
    kind: TileKind,
) -> Result<(), String> {
    authorize(ctx, RequiredRole::Operator)?;
    let rect = reducer_rect(ctx, start_x, start_y, end_x, end_y)?;
    // Empty physical cells need not have inert operational rows. The same
    // atomic planner allocates durable IDs on demand at the legacy z=0 layer.
    crate::reducers::vertical::build_tile_block_at(ctx, start_x, start_y, end_x, end_y, 0, kind)?;
    let cost = block_cost(rect);
    log_event(
        ctx,
        Severity::Info,
        format!(
            "Built {kind:?} block ({},{})-({},{}) for {cost:.0} stored wood by operator {}.",
            rect.min_x,
            rect.min_y,
            rect.max_x,
            rect.max_y,
            crate::auth::identity_hex(ctx.sender())
        ),
    );
    Ok(())
}

#[reducer]
pub fn set_tile_block_enabled(
    ctx: &ReducerContext,
    start_x: i32,
    start_y: i32,
    end_x: i32,
    end_y: i32,
    enabled: bool,
) -> Result<(), String> {
    authorize(ctx, RequiredRole::Operator)?;
    let rect = reducer_rect(ctx, start_x, start_y, end_x, end_y)?;
    let tiles: Vec<_> = ctx.db.tile().iter().collect();
    let ids: Vec<_> = tiles
        .iter()
        .filter(|tile| {
            tile.kind != TileKind::Empty
                && tile.z == 0
                && tile.x >= rect.min_x
                && tile.x <= rect.max_x
                && tile.y >= rect.min_y
                && tile.y <= rect.max_y
        })
        .map(|tile| tile.id)
        .collect();
    if ids.is_empty() {
        return Err("rectangle contains no non-empty tiles".into());
    }
    let mut changed = 0;
    for id in ids {
        let mut tile = ctx
            .db
            .tile()
            .id()
            .find(id)
            .expect("validated tile disappeared");
        if tile.enabled != enabled {
            tile.enabled = enabled;
            ctx.db.tile().id().update(tile);
            changed += 1;
        }
    }
    if changed > 0 {
        log_event(
            ctx,
            Severity::Info,
            format!(
                "Tile block ({},{})-({},{}) was {} by operator {} ({changed} tiles).",
                rect.min_x,
                rect.min_y,
                rect.max_x,
                rect.max_y,
                if enabled { "enabled" } else { "disabled" },
                crate::auth::identity_hex(ctx.sender())
            ),
        );
    }
    Ok(())
}

#[reducer]
#[allow(clippy::too_many_arguments)]
pub fn set_block_work_order(
    ctx: &ReducerContext,
    start_x: i32,
    start_y: i32,
    end_x: i32,
    end_y: i32,
    work: WorkKind,
    priority: u8,
    enabled: bool,
) -> Result<(), String> {
    authorize(ctx, RequiredRole::Operator)?;
    let rect = reducer_rect(ctx, start_x, start_y, end_x, end_y)?;
    validate_priority(priority)?;
    let tiles: Vec<_> = ctx.db.tile().iter().collect();
    let sim_tiles: Vec<_> = tiles.iter().map(to_sim_tile).collect();
    let ids = compatible_tile_ids(&sim_tiles, rect, work)?;
    if ids.is_empty() {
        return Err("rectangle contains no compatible non-empty tiles".into());
    }
    let mut changed = 0;
    for id in ids {
        let tile = ctx
            .db
            .tile()
            .id()
            .find(id)
            .expect("validated tile disappeared");
        let order = sim::WorkOrder::new(&to_sim_tile(&tile), work, priority, enabled)?;
        let row = WorkOrder {
            id: order.id,
            tile_id: id,
            work,
            priority,
            enabled,
        };
        match ctx.db.work_order().id().find(order.id) {
            Some(existing)
                if existing.tile_id == row.tile_id
                    && existing.work == row.work
                    && existing.priority == row.priority
                    && existing.enabled == row.enabled => {}
            Some(_) => {
                ctx.db.work_order().id().update(row);
                changed += 1;
            }
            None => {
                ctx.db.work_order().insert(row);
                changed += 1;
            }
        }
    }
    if changed > 0 {
        log_event(ctx, Severity::Info, format!(
            "Work order block ({},{})-({},{}) set to {work:?}, priority {priority}, enabled {enabled} by operator {} ({changed} tiles).",
            rect.min_x, rect.min_y, rect.max_x, rect.max_y,
            crate::auth::identity_hex(ctx.sender())
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tile(id: u32, x: i32, y: i32, kind: TileKind) -> sim::Tile {
        sim::Tile {
            id,
            x,
            y,
            kind,
            enabled: true,
            z: 0,
            width: 1,
            depth: 1,
            clearance_height: 4,
        }
    }

    #[test]
    fn normalizes_inclusive_bounds_and_costs_area() {
        let rect = normalize_rect(3, 4, 1, 2).unwrap();
        assert_eq!(
            rect,
            Rect {
                min_x: 1,
                min_y: 2,
                max_x: 3,
                max_y: 4
            }
        );
        assert_eq!(rect_area(rect), 9);
        assert_eq!(block_cost(rect), 180.0);
    }

    #[test]
    fn rectangle_bounds_follow_persisted_geometry_not_the_starter_extent() {
        assert!(normalize_rect_in_bounds(24, 24, 127, 127, 128, 128).is_ok());
        assert!(normalize_rect_in_bounds(24, 24, 127, 127, 24, 24).is_err());
        assert!(normalize_rect_in_bounds(0, 0, 128, 0, 128, 128).is_err());
        assert!(normalize_rect_in_bounds(0, -1, 0, 127, 128, 128).is_err());
        assert!(normalize_rect_in_bounds(i32::MIN, 0, i32::MAX, 0, 128, 128).is_err());
        assert!(normalize_rect_in_bounds(0, 0, 255, 255, 256, 256).is_ok());
        assert!(normalize_rect_in_bounds(32, 30, 0, 0, 33, 31).is_ok());
        assert!(normalize_rect_in_bounds(32, 31, 0, 0, 33, 31).is_err());
    }

    #[test]
    fn rejects_invalid_rectangles_and_empty_builds() {
        assert!(normalize_rect(-1, 0, 1, 1).is_err());
        assert!(normalize_rect(0, 0, sim::GRID_W, 0).is_err());
        let tiles = vec![tile(1, 0, 0, TileKind::Empty)];
        let rect = normalize_rect(0, 0, 0, 0).unwrap();
        assert!(validate_empty_block(&tiles, rect, TileKind::Empty, 20.0).is_err());
    }

    #[test]
    fn prevalidates_full_block_before_building() {
        let rect = normalize_rect(0, 0, 1, 0).unwrap();
        let tiles = vec![tile(1, 0, 0, TileKind::Empty)];
        assert!(validate_empty_block(&tiles, rect, TileKind::Farm, 100.0).is_err());
        let occupied = vec![
            tile(1, 0, 0, TileKind::Farm),
            tile(2, 1, 0, TileKind::Empty),
        ];
        assert!(validate_empty_block(&occupied, rect, TileKind::Farm, 100.0).is_err());
        assert!(validate_empty_block(
            &[tile(1, 0, 0, TileKind::Empty)],
            normalize_rect(0, 0, 0, 0).unwrap(),
            TileKind::Farm,
            19.9
        )
        .is_err());
        assert!(validate_empty_block(
            &[tile(1, 0, 0, TileKind::Empty)],
            normalize_rect(0, 0, 0, 0).unwrap(),
            TileKind::Farm,
            f32::NAN
        )
        .is_err());
        assert!(validate_empty_block(
            &[tile(1, 0, 0, TileKind::Empty)],
            normalize_rect(0, 0, 0, 0).unwrap(),
            TileKind::Farm,
            f32::INFINITY
        )
        .is_err());
    }

    #[test]
    fn filters_compatible_work_and_keeps_forest_jobs_distinct() {
        let tiles = vec![
            tile(1, 0, 0, TileKind::Forest),
            tile(2, 1, 0, TileKind::Farm),
            tile(3, 2, 0, TileKind::Empty),
        ];
        let rect = normalize_rect(0, 0, 2, 0).unwrap();
        assert_eq!(
            compatible_tile_ids(&tiles, rect, WorkType::Logging).unwrap(),
            vec![1]
        );
        assert_eq!(
            compatible_tile_ids(&tiles, rect, WorkType::Hunting).unwrap(),
            vec![1]
        );
        assert!(compatible_tile_ids(&tiles, rect, WorkType::None).is_err());
        let logging = sim::WorkOrder::new(&tiles[0], WorkType::Logging, 2, true).unwrap();
        let hunting = sim::WorkOrder::new(&tiles[0], WorkType::Hunting, 2, true).unwrap();
        assert_ne!(logging.id, hunting.id);
    }
}
