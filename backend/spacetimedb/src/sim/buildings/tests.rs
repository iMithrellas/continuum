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

#[test]
fn unrepresentable_room_debits_reject_without_mutating_planning_inputs() {
    let geometry = Geometry::flat();
    let existing = Vec::new();
    let before = (geometry.clone(), existing.clone());
    let r = rect(0, 0, 0, 0);
    for wood in [67_108_864.0, 268_435_456.0, f32::MAX] {
        let error = preflight_room(r, 6, wood).unwrap_err();
        assert!(error.contains("Cannot charge exactly 5 stored wood"));
        assert!(error.contains("no wood was spent"));
        assert!(plan_room(&geometry, &existing, r, 0, 6, wood).is_err());
        assert_eq!((geometry.clone(), existing.clone()), before);
    }
    let (room, cost) =
        plan_room(&geometry, &existing, rect(0, 0, 1, 1), 0, 6, 67_108_864.0).unwrap();
    assert_eq!((room.width, room.depth, cost), (2, 2, 20.0));
    let remainder = checked_room_wood_remainder(67_108_864.0, cost).unwrap();
    assert_eq!(remainder, 67_108_844.0);
    assert_eq!(67_108_864.0_f64 - f64::from(remainder), 20.0);
}

#[test]
fn every_room_area_accepts_exact_fractional_debits_and_rejects_invalid_stocks() {
    for area in 1..=4096 {
        let r = rect(0, 0, area - 1, 0);
        let cost = area as f32 * 5.0;
        assert_eq!(f64::from(cost), f64::from(area) * 5.0);
        for extra in [0.0, 0.125, 0.25, 0.5, 100.75, 65_536.125] {
            let wood = cost + extra;
            assert_eq!(preflight_room(r, 4, wood).unwrap(), cost);
            let remainder = checked_room_wood_remainder(wood, cost).unwrap();
            assert_eq!(remainder, extra);
            assert_eq!(f64::from(wood) - f64::from(remainder), f64::from(cost));
        }
        let just_insufficient = f32::from_bits(cost.to_bits() - 1);
        for wood in [
            just_insufficient,
            -1.0,
            f32::NAN,
            f32::INFINITY,
            f32::NEG_INFINITY,
            f32::MAX,
        ] {
            assert!(
                preflight_room(r, 4, wood).is_err(),
                "area={area}, wood={wood}"
            );
            assert!(checked_room_wood_remainder(wood, cost).is_err());
        }
    }
}

#[test]
fn every_area_checks_fractional_and_large_ulp_boundary_stocks_without_overcharge() {
    let mut accepted = 0;
    let mut rejected = 0;
    for area in 1..=4096 {
        let r = rect(0, 0, area - 1, 0);
        let cost = area as f32 * 5.0;
        for exponent in [16, 20, 21, 22, 23, 24, 26, 28] {
            let boundary = 2.0_f32.powi(exponent);
            for offset in -2..=2 {
                let wood = f32::from_bits((i64::from(boundary.to_bits()) + offset) as u32);
                let candidate = wood - cost;
                let exact_debit = f64::from(wood) - f64::from(candidate);
                let result = checked_room_wood_remainder(wood, cost);
                if exact_debit == f64::from(cost) {
                    accepted += 1;
                    let remainder = result.unwrap();
                    assert_eq!(remainder.to_bits(), candidate.to_bits());
                    assert_eq!(f64::from(wood) - f64::from(remainder), f64::from(cost));
                    assert_eq!(preflight_room(r, 4, wood).unwrap(), cost);
                } else {
                    rejected += 1;
                    assert!(
                        result.is_err(),
                        "area={area}, wood={wood}, debit={exact_debit}"
                    );
                    assert!(preflight_room(r, 4, wood).is_err());
                }
            }
        }
    }
    assert!(accepted > 0 && rejected > 0);
    assert_eq!(16_777_248.0_f32 - (16_777_248.0_f32 - 5.0), 4.0);
    assert!(checked_room_wood_remainder(16_777_248.0, 5.0).is_err());
    assert_eq!(16_777_250.0_f32 - (16_777_250.0_f32 - 5.0), 6.0);
    assert!(checked_room_wood_remainder(16_777_250.0, 5.0).is_err());
}
