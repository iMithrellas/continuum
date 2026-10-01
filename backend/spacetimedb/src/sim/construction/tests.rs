use super::*;
use crate::sim::{
    self,
    geometry::{AIR, STONE},
    World,
};

fn rect(x0: i32, y0: i32, x1: i32, y1: i32) -> BlockRect {
    BlockRect {
        min_x: x0,
        min_y: y0,
        max_x: x1,
        max_y: y1,
    }
}
fn tile(id: u32, x: i32, y: i32, z: i32) -> Tile {
    Tile {
        id,
        x,
        y,
        z,
        kind: TileKind::Empty,
        enabled: true,
        width: 1,
        depth: 1,
        clearance_height: 4,
    }
}

#[test]
fn huge_unaffordable_and_affordable_blocks_reject_before_geometry_or_row_planning() {
    let mut g = Geometry::flat_with_dimensions(256, 256).unwrap();
    g.chunks.clear();
    for max in [127, 255] {
        let area = rect(24, 24, max, max);
        let cost = area.cells().unwrap() as f32 * 20.0;
        assert_eq!(
            preflight_block(area, TileKind::Farm, 0.0).unwrap_err(),
            format!("building requires {cost} stored wood")
        );
        assert_eq!(
            plan_block(&g, &[], area, 0, TileKind::Farm, 0.0).unwrap_err(),
            format!("building requires {cost} stored wood")
        );
        let error = plan_block(&g, &[], area, 0, TileKind::Farm, f32::MAX).unwrap_err();
        assert!(error.contains("at most 4096 cells"));
        assert!(error.contains(&format!("requested {}", area.cells().unwrap())));
    }
    assert!(
        preflight_block(rect(24, 0, 40, 240), TileKind::Farm, f32::MAX)
            .unwrap_err()
            .contains("requested 4097")
    );
    for wood in [f32::NAN, f32::INFINITY, -1.0, 81919.0] {
        assert!(preflight_block(rect(24, 24, 87, 87), TileKind::Farm, wood).is_err());
    }
    assert!(preflight_block(rect(0, 0, 0, 0), TileKind::Empty, 20.0).is_err());
    assert!(preflight_block(rect(1, 0, 0, 0), TileKind::Farm, f32::MAX).is_err());
    assert!(rect(i32::MIN, i32::MIN, i32::MAX, i32::MAX)
        .cells()
        .is_err());
    assert!(
        plan_block(&g, &[], rect(24, 24, 87, 87), 0, TileKind::Farm, 81920.0)
            .unwrap_err()
            .contains("full clearance and solid support")
    );
}

#[test]
fn maximum_valid_block_is_a_bounded_delta_with_ascending_durable_ids() {
    let g = Geometry::seeded();
    let existing = sim::default_tiles();
    let original = existing.clone();
    let plan = plan_block(
        &g,
        &existing,
        rect(24, 24, 87, 87),
        0,
        TileKind::Farm,
        81920.0,
    )
    .unwrap();
    assert_eq!(plan.tiles.len(), MAX_ATOMIC_BUILD_CELLS as usize);
    assert_eq!(plan.cost, 81920.0);
    assert_eq!(plan.tiles.first().unwrap().id, 577);
    assert_eq!(plan.tiles.last().unwrap().id, 4672);
    assert!(plan.tiles.windows(2).all(|t| t[1].id == t[0].id + 1));
    assert_eq!(existing, original);
}

#[test]
fn late_support_or_headroom_failure_cannot_mutate_any_input_or_publish_partial_plan() {
    let existing = sim::default_tiles();
    for c in [Cell(87, 87, -1), Cell(87, 87, 3)] {
        let mut g = Geometry::seeded();
        g.set(c, if c.2 < 0 { AIR } else { STONE });
        let original = g.clone();
        assert!(plan_block(
            &g,
            &existing,
            rect(24, 24, 87, 87),
            0,
            TileKind::Sleep,
            81920.0
        )
        .is_err());
        assert_eq!(g, original);
    }
    let g = Geometry::seeded();
    assert!(plan_block(
        &g,
        &existing,
        rect(127, 127, 128, 127),
        0,
        TileKind::Sleep,
        40.0
    )
    .is_err());
    assert!(plan_block(
        &g,
        &existing,
        rect(24, 24, 24, 24),
        13,
        TileKind::Sleep,
        20.0
    )
    .is_err());
}

