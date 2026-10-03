use super::*;
use crate::sim::geometry::{AIR, STONE};
use crate::sim::{self, designations, TileKind};

fn rect(x0: i32, y0: i32, x1: i32, y1: i32) -> BlockRect {
    BlockRect {
        min_x: x0,
        min_y: y0,
        max_x: x1,
        max_y: y1,
    }
}

#[test]
fn cost_property_and_full_volume_validation_are_atomic() {
    let mut g = Geometry::flat();
    let r = rect(0, 0, 1, 1);
    let original = g.clone();
    let (room, cost) = plan_room(&g, &[], r, 0, 6, 20.0).unwrap();
    assert_eq!(cost, 20.0);
    assert_eq!(room.thermal_resistance, Some(2.0));
    assert_eq!(g, original);
    for wood in [19.99, f32::NAN, f32::INFINITY, f32::NEG_INFINITY] {
        assert!(plan_room(&g, &[], r, 0, 6, wood).is_err());
    }
    for height in [0, 3, 17, u16::MAX] {
        assert!(plan_room(&g, &[], r, 0, height, 20.0).is_err());
    }
    for (r, z) in [
        (rect(-1, 0, 0, 0), 0),
        (rect(23, 0, 24, 0), 0),
        (rect(0, 0, 0, 0), i32::MAX),
        (rect(0, 0, 0, 0), -16),
    ] {
        assert!(plan_room(&g, &[], r, z, 4, 100.0).is_err());
    }
    g.set(Cell(1, 1, 5), STONE);
    let blocked = g.clone();
    assert!(plan_room(&g, &[], r, 0, 6, 20.0).is_err());
    assert_eq!(g, blocked);
    g.set(Cell(1, 1, 5), AIR);
    g.set(Cell(1, 1, -1), AIR);
    assert!(plan_room(&g, &[], r, 0, 6, 20.0).is_err());
    assert!(preflight_room(rect(0, 0, 64, 64), 4, f32::MAX).is_err());
    assert!(preflight_room(rect(i32::MIN, 0, i32::MAX, 0), 4, f32::MAX).is_err());
}

#[test]
fn rooms_overlap_only_other_rooms_and_query_exact_half_open_volume() {
    let mut world = sim::new_world();
    let g = Geometry::flat();
    let r = rect(0, 0, 1, 1);
    let (mut room, _) = plan_room(&g, &[], r, 0, 6, 20.0).unwrap();
    room.id = 41;
    world.buildings.push(room.clone());
    assert_eq!(world.room_thermal_resistance_at(Cell(1, 1, 5)), Some(2.0));
    for p in [Cell(2, 1, 0), Cell(1, 2, 0), Cell(1, 1, 6), Cell(1, 1, -1)] {
        assert_eq!(world.room_thermal_resistance_at(p), None);
    }
    assert!(plan_room(&g, &world.buildings, r, 0, 6, 20.0).is_err());
    assert!(plan_room(&g, &world.buildings, rect(2, 0, 3, 1), 0, 6, 20.0).is_ok());
    let mut upper = room.clone();
    upper.base.2 = 6;
    assert!(!room.overlaps(&upper));
    upper.base.2 = 5;
    assert!(room.overlaps(&upper));
    world.buildings[0].thermal_resistance = None;
    assert_eq!(world.room_thermal_resistance_at(Cell(0, 0, 0)), None);
}

#[test]
fn room_and_storage_work_in_either_creation_order_and_clear_is_independent() {
    let mut world = sim::new_world();
    let g = Geometry::flat();
    let r = rect(0, 0, 1, 1);
    let zones_first = designations::plan_zone(&g, &world.tiles, r, 0, TileKind::Storage).unwrap();
    let (room_after, _) = plan_room(&g, &[], r, 0, 6, 20.0).unwrap();
    let (room_first, _) = plan_room(&g, &[], r, 0, 6, 20.0).unwrap();
    world.buildings.push(room_first.clone());
    let zones_after = designations::plan_zone(&g, &world.tiles, r, 0, TileKind::Storage).unwrap();
    assert_eq!(room_after, room_first);
    assert_eq!(zones_first, zones_after);
    let cleared = designations::cleared_zone(&zones_after[0]);
    assert_eq!(cleared.id, zones_after[0].id);
    assert_eq!(world.room_thermal_resistance_at(Cell(0, 0, 0)), Some(2.0));
    world.buildings.clear();
    assert_eq!(zones_after[0].kind, TileKind::Storage);
}

#[test]
fn room_support_is_protected_without_changing_navigation() {
    let mut world = sim::new_world();
    let g = Geometry::flat();
    let (room, _) = plan_room(&g, &[], rect(0, 0, 1, 1), 0, 6, 20.0).unwrap();
    world.geometry = Some(g);
    assert!(!world.cell_protected(Cell(1, 1, -1)));
    let before = world.actor_reachability(0).get(&Cell(1, 1, 0));
    assert!(before.is_some());
    world.buildings.push(room);
    assert!(world.cell_protected(Cell(1, 1, -1)));
    assert!(!world.cell_protected(Cell(2, 1, -1)));
    assert_eq!(world.actor_reachability(0).get(&Cell(1, 1, 0)), before);
    world.buildings.clear();
    assert!(!world.cell_protected(Cell(1, 1, -1)));
}

#[test]
fn maximum_room_has_one_envelope_and_exact_cost_not_per_cell_entities() {
    let g = Geometry::flat_with_dimensions(128, 128).unwrap();
    let r = rect(32, 32, 95, 95);
    let (room, cost) = plan_room(&g, &[], r, 0, 6, 20_480.0).unwrap();
    assert_eq!((room.width, room.depth, room.height), (64, 64, 6));
    assert_eq!(cost, 20_480.0);
    assert!(plan_room(&g, &[], r, 0, 6, cost - 1.0).is_err());
    assert!(plan_room(&g, &[], rect(32, 32, 96, 95), 0, 6, f32::MAX).is_err());
}
