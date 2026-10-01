use crate::auth::{authorize, RequiredRole};
use crate::persistence;
use crate::schema::*;
use crate::sim::construction::{self, validate_cost};
use crate::sim::{self, TileKind, WorkType, FACILITY_BUILD_WOOD_COST};
use spacetimedb::{reducer, ReducerContext, Table};

#[reducer]
#[allow(clippy::too_many_arguments)]
pub fn designate_excavation(
    ctx: &ReducerContext,
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
    bottom_z: i32,
    height: u16,
    priority: u8,
) -> Result<(), String> {
    authorize(ctx, RequiredRole::Operator)?;
    let world = persistence::load_world(ctx);
    let d = world
        .geometry
        .as_ref()
        .unwrap()
        .designate(0, x0, y0, x1, y1, bottom_z, height, priority)?;
    persistence::insert_designation(ctx, &d);
    Ok(())
}

#[reducer]
pub fn set_excavation_enabled(ctx: &ReducerContext, id: u64, enabled: bool) -> Result<(), String> {
    authorize(ctx, RequiredRole::Operator)?;
    let mut d = ctx
        .db
        .excavation_designation()
        .id()
        .find(id)
        .ok_or("no such excavation")?;
    d.enabled = enabled;
    ctx.db.excavation_designation().id().update(d);
    Ok(())
}

#[reducer]
pub fn cancel_excavation(ctx: &ReducerContext, id: u64) -> Result<(), String> {
    authorize(ctx, RequiredRole::Operator)?;
    if ctx.db.excavation_designation().id().find(id).is_none() {
        return Err("no such excavation".into());
    }
    ctx.db.excavation_designation().id().delete(id);
    ctx.db.excavation_jobs().id().delete(id);
    Ok(())
}

fn commit_build(ctx: &ReducerContext, world: &sim::World, cost: f32) -> Result<(), String> {
    let mut colony = ctx.db.colony().id().find(0).ok_or("colony missing")?;
    validate_cost(colony.wood, cost)?;
    colony.wood -= cost;
    // All validations are complete before either cost or entity writes.
    ctx.db.colony().id().update(colony);
    persistence::save_geometry_and_tiles(ctx, world);
    Ok(())
}

#[cfg(test)]
fn plan_block(
    world: &sim::World,
    rect: crate::blocks::Rect,
    z: i32,
    kind: TileKind,
) -> Result<(sim::World, f32), String> {
    let plan = construction::plan_block(
        world.geometry.as_ref().ok_or("live geometry missing")?,
        &world.tiles,
        rect,
        z,
        kind,
        f32::MAX,
    )?;
    let mut changes: std::collections::BTreeMap<_, _> =
        plan.tiles.into_iter().map(|t| (t.id, t)).collect();
    let mut planned = world.clone();
    for existing in &mut planned.tiles {
        if let Some(tile) = changes.remove(&existing.id) {
            *existing = tile;
        }
    }
    planned.tiles.extend(changes.into_values());
    Ok((planned, plan.cost))
}

fn planned_tile(
    world: &sim::World,
    x: i32,
    y: i32,
    z: i32,
    kind: TileKind,
    width: u16,
    depth: u16,
    height: u16,
) -> Result<sim::Tile, String> {
    let tile = sim::Tile {
        id: 0,
        x,
        y,
        z,
        kind,
        enabled: true,
        width,
        depth,
        clearance_height: height,
    };
    world.validate_placement(&tile)?;
    Ok(tile)
}

fn install_tile(world: &mut sim::World, mut tile: sim::Tile) -> Result<(), String> {
    tile.id = world.allocate_tile(tile.base(), TileKind::Empty)?.id;
    let existing = world.tiles.iter_mut().find(|t| t.id == tile.id).unwrap();
    *existing = tile;
    Ok(())
}

