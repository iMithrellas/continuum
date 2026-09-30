use super::*;

fn small() -> Geometry {
    let mut g = Geometry::flat();
    g.width = 8;
    g.height = 8;
    g
}

#[test]
fn chunk_flattening_and_negative_euclidean_coordinates_are_exact() {
    assert_eq!(chunk_address(Cell(15, 15, 15)), (Cell(0, 0, 0), 4095));
    assert_eq!(chunk_address(Cell(16, 0, 0)), (Cell(1, 0, 0), 0));
    assert_eq!(chunk_address(Cell(0, 0, -1)), (Cell(0, 0, -1), 3840));
    assert_eq!(chunk_address(Cell(-1, -17, -16)), (Cell(-1, -2, -1), 255));
    assert_eq!(CELL_VOLUME_M3, 0.5 * 0.5 * 0.5);
}

#[test]
fn flat_migration_preserves_all_z_zero_support_and_four_cell_clearance() {
    let g = Geometry::flat();
    assert_eq!((g.width, g.height, g.min_z, g.max_z), (24, 24, -16, 15));
    for x in 0..24 {
        for y in 0..24 {
            assert!(g.supported(Cell(x, y, 0), Body::default()));
            assert_eq!(g.material(Cell(x, y, -1)), Some(SOIL));
            assert_eq!(g.material(Cell(x, y, -2)), Some(STONE));
        }
    }
    assert_eq!(g.chunks.len(), 8);
    assert!(g.changed.is_empty());
}

#[test]
fn writes_dirty_only_changed_chunks_and_increment_revision_once_per_transaction() {
    let mut g = Geometry::flat();
    assert!(g.set(Cell(1, 1, 0), STONE));
    assert!(g.set(Cell(2, 1, 0), SOIL));
    assert!(!g.set(Cell(2, 1, 0), SOIL));
    assert!(!g.set(Cell(24, 1, 0), SOIL));
    assert_eq!(g.changed, BTreeSet::from([Cell(0, 0, 0)]));
    assert_eq!(g.chunks[&Cell(0, 0, 0)].revision, 1);
    let rev = g.chunks[&Cell(0, 0, -1)].revision;
    assert!(g.set(Cell(1, 1, -1), AIR));
    assert_eq!(g.chunks[&Cell(0, 0, -1)].revision, rev + 1);
}

#[test]
fn surfaces_are_solid_air_adjacency_not_facility_kinds() {
    let mut g = small();
    let p = Cell(3, 3, 0);
    assert_eq!(g.surfaces(p), [true, false, false, false, false, false]);
    g.set(Cell(3, 3, 1), STONE);
    g.set(Cell(4, 3, 0), STONE);
    assert_eq!(g.surfaces(p), [true, true, false, true, false, false]);
}

#[test]
fn complete_multicell_footprint_and_height_are_required() {
    let mut g = small();
    let b = Body {
        width: 2,
        depth: 3,
        height: 4,
        step: 1,
    };
    assert!(g.supported(Cell(2, 2, 0), b));
    g.set(Cell(3, 4, 3), STONE);
    assert!(!g.supported(Cell(2, 2, 0), b));
    g.set(Cell(3, 4, 3), AIR);
    g.set(Cell(3, 4, -1), AIR);
    assert!(!g.supported(Cell(2, 2, 0), b));
    assert!(!g.supported(Cell(7, 7, 0), b));
    assert!(!g.clear(Cell(i32::MAX, 1, 0), b));
    assert!(!g.clear(Cell(1, 1, i32::MAX), b));
    assert!(!g.clear(Cell(1, 1, 0), Body { width: 0, ..b }));
}

#[test]
fn supported_negative_elevation_tunnel_routes_without_seeing_z_zero() {
    let mut g = small();
    for x in 1..=5 {
        for z in -5..=-2 {
            g.set(Cell(x, 2, z), AIR);
        }
    }
    let reachable = g.reachable(Cell(1, 2, -5), Body::default());
    assert!(reachable.contains_key(&Cell(5, 2, -5)));
    assert!(!reachable.contains_key(&Cell(5, 2, 0)));
    assert_eq!(reachable[&Cell(5, 2, -5)], (4, Cell(2, 2, -5)));
}