#[test]
fn reservation_interiors_and_partial_z_overlap_block_but_touching_faces_do_not() {
    let g = Geometry::seeded();
    let area = rect(24, 24, 25, 25);
    let mut room = tile(1000, 22, 25, 1);
    room.kind = TileKind::Dining;
    room.width = 3;
    room.depth = 2;
    room.clearance_height = 2;
    assert!(
        plan_block(&g, &[room.clone()], area, 0, TileKind::Sleep, 80.0)
            .unwrap_err()
            .contains("overlap")
    );
    room.width = 2;
    assert!(plan_block(&g, &[room.clone()], area, 0, TileKind::Sleep, 80.0).is_ok());
    room.width = 3;
    room.z = 4;
    assert!(plan_block(&g, &[room.clone()], area, 0, TileKind::Sleep, 80.0).is_ok());
    room.z = -1;
    assert!(plan_block(&g, &[room.clone()], area, 0, TileKind::Sleep, 80.0).is_err());
    room.kind = TileKind::Empty;
    assert!(plan_block(&g, &[room], area, 0, TileKind::Sleep, 80.0).is_ok());
}

#[test]
fn existing_base_anchors_are_reused_and_id_exhaustion_is_atomic() {
    let g = Geometry::seeded();
    let existing = vec![tile(17, 24, 24, 0), tile(42, 0, 0, -5), tile(3, 25, 24, -5)];
    let plan = plan_block(
        &g,
        &existing,
        rect(24, 24, 25, 25),
        0,
        TileKind::Sleep,
        80.0,
    )
    .unwrap();
    assert_eq!(
        plan.tiles.iter().map(|t| t.id).collect::<Vec<_>>(),
        [17, 43, 44, 45]
    );
    let exhausted = vec![tile(17, 24, 24, 0), tile(u32::MAX, 0, 0, 0)];
    assert_eq!(
        plan_block(
            &g,
            &exhausted,
            rect(24, 24, 25, 24),
            0,
            TileKind::Sleep,
            40.0
        )
        .unwrap_err(),
        "tile ID exhausted"
    );
    assert_eq!(
        plan_block(
            &g,
            &exhausted,
            rect(24, 24, 24, 24),
            0,
            TileKind::Sleep,
            20.0
        )
        .unwrap()
        .tiles[0]
            .id,
        17
    );
}

#[test]
fn all_576_legacy_cells_can_still_be_built_atomically_without_rekeying() {
    let g = Geometry::flat();
    let mut existing = sim::default_tiles();
    for t in &mut existing {
        t.kind = TileKind::Empty;
    }
    let plan = plan_block(
        &g,
        &existing,
        rect(0, 0, 23, 23),
        0,
        TileKind::Sleep,
        11520.0,
    )
    .unwrap();
    assert_eq!(plan.cost, 11520.0);
    assert_eq!(plan.tiles.len(), 576);
    for (old, new) in existing.iter().zip(&plan.tiles) {
        assert_eq!((new.id, new.x, new.y, new.z), (old.id, old.x, old.y, old.z));
        assert_eq!(new.kind, TileKind::Sleep);
    }
}

#[test]
fn maximum_request_indexes_a_preexisting_53824_row_region_instead_of_rescanning_it_per_cell() {
    let g = Geometry::flat_with_dimensions(256, 256).unwrap();
    let mut existing = sim::default_tiles();
    let mut id = 577;
    for y in 24..256 {
        for x in 24..256 {
            let mut t = tile(id, x, y, 0);
            if x > 87 || y > 87 {
                t.kind = TileKind::Farm;
            }
            existing.push(t);
            id += 1;
        }
    }
    let plan = plan_block(
        &g,
        &existing,
        rect(24, 24, 87, 87),
        0,
        TileKind::Farm,
        81920.0,
    )
    .unwrap();
    assert_eq!(plan.tiles.len(), 4096);
    assert_eq!(plan.tiles[0].id, 577);
    assert_eq!(plan.tiles[4095].id, 577 + 63 * 232 + 63);
    assert!(plan.tiles.iter().all(|t| t.id < id));
    assert_eq!(existing.len(), 576 + 53824);
}