#[reducer]
#[allow(clippy::too_many_arguments)]
pub fn place_facility(
    ctx: &ReducerContext,
    x: i32,
    y: i32,
    z: i32,
    kind: TileKind,
    width: u16,
    depth: u16,
    clearance_height: u16,
) -> Result<(), String> {
    authorize(ctx, RequiredRole::Operator)?;
    let cost = FACILITY_BUILD_WOOD_COST * f32::from(width) * f32::from(depth);
    let wood = ctx.db.colony().id().find(0).ok_or("colony missing")?.wood;
    validate_cost(wood, cost)?;
    let mut world = persistence::load_world(ctx);
    let tile = planned_tile(&world, x, y, z, kind, width, depth, clearance_height)?;
    install_tile(&mut world, tile)?;
    commit_build(ctx, &world, cost)
}

/// Build one atomic inclusive rectangle of at most 4096 cells. Cost/size rejection
/// precedes world loading; placement failure neither charges wood nor saves a
/// partial block. Excavation designation sizes are unaffected.
#[reducer]
#[allow(clippy::too_many_arguments)]
pub fn build_tile_block_at(
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
    let mut colony = ctx.db.colony().id().find(0).ok_or("colony missing")?;
    // Reject unaffordable and oversized intents before loading any geometry,
    // actors, job vectors or tiles. The pure planner also guards direct callers.
    construction::preflight_block(rect, kind, colony.wood)?;
    let world = persistence::load_world(ctx);
    let plan = construction::plan_block(
        world.geometry.as_ref().unwrap(),
        &world.tiles,
        rect,
        z,
        kind,
        colony.wood,
    )?;
    colony.wood -= plan.cost;
    ctx.db.colony().id().update(colony);
    persistence::save_tiles(ctx, &plan.tiles);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use sim::geometry::{Cell, Geometry, AIR};
    #[test]
    fn block_plan_is_atomic_on_late_failure_and_cost_is_validated_as_a_whole() {
        let mut w = sim::new_world();
        w.geometry = Some(Geometry::flat());
        // First cells are empty but the last overlaps the seeded dining room.
        let original = w.clone();
        let rect = crate::blocks::normalize_rect(0, 2, 2, 2).unwrap();
        assert!(plan_block(&w, rect, 0, TileKind::Dining).is_err());
        assert_eq!(w, original);
        let rect = crate::blocks::normalize_rect(0, 0, 2, 0).unwrap();
        let (planned, cost) = plan_block(&w, rect, 0, TileKind::Dining).unwrap();
        assert_eq!(cost, 60.0);
        assert_eq!(w, original);
        assert!(validate_cost(59.9, cost).is_err());
        assert!(validate_cost(f32::NAN, cost).is_err());
        assert!(validate_cost(f32::INFINITY, cost).is_err());
        assert!(validate_cost(60.0, cost).is_ok());
        assert_eq!(
            planned
                .tiles
                .iter()
                .filter(|t| t.y == 0 && t.x <= 2 && t.z == 0 && t.kind == TileKind::Dining)
                .count(),
            3
        );
    }
    #[test]
    fn elevated_block_allocates_ids_and_never_changes_old_base_layer_rows() {
        let mut w = sim::new_world();
        let mut g = Geometry::flat();
        for x in 0..2 {
            for z in -5..=-2 {
                g.set(Cell(x, 0, z), AIR);
            }
        }
        w.geometry = Some(g);
        let (planned, cost) = plan_block(
            &w,
            crate::blocks::normalize_rect(0, 0, 1, 0).unwrap(),
            -5,
            TileKind::Sleep,
        )
        .unwrap();
        assert_eq!(cost, 40.0);
        for t in &w.tiles {
            assert_eq!(planned.tiles.iter().find(|p| p.id == t.id), Some(t));
        }
        let elevated: Vec<_> = planned.tiles.iter().filter(|t| t.z == -5).collect();
        assert_eq!(elevated.len(), 2);
        assert!(elevated
            .iter()
            .all(|t| t.id > 576 && t.kind == TileKind::Sleep));
    }

    #[test]
    fn sparse_new_land_builds_on_demand_without_inert_rows_or_id_reuse() {
        let mut w = sim::new_world();
        w.geometry = Some(Geometry::seeded());
        let original = w.tiles.clone();
        let rect = crate::blocks::Rect {
            min_x: 126,
            min_y: 127,
            max_x: 127,
            max_y: 127,
        };
        let (planned, cost) = plan_block(&w, rect, 0, TileKind::Dining).unwrap();
        assert_eq!(cost, 40.0);
        assert_eq!(planned.tiles.len(), 578);
        assert_eq!(&planned.tiles[..576], original);
        assert_eq!(planned.tiles[576].id, 577);
        assert_eq!(planned.tiles[577].id, 578);
        sim::validate_facility_build_in_bounds(
            &sim::Tile {
                kind: TileKind::Empty,
                ..planned.tiles[576].clone()
            },
            TileKind::Sleep,
            20.0,
            128,
            128,
        )
        .unwrap();
        assert!(planned
            .validate_placement(&sim::Tile {
                x: 128,
                ..planned.tiles[576].clone()
            })
            .is_err());
        assert!(planned
            .validate_placement(&sim::Tile {
                width: 2,
                ..planned.tiles[577].clone()
            })
            .is_err());
    }
}