#[test]
fn bfs_next_hop_goes_around_walls_instead_of_x_first_guess() {
    let mut g = small();
    for z in 0..4 {
        g.set(Cell(2, 1, z), STONE);
    }
    let reached = g.reachable(Cell(1, 1, 0), Body::default());
    assert_eq!(reached[&Cell(3, 1, 0)].0, 4);
    let hop = reached[&Cell(3, 1, 0)].1;
    assert_ne!(hop, Cell(2, 1, 0));
    assert!(g.can_step(Cell(1, 1, 0), hop, Body::default()));
}

#[test]
fn insufficient_height_and_support_prevent_routes() {
    let mut g = small();
    g.height = 1;
    g.set(Cell(2, 0, 3), STONE);
    assert!(!g
        .reachable(Cell(0, 0, 0), Body::default())
        .contains_key(&Cell(3, 0, 0)));
    g.set(Cell(2, 0, 3), AIR);
    g.set(Cell(2, 0, -1), AIR);
    g.set(Cell(2, 0, -2), AIR);
    assert!(!g
        .reachable(Cell(0, 0, 0), Body::default())
        .contains_key(&Cell(3, 0, 0)));
    assert!(g.reachable(Cell(2, 0, 0), Body::default()).is_empty());
}

#[test]
fn configurable_step_height_and_complete_up_down_sweep() {
    let mut g = small();
    let a = Cell(1, 1, 0);
    let b = Cell(2, 1, 1);
    g.set(Cell(2, 1, 0), STONE);
    assert!(g.can_step(a, b, Body::default()));
    assert!(g.can_step(b, a, Body::default()));
    assert!(!g.can_step(
        a,
        b,
        Body {
            step: 0,
            ..Body::default()
        }
    ));
    g.set(Cell(1, 1, 4), STONE);
    assert!(!g.can_step(a, b, Body::default()));
    assert!(!g.can_step(b, a, Body::default()));
    let tiny = Body {
        height: 1,
        step: 5,
        ..Body::default()
    };
    g.set(Cell(1, 1, 4), AIR);
    g.set(Cell(1, 1, 2), STONE);
    g.set(Cell(2, 1, 4), STONE);
    assert!(g.supported(a, tiny));
    assert!(g.supported(Cell(2, 1, 5), tiny));
    assert!(!g.can_step(a, Cell(2, 1, 5), tiny));
    assert!(!g.can_step(Cell(2, 1, 5), a, tiny));
    assert!(!g.can_step(Cell(i32::MIN, 0, 0), Cell(i32::MAX, 0, 0), tiny));
}

#[test]
fn excavation_normalizes_rectangles_and_uses_actual_solids_at_arbitrary_heights() {
    let mut g = small();
    for z in 0..7 {
        g.set(Cell(3, 3, z), STONE);
    }
    let d = g.designate(9, 4, 4, 2, 2, 0, 7, 3).unwrap();
    assert_eq!(
        (d.x0, d.y0, d.x1, d.y1, d.bottom_z, d.height),
        (2, 2, 4, 4, 0, 7)
    );
    assert_eq!(d.cells.len(), 7);
    assert_eq!(d.completed(), 0);
    assert_eq!(d.cells[0].z, 6);
    assert_eq!(d.cells[6].z, 0);
    let below = g.designate(10, 0, 0, 0, 0, -10, 3, 2).unwrap();
    assert_eq!(below.cells.len(), 3);
    assert!(g.designate(0, 0, 0, 1, 1, 0, 0, 2).is_err());
    assert!(g.designate(0, 0, 0, 1, 1, 0, 4, 0).is_err());
    assert!(g.designate(0, -1, 0, 1, 1, 0, 4, 2).is_err());
    assert!(g.designate(0, 0, 0, 1, 1, 14, 3, 2).is_err());
    assert!(g.designate(0, 0, 0, 1, 1, i32::MAX, 2, 2).is_err());
    assert!(g.designate(0, 0, 0, 1, 1, 0, 4, 2).is_err());
    g.designations.push(d);
    assert!(g.designate(0, 3, 3, 3, 3, 0, 1, 2).is_err());
    g.designations[0].enabled = false;
    assert!(g.designate(0, 3, 3, 3, 3, 0, 1, 2).is_err());
    g.designations.clear();
    assert!(g.designate(0, 3, 3, 3, 3, 0, 1, 2).is_ok());
}

