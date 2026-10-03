use super::*;
use crate::sim::geometry::{AIR, STONE};
use crate::sim::{self, stack_id, ResourceKind};

fn rect(x0: i32, y0: i32, x1: i32, y1: i32) -> BlockRect {
    BlockRect {
        min_x: x0,
        min_y: y0,
        max_x: x1,
        max_y: y1,
    }
}

#[test]
fn free_zone_preserves_ids_enablement_and_inputs() {
    let g = Geometry::flat();
    let world = sim::new_world();
    let original = world.clone();
    let r = rect(0, 0, 1, 1);
    let mut plan = plan_zone(&g, &world.tiles, r, 0, TileKind::Storage).unwrap();
    assert_eq!(world, original);
    assert_eq!(
        plan.iter().map(|t| t.id).collect::<Vec<_>>(),
        vec![1, 2, 25, 26]
    );
    plan[0].enabled = false;
    assert_eq!(plan_zone(&g, &plan, r, 0, TileKind::Storage).unwrap(), plan);
    assert!(plan_zone(&g, &plan, r, 0, TileKind::Farm).is_err());
    let cleared = cleared_zone(&plan[0]);
    assert_eq!(cleared_zone(&cleared), cleared);
    let rezone = plan_zone(&g, &[cleared], rect(0, 0, 0, 0), 0, TileKind::Farm).unwrap();
    assert_eq!(rezone[0].id, 1);
    assert_eq!(
        stack_id(rezone[0].id, ResourceKind::Wood),
        stack_id(plan[0].id, ResourceKind::Wood)
    );
}

#[test]
fn conflicting_legacy_volumes_and_hidden_layers_are_not_overwritten() {
    let mut g = Geometry::flat();
    let tile = Tile {
        id: 90,
        x: 0,
        y: 0,
        z: 0,
        kind: TileKind::Storage,
        enabled: false,
        width: 2,
        depth: 2,
        clearance_height: 6,
    };
    assert!(plan_zone(&g, &[tile.clone()], rect(1, 1, 1, 1), 0, TileKind::Storage).is_err());
    assert!(plan_zone(&g, &[tile.clone()], rect(1, 1, 1, 1), 4, TileKind::Farm).is_err());
    for z in -5..=-2 {
        g.set(Cell(0, 0, z), AIR);
    }
    let plan = plan_zone(&g, &[tile.clone()], rect(0, 0, 0, 0), -5, TileKind::Storage).unwrap();
    assert_eq!(plan[0].id, 91);
    assert_eq!(tile.z, 0);
    assert_eq!(tile.width, 2);
    let short = Tile {
        width: 1,
        depth: 1,
        clearance_height: 1,
        ..tile
    };
    assert!(plan_zone(&g, &[short], rect(0, 0, 0, 0), 0, TileKind::Storage).is_err());
}

#[test]
fn invalid_geometry_and_late_failure_leave_all_inputs_unchanged() {
    let mut g = Geometry::flat();
    let tiles = sim::default_tiles();
    let r = rect(0, 0, 1, 1);
    for kind in [TileKind::Empty] {
        assert!(plan_zone(&g, &tiles, r, 0, kind).is_err());
    }
    for z in [i32::MAX, -16, 13] {
        assert!(plan_zone(&g, &tiles, r, z, TileKind::Storage).is_err());
    }
    assert!(plan_zone(&g, &tiles, rect(0, 0, 64, 64), 0, TileKind::Storage).is_err());
    g.set(Cell(1, 1, 3), STONE);
    let before = (g.clone(), tiles.clone());
    assert!(plan_zone(&g, &tiles, r, 0, TileKind::Storage).is_err());
    assert_eq!((g.clone(), tiles.clone()), before);
    g.set(Cell(1, 1, 3), AIR);
    g.set(Cell(1, 1, -1), AIR);
    assert!(plan_zone(&g, &tiles, r, 0, TileKind::Storage).is_err());
}

#[test]
fn sparse_allocation_checks_id_exhaustion_and_never_reuses_retained_ids() {
    let g = Geometry::flat_with_dimensions(128, 128).unwrap();
    let mut tiles = sim::default_tiles();
    let r = rect(126, 127, 127, 127);
    let plan = plan_zone(&g, &tiles, r, 0, TileKind::Forest).unwrap();
    assert_eq!(
        plan.iter().map(|t| t.id).collect::<Vec<_>>(),
        vec![577, 578]
    );
    tiles.extend(plan.iter().map(cleared_zone));
    assert_eq!(plan_zone(&g, &tiles, r, 0, TileKind::Forest).unwrap(), plan);
    tiles[0].id = u32::MAX;
    assert!(plan_zone(&g, &tiles, rect(100, 100, 100, 100), 0, TileKind::Storage).is_err());
}

#[test]
fn maximum_free_designation_is_a_bounded_delta_and_old_rows_are_order_independent() {
    let g = Geometry::flat_with_dimensions(128, 128).unwrap();
    let r = rect(32, 32, 95, 95);
    let mut old = sim::default_tiles();
    let plan = plan_zone(&g, &old, r, 0, TileKind::Storage).unwrap();
    assert_eq!(plan.len(), 4096);
    assert_eq!(plan.first().unwrap().id, 577);
    assert_eq!(plan.last().unwrap().id, 4672);
    old.reverse();
    assert_eq!(plan_zone(&g, &old, r, 0, TileKind::Storage).unwrap(), plan);
    assert!(plan_zone(&g, &old, rect(32, 32, 96, 95), 0, TileKind::Storage).is_err());
}