#[reducer]
#[allow(clippy::too_many_arguments)]
pub fn set_tile_block_enabled_at(
    ctx: &ReducerContext,
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
    z: i32,
    enabled: bool,
) -> Result<(), String> {
    authorize(ctx, RequiredRole::Operator)?;
    let rect = crate::blocks::reducer_rect(ctx, x0, y0, x1, y1)?;
    crate::blocks::validate_elevation(ctx, z)?;
    let tiles: Vec<_> = ctx
        .db
        .tile()
        .iter()
        .filter(|t| {
            t.z == z
                && t.kind != TileKind::Empty
                && t.x >= rect.min_x
                && t.x <= rect.max_x
                && t.y >= rect.min_y
                && t.y <= rect.max_y
        })
        .collect();
    if tiles.is_empty() {
        return Err("rectangle contains no facilities at elevation".into());
    }
    for mut t in tiles {
        t.enabled = enabled;
        ctx.db.tile().id().update(t);
    }
    Ok(())
}

#[reducer]
#[allow(clippy::too_many_arguments)]
pub fn set_block_work_order_at(
    ctx: &ReducerContext,
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
    z: i32,
    work: WorkType,
    priority: u8,
    enabled: bool,
) -> Result<(), String> {
    authorize(ctx, RequiredRole::Operator)?;
    let rect = crate::blocks::reducer_rect(ctx, x0, y0, x1, y1)?;
    crate::blocks::validate_elevation(ctx, z)?;
    if !(1..=3).contains(&priority) {
        return Err("priority must be 1..=3".into());
    }
    let definition = work.definition().ok_or("producing job required")?;
    let tiles: Vec<_> = ctx
        .db
        .tile()
        .iter()
        .filter(|t| {
            t.z == z
                && t.kind == definition.facility
                && t.x >= rect.min_x
                && t.x <= rect.max_x
                && t.y >= rect.min_y
                && t.y <= rect.max_y
        })
        .collect();
    if tiles.is_empty() {
        return Err("rectangle contains no compatible facilities at elevation".into());
    }
    for t in tiles {
        super::work_orders::set_work_order(ctx, t.id, work, priority, enabled)?;
    }
    Ok(())
}

#[reducer]
pub fn configure_colonist_body(
    ctx: &ReducerContext,
    id: u64,
    width: u16,
    depth: u16,
    clearance_height: u16,
    max_step_height: u16,
) -> Result<(), String> {
    authorize(ctx, RequiredRole::Operator)?;
    let world = persistence::load_world(ctx);
    let mut c = ctx.db.colonist().id().find(id).ok_or("no such colonist")?;
    let body = sim::geometry::Body {
        width,
        depth,
        height: clearance_height,
        step: max_step_height,
    };
    if !world
        .geometry
        .as_ref()
        .unwrap()
        .supported(sim::geometry::Cell(c.x, c.y, c.z), body)
    {
        return Err("body lacks clearance/support".into());
    }
    c.body_width = width;
    c.body_depth = depth;
    c.clearance_height = clearance_height;
    c.max_step_height = max_step_height;
    c.move_progress = 0.0;
    c.next_x = c.x;
    c.next_y = c.y;
    c.next_z = c.z;
    ctx.db.colonist().id().update(c);
    Ok(())
}
