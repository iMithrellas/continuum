use crate::auth::{authorize, RequiredRole};
use crate::persistence;
use crate::schema::*;
use crate::sim::buildings::{plan_room, preflight_room, ROOM_THERMAL_RESISTANCE};
use spacetimedb::{reducer, ReducerContext, Table};

/// Construct a traversable insulation envelope, not voxel walls or a usage zone.
#[reducer]
pub fn construct_room(
    ctx: &ReducerContext,
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
    z: i32,
    clearance_height: u16,
) -> Result<(), String> {
    authorize(ctx, RequiredRole::Operator)?;
    let rect = crate::blocks::reducer_rect(ctx, x0, y0, x1, y1)?;
    crate::blocks::validate_elevation(ctx, z)?;
    let mut colony = ctx.db.colony().id().find(0).ok_or("colony missing")?;
    preflight_room(rect, clearance_height, colony.wood)?;
    let geometry = persistence::load_placement_geometry(ctx, rect);
    let (room, cost) = plan_room(
        &geometry,
        &persistence::load_buildings(ctx),
        rect,
        z,
        clearance_height,
        colony.wood,
    )?;
    let building = ctx.db.building().insert(Building {
        id: 0,
        kind: BuildingKind::InsulatedRoom,
        x: room.base.0,
        y: room.base.1,
        z: room.base.2,
        width: room.width,
        depth: room.depth,
        clearance_height: room.height,
        wood_cost: cost,
    });
    ctx.db
        .building_thermal_property()
        .insert(BuildingThermalProperty {
            building_id: building.id,
            thermal_resistance_m2_k_per_w: ROOM_THERMAL_RESISTANCE,
        });
    colony.wood -= cost;
    ctx.db.colony().id().update(colony);
    Ok(())
}

/// Removes only construction capabilities; no zone edits, goods loss or refunds.
#[reducer]
pub fn demolish_building(ctx: &ReducerContext, building_id: u64) -> Result<(), String> {
    authorize(ctx, RequiredRole::Operator)?;
    if ctx.db.building().id().find(building_id).is_none() {
        return Err("no such building".into());
    }
    ctx.db
        .building_thermal_property()
        .building_id()
        .delete(building_id);
    ctx.db.building().id().delete(building_id);
    Ok(())
}
