//! Atomic operator operations over inclusive rectangular tile blocks.

use crate::auth::{authorize, RequiredRole};
use crate::events::log_event;
use crate::schema::{colony, tile, work_order, Severity, Tile, WorkOrder};
use crate::sim::{self, TileKind, WorkType, FACILITY_BUILD_WOOD_COST, GRID_H, GRID_W};
use spacetimedb::{reducer, ReducerContext, Table};

/// Existing `WorkType` is the wire-level work-kind primitive.
pub type WorkKind = WorkType;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Rect {
    pub min_x: i32,
    pub min_y: i32,
    pub max_x: i32,
    pub max_y: i32,
}

pub(crate) fn normalize_rect(
    start_x: i32,
    start_y: i32,
    end_x: i32,
    end_y: i32,
) -> Result<Rect, String> {
    let rect = Rect {
        min_x: start_x.min(end_x),
        min_y: start_y.min(end_y),
        max_x: start_x.max(end_x),
        max_y: start_y.max(end_y),
    };
    if rect.min_x < 0 || rect.max_x >= GRID_W || rect.min_y < 0 || rect.max_y >= GRID_H {
        return Err("rectangle must be inside the colony grid".into());
    }
    Ok(rect)
}

pub(crate) fn rect_area(rect: Rect) -> u64 {
    ((rect.max_x - rect.min_x + 1) as u64) * ((rect.max_y - rect.min_y + 1) as u64)
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
    }
}

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
            let tile = tiles.iter().find(|tile| tile.x == x && tile.y == y);
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
    let rect = normalize_rect(start_x, start_y, end_x, end_y)?;
    let colony = ctx
        .db
        .colony()
        .id()
        .find(0)
        .ok_or_else(|| "colony is not initialised".to_string())?;
    let tiles: Vec<_> = ctx.db.tile().iter().collect();
    let sim_tiles: Vec<_> = tiles.iter().map(to_sim_tile).collect();
    let ids = validate_empty_block(&sim_tiles, rect, kind, colony.wood)?;
    let cost = block_cost(rect);

    let mut updated_colony = colony;
    updated_colony.wood -= cost;
    ctx.db.colony().id().update(updated_colony);
    for id in ids {
        let mut tile = ctx
            .db
            .tile()
            .id()
            .find(id)
            .expect("validated tile disappeared");
        tile.kind = kind;
        tile.enabled = true;
        ctx.db.tile().id().update(tile);
    }
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
    let rect = normalize_rect(start_x, start_y, end_x, end_y)?;
    let tiles: Vec<_> = ctx.db.tile().iter().collect();
    let ids: Vec<_> = tiles
        .iter()
        .filter(|tile| {
            tile.kind != TileKind::Empty
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
    let rect = normalize_rect(start_x, start_y, end_x, end_y)?;
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
    fn rejects_invalid_rectangles_and_empty_builds() {
        assert!(normalize_rect(-1, 0, 1, 1).is_err());
        assert!(normalize_rect(0, 0, GRID_W, 0).is_err());
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
