use crate::auth::{authorize, identity_hex, RequiredRole};
use crate::events::log_event;
use crate::schema::*;
use crate::sim::{validate_facility_build_in_bounds, TileKind, FACILITY_BUILD_WOOD_COST};
use spacetimedb::{reducer, ReducerContext, Table};

/// Enable or disable a single tile. Disabling recreation starts the failure chain.
#[reducer]
pub fn set_tile_enabled(ctx: &ReducerContext, tile_id: u32, enabled: bool) -> Result<(), String> {
    authorize(ctx, RequiredRole::Operator)?;
    let mut tile = ctx
        .db
        .tile()
        .id()
        .find(tile_id)
        .ok_or_else(|| format!("no such tile: {tile_id}"))?;
    if tile.kind == TileKind::Empty {
        return Err("empty tiles cannot be enabled or disabled".into());
    }
    if tile.enabled == enabled {
        return Ok(());
    }
    tile.enabled = enabled;
    let kind = tile.kind;
    let (x, y) = (tile.x, tile.y);
    ctx.db.tile().id().update(tile);
    log_event(
        ctx,
        Severity::Info,
        format!(
            "{:?} tile ({x},{y}) was {} by operator {}",
            kind,
            if enabled { "enabled" } else { "disabled" },
            identity_hex(ctx.sender())
        ),
    );
    Ok(())
}

/// Instantly turn an empty grid tile into a needs facility.
/// Deprecated compatibility placement: charges for usage, not physical construction.
/// New clients should call construct_room and designate_zone_at independently.
#[reducer]
pub fn build_facility(ctx: &ReducerContext, tile_id: u32, kind: TileKind) -> Result<(), String> {
    authorize(ctx, RequiredRole::Operator)?;
    let mut tile = ctx
        .db
        .tile()
        .id()
        .find(tile_id)
        .ok_or_else(|| format!("no such tile: {tile_id}"))?;
    let mut colony = ctx
        .db
        .colony()
        .id()
        .find(0)
        .ok_or_else(|| "colony is not initialised".to_string())?;
    if tile.z != 0 {
        return Err("legacy build_facility only targets z=0".into());
    }
    let world = crate::persistence::load_world(ctx);
    let mut placement = world
        .tiles
        .iter()
        .find(|t| t.id == tile_id)
        .unwrap()
        .clone();
    placement.kind = kind;
    world.validate_placement(&placement)?;
    let geometry = world.geometry.as_ref().unwrap();
    validate_facility_build_in_bounds(
        &crate::sim::Tile {
            id: tile.id,
            x: tile.x,
            y: tile.y,
            kind: tile.kind,
            enabled: tile.enabled,
            z: tile.z,
            width: tile.width,
            depth: tile.depth,
            clearance_height: tile.clearance_height,
        },
        kind,
        colony.wood,
        geometry.width,
        geometry.height,
    )?;
    colony.wood -= FACILITY_BUILD_WOOD_COST;
    tile.kind = kind;
    tile.enabled = true;
    ctx.db.colony().id().update(colony);
    ctx.db.tile().id().update(tile);
    log_event(
        ctx,
        Severity::Info,
        format!(
            "Built {kind:?} facility on tile {tile_id} for {:.0} stored wood by operator {}.",
            FACILITY_BUILD_WOOD_COST,
            identity_hex(ctx.sender())
        ),
    );
    Ok(())
}

/// Enable or disable every tile of a kind at once.
#[reducer]
pub fn set_zone_enabled(ctx: &ReducerContext, kind: TileKind, enabled: bool) -> Result<(), String> {
    authorize(ctx, RequiredRole::Operator)?;
    if kind == TileKind::Empty {
        return Err("empty tiles cannot be enabled or disabled".into());
    }
    let mut changed = 0u32;
    for mut tile in ctx
        .db
        .tile()
        .iter()
        .filter(|tile| tile.kind == kind && tile.z == 0)
    {
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
                "{:?} zone was {} by operator {} ({changed} tiles)",
                kind,
                if enabled { "enabled" } else { "disabled" },
                identity_hex(ctx.sender())
            ),
        );
    }
    Ok(())
}
