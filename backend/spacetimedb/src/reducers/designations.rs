use crate::auth::{authorize, RequiredRole};
use crate::persistence;
use crate::schema::*;
use crate::sim::designations::{cleared_zone, plan_zone, preflight_zone};
use crate::sim::TileKind;
use spacetimedb::{reducer, ReducerContext, Table};

/// Free usage intent. Construction and its properties are independent authority.
#[reducer]
pub fn designate_zone_at(
    ctx: &ReducerContext,
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
    z: i32,
    kind: TileKind,
) -> Result<(), String> {
    authorize(ctx, RequiredRole::Operator)?;
    let rect = crate::blocks::reducer_rect(ctx, x0, y0, x1, y1)?;
    crate::blocks::validate_elevation(ctx, z)?;
    preflight_zone(rect, kind)?;
    let geometry = persistence::load_placement_geometry(ctx, rect);
    let tiles: Vec<_> = ctx.db.tile().iter().map(persistence::tile_state).collect();
    let plan = plan_zone(&geometry, &tiles, rect, z, kind)?;
    persistence::save_tiles(ctx, &plan);
    Ok(())
}

/// Clear usage while retaining durable anchor/stack IDs and unrelated buildings.
#[reducer]
pub fn clear_zone(ctx: &ReducerContext, tile_id: u32) -> Result<(), String> {
    authorize(ctx, RequiredRole::Operator)?;
    let tile = ctx.db.tile().id().find(tile_id).ok_or("no such tile")?;
    let cleared = cleared_zone(&persistence::tile_state(tile));
    let orders: Vec<_> = ctx
        .db
        .work_order()
        .iter()
        .filter(|order| order.tile_id == tile_id)
        .map(|order| order.id)
        .collect();
    for id in orders {
        ctx.db.work_order().id().delete(id);
    }
    persistence::save_tiles(ctx, &[cleared]);
    Ok(())
}