#[test]
fn mining_validates_exposed_face_supported_position_and_six_cell_reach() {
    let mut g = small();
    g.set(Cell(3, 3, 5), STONE);
    g.set(Cell(3, 3, 6), STONE);
    assert!(g.mine_reachable(Cell(2, 3, 0), Body::default(), Cell(3, 3, 5)));
    assert!(!g.mine_reachable(Cell(2, 3, 0), Body::default(), Cell(3, 3, 6)));
    assert!(!g.mine_reachable(Cell(1, 3, 0), Body::default(), Cell(3, 3, 5)));
    g.set(Cell(2, 3, 4), STONE);
    assert!(!g.mine_reachable(Cell(2, 3, 0), Body::default(), Cell(3, 3, 5)));
    g.set(Cell(2, 3, 4), AIR);
    g.set(Cell(2, 3, -1), AIR);
    assert!(!g.mine_reachable(Cell(2, 3, 0), Body::default(), Cell(3, 3, 5)));
}

#[test]
fn excavation_can_open_adjacent_floors_but_not_reach_through_them() {
    let mut g = small();
    let p = Cell(2, 3, 0);
    assert!(g.mine_reachable(p, Body::default(), Cell(3, 3, -1)));
    assert!(!g.mine_reachable(p, Body::default(), Cell(3, 3, -2)));
    assert!(!g.mine_reachable(p, Body::default(), Cell(2, 3, -1)));
    g.set(Cell(3, 3, 0), STONE);
    assert!(!g.mine_reachable(p, Body::default(), Cell(3, 3, -1)));
}

#[test]
fn seeded_hillside_has_finite_reachable_six_cell_designation() {
    let g = Geometry::seeded();
    let d = &g.designations[0];
    assert_eq!(d.height, DEFAULT_EXCAVATION_HEIGHT);
    assert_eq!(d.cells.len(), 48);
    assert!(g.supported(Cell(21, 8, 0), Body::default()));
    assert!(g.mine_reachable(Cell(21, 8, 0), Body::default(), d.cells[0].cell()));
    assert!(!g.supported(Cell(22, 8, 0), Body::default()));
}

#[test]
fn fresh_default_is_128_squared_but_starter_and_flat_migration_remain_24_squared() {
    let g = Geometry::seeded();
    assert_eq!((g.width, g.height, g.min_z, g.max_z), (128, 128, -16, 15));
    assert_eq!(g.chunks.len(), 128);
    assert!(g.supported(Cell(127, 127, 0), Body::default()));
    for c in [
        Cell(128, 0, 0),
        Cell(0, 128, 0),
        Cell(-1, 0, 0),
        Cell(0, 0, -17),
        Cell(0, 0, 16),
    ] {
        assert_eq!(g.material(c), None, "{c:?}");
    }
    let w = crate::sim::new_world();
    assert_eq!(w.tiles.len(), 576);
    assert_eq!(w.colonists.len(), 8);
    for tile in w
        .tiles
        .iter()
        .filter(|t| t.kind != crate::sim::TileKind::Empty)
    {
        assert!(g.supported(tile.base(), tile.body()));
    }
    assert_eq!((Geometry::flat().width, Geometry::flat().height), (24, 24));
}