fn reference(world: &World, area: BlockRect, z: i32, kind: TileKind) -> Result<Vec<Tile>, String> {
    let mut world = world.clone();
    let mut result = Vec::new();
    for y in area.min_y..=area.max_y {
        for x in area.min_x..=area.max_x {
            let mut t = tile(0, x, y, z);
            t.kind = kind;
            let g = world.geometry.as_ref().unwrap();
            if !g.supported(t.base(), t.body()) {
                return Err("unsupported".into());
            }
            for layer in z..z + 4 {
                if world
                    .tiles
                    .iter()
                    .any(|old| old.occupies(Cell(x, y, layer)))
                {
                    return Err("overlap".into());
                }
            }
            t.id = world.allocate_tile(t.base(), TileKind::Empty)?.id;
            *world.tiles.iter_mut().find(|old| old.id == t.id).unwrap() = t.clone();
            result.push(t);
        }
    }
    Ok(result)
}

#[test]
fn batch_planning_matches_the_original_sequential_voxel_reference() {
    let mut w = sim::new_world();
    let mut g = Geometry::seeded();
    for y in 6..12 {
        for x in 6..12 {
            for z in -5..=-2 {
                g.set(Cell(x, y, z), AIR);
            }
        }
    }
    w.geometry = Some(g);
    let mut room = tile(2000, 25, 25, 5);
    room.kind = TileKind::Dining;
    room.width = 2;
    room.depth = 3;
    room.clearance_height = 7;
    w.tiles.push(room);
    for reverse in [false, true] {
        if reverse {
            w.tiles.reverse();
        }
        for area in [
            rect(0, 0, 2, 0),
            rect(1, 1, 4, 4),
            rect(6, 6, 10, 10),
            rect(23, 8, 25, 8),
            rect(24, 24, 27, 27),
            rect(0, 0, 23, 23),
        ] {
            for z in [-5, 0, 1, 4, 12, 13] {
                let fast = plan_block(
                    w.geometry.as_ref().unwrap(),
                    &w.tiles,
                    area,
                    z,
                    TileKind::Sleep,
                    f32::MAX,
                );
                let slow = reference(&w, area, z, TileKind::Sleep);
                match (fast, slow) {
                    (Ok(a), Ok(b)) => assert_eq!(a.tiles, b),
                    (Err(_), Err(_)) => {}
                    other => panic!("reference mismatch {area:?} z={z}: {other:?}"),
                }
            }
        }
    }
}

#[test]
fn reservation_box_intersections_match_voxel_occupancy_for_all_small_footprints_and_heights() {
    let mut a = tile(1, 0, 0, 0);
    a.kind = TileKind::Sleep;
    a.width = 2;
    a.depth = 3;
    a.clearance_height = 5;
    for x in -2..=3 {
        for y in -2..=4 {
            for z in -7..=6 {
                for width in [0, 1, 2] {
                    for depth in [0, 1, 3] {
                        for height in [0, 1, 7] {
                            let mut b = tile(2, x, y, z);
                            b.kind = TileKind::Dining;
                            b.width = width;
                            b.depth = depth;
                            b.clearance_height = height;
                            let reference = (x..x + i32::from(width)).any(|px| {
                                (y..y + i32::from(depth)).any(|py| {
                                    (z..z + i32::from(height))
                                        .any(|pz| a.occupies(Cell(px, py, pz)))
                                })
                            });
                            assert_eq!(volumes_overlap(&a, &b), reference, "{b:?}");
                        }
                    }
                }
            }
        }
    }
}