#[test]
fn expansion_preserves_every_old_cell_and_job_and_seeds_former_padding() {
    let mut g = Geometry::flat();
    g.set(Cell(23, 23, -1), AIR);
    g.set(Cell(20, 21, 0), STONE);
    let mut d = g.designate(88, 2, 1, 2, 1, -4, 3, 1).unwrap();
    d.cells[0].progress = 0.375;
    d.cells[1].material = AIR;
    d.cells[1].progress = 1.0;
    d.enabled = false;
    g.designations.push(d);
    let (key, i) = chunk_address(Cell(24, 1, 3));
    g.chunks.get_mut(&key).unwrap().materials[i] = STONE;
    g.changed.clear();
    let old = g.clone();
    g.expand(128, 128).unwrap();
    assert_eq!(g.designations, old.designations);
    assert_eq!(g.dirty_jobs, old.dirty_jobs);
    assert_eq!(g.dirty_designations, old.dirty_designations);
    for z in -16..=15 {
        for y in 0..128 {
            for x in 0..128 {
                let c = Cell(x, y, z);
                if x < 24 && y < 24 {
                    assert_eq!(g.material(c), old.material(c), "{c:?}");
                } else {
                    assert_eq!(
                        g.material(c),
                        Some(if z == -1 {
                            SOIL
                        } else if z < 0 {
                            STONE
                        } else {
                            AIR
                        }),
                        "{c:?}"
                    );
                }
            }
        }
    }
    for (key, chunk) in &old.chunks {
        let expanded = &g.chunks[key];
        assert_eq!(expanded.id, chunk.id);
        assert_eq!(
            expanded.revision,
            chunk.revision + u32::from(expanded.materials != chunk.materials)
        );
    }
    let old_max = old.chunks.values().map(|c| c.id).max().unwrap();
    assert!(g
        .chunks
        .iter()
        .filter(|(k, _)| !old.chunks.contains_key(k))
        .all(|(_, c)| c.id > old_max));
    assert!(g.supported(Cell(24, 1, 0), Body::default()));
    assert!(g.can_step(Cell(23, 1, 0), Cell(24, 1, 0), Body::default()));
}

#[test]
fn expansion_is_bounded_atomic_idempotent_and_never_shrinks() {
    let mut g = Geometry::flat();
    let original = g.clone();
    for (w, h) in [
        (0, 128),
        (128, 0),
        (-1, 128),
        (257, 128),
        (128, 257),
        (i32::MAX, 1),
        (23, 128),
        (128, 23),
    ] {
        assert!(g.expand(w, h).is_err());
        assert_eq!(g, original);
    }
    g.expand(24, 24).unwrap();
    assert_eq!(g, original);
    g.expand(25, 24).unwrap();
    assert_eq!(g.chunks.len(), 8);
    assert_eq!(g.material(Cell(25, 0, -1)), None);
    assert!(!g.supported(
        Cell(24, 0, 0),
        Body {
            width: 2,
            ..Body::default()
        }
    ));
    g.changed.clear();
    g.expand(33, 31).unwrap();
    assert_eq!(g.material(Cell(32, 30, -1)), Some(SOIL));
    assert_eq!(g.material(Cell(33, 30, -1)), None);
    g.changed.clear();
    let grown = g.clone();
    g.expand(33, 31).unwrap();
    assert_eq!(g, grown);
    assert!(g.changed.is_empty());
    g.chunks.get_mut(&Cell(0, 0, -1)).unwrap().id = u64::MAX;
    let exhausted = g.clone();
    assert!(g.expand(128, 128).is_err());
    assert_eq!(g, exhausted);
}

#[test]
fn maximum_bounded_world_has_exact_chunk_and_padding_limits() {
    let g = Geometry::flat_with_dimensions(MAX_WORLD_EDGE, MAX_WORLD_EDGE).unwrap();
    assert_eq!(g.chunks.len(), 512);
    assert!(g.supported(Cell(255, 255, 0), Body::default()));
    assert_eq!(g.material(Cell(256, 255, -1)), None);
    assert!(Geometry::flat_with_dimensions(257, 128).is_err());
}

#[test]
fn expansion_rejects_incomplete_old_chunks_instead_of_regenerating_old_land() {
    let mut g = Geometry::flat();
    g.chunks.remove(&Cell(1, 1, -1));
    let original = g.clone();
    assert!(g.expand(128, 128).is_err());
    assert_eq!(g, original);
    let mut g = Geometry::flat();
    g.chunks
        .get_mut(&Cell(1, 1, -1))
        .unwrap()
        .materials
        .truncate(8);
    let original = g.clone();
    assert!(g.expand(128, 128).is_err());
    assert_eq!(g, original);
}
