use super::*;
use crate::sim::geometry::{Geometry, STONE};
use crate::sim::{self, Colonist, HaulPolicy, HaulRole};

fn tile(id: u32, p: Cell, kind: TileKind) -> Tile {
    Tile {
        id,
        x: p.0,
        y: p.1,
        z: p.2,
        kind,
        enabled: true,
        width: 1,
        depth: 1,
        clearance_height: 4,
    }
}
fn world() -> World {
    let mut w = sim::new_world();
    w.tiles.clear();
    w.work_orders.clear();
    w.colonists.clear();
    let mut g = Geometry::flat();
    g.width = 8;
    g.height = 6;
    w.geometry = Some(g);
    let mut c = Colonist::new(1, "Miner", 2, 2);
    c.assignment.work = WorkType::Mining;
    c.wellbeing.productivity = 100.0;
    c.needs.hunger = 0.0;
    c.needs.fatigue = 0.0;
    c.needs.recreation = 0.0;
    w.colonists.push(c);
    w.tiles.push(tile(71, Cell(0, 0, 0), TileKind::Storage));
    w
}
fn designate(w: &mut World, p: Cell, height: u16) {
    let g = w.geometry.as_mut().unwrap();
    for z in p.2..p.2 + i32::from(height) {
        g.set(Cell(p.0, p.1, z), STONE);
    }
    let d = g.designate(1, p.0, p.1, p.0, p.1, p.2, height, 2).unwrap();
    g.designations.push(d);
}
fn fast() -> Tuning {
    Tuning {
        output_stone_per_hour: 600.0,
        move_tiles_per_hour: 600.0,
        ..Tuning::default()
    }
}
fn stone_total(w: &World) -> f32 {
    w.resources.stone
        + w.stacks
            .iter()
            .filter(|s| s.kind == ResourceKind::Stone)
            .map(|s| s.amount)
            .sum::<f32>()
        + w.colonists
            .iter()
            .filter(|c| c.cargo.kind == ResourceKind::Stone)
            .map(|c| c.cargo.amount)
            .sum::<f32>()
}

#[test]
fn finite_specific_cells_progress_once_and_never_use_infinite_mine_orders() {
    let mut w = world();
    designate(&mut w, Cell(3, 2, 0), 6);
    w.tiles.push(tile(72, Cell(1, 2, 0), TileKind::Mine));
    w.work_orders = sim::default_work_orders(&w.tiles);
    for _ in 0..12 {
        w.step_mining(0, &fast(), 1.0);
    }
    assert_eq!(w.geometry.as_ref().unwrap().designations[0].completed(), 6);
    for z in 0..6 {
        assert_eq!(
            w.geometry.as_ref().unwrap().material(Cell(3, 2, z)),
            Some(AIR)
        );
    }
    assert_eq!(stone_total(&w), 6.0);
    for _ in 0..5 {
        crate::sim::logistics::step_work(&mut w, 0, &fast(), 1.0);
    }
    assert_eq!(stone_total(&w), 6.0);
    assert_eq!(
        w.stacks[0].id,
        sim::stack_id(w.stacks[0].tile_id, ResourceKind::Stone)
    );
    assert!(w.stacks[0].tile_id > 72);
}

#[test]
fn partial_progress_pause_and_cancel_do_not_create_goods() {
    let mut w = world();
    designate(&mut w, Cell(3, 2, 0), 1);
    w.step_mining(0, &Tuning::default(), 0.1);
    assert_eq!(stone_total(&w), 0.0);
    assert_eq!(
        w.geometry.as_ref().unwrap().designations[0].cells[0].progress,
        0.5
    );
    w.geometry.as_mut().unwrap().designations[0].enabled = false;
    w.step_mining(0, &fast(), 1.0);
    assert_eq!(stone_total(&w), 0.0);
    w.geometry.as_mut().unwrap().designations[0].enabled = true;
    w.step_mining(0, &Tuning::default(), 0.1);
    assert_eq!(stone_total(&w), 1.0);
    w.geometry.as_mut().unwrap().designations.clear();
    w.step_mining(0, &fast(), 1.0);
    assert_eq!(stone_total(&w), 1.0);
}

#[test]
fn inaccessible_buried_job_never_teleports_or_mines_through_rock() {
    let mut w = world();
    let g = w.geometry.as_mut().unwrap();
    let d = g.designate(1, 4, 4, 4, 4, -8, 1, 1).unwrap();
    g.designations.push(d);
    assert!(w.mining_job(0).is_none());
    let before = w.actor_cell(0);
    sim::step(&mut w, &fast(), 60.0);
    assert_eq!(w.actor_cell(0), before);
    assert_eq!(stone_total(&w), 0.0);
    assert_eq!(
        w.geometry.as_ref().unwrap().material(Cell(4, 4, -8)),
        Some(STONE)
    );
}

#[test]
fn support_under_actors_facilities_and_ground_stacks_is_protected() {
    let mut w = world();
    assert!(w.cell_protected(Cell(2, 2, -1)));
    assert!(w.cell_protected(Cell(0, 0, -1)));
    let t = tile(80, Cell(4, 2, 0), TileKind::Farm);
    w.add_to_stack(&t, ResourceKind::Stone, 1.0);
    assert!(w.cell_protected(Cell(4, 2, -1)));
    // A tunnel miner can reach the support face but must leave it intact.
    let g = w.geometry.as_mut().unwrap();
    for z in -1..=2 {
        g.set(Cell(1, 2, z), AIR);
    }
    let d = g.designate(1, 2, 2, 2, 2, -1, 1, 1).unwrap();
    g.designations.push(d);
    let mut miner = Colonist::new(2, "Tunnel miner", 1, 2);
    miner.spatial.z = -1;
    miner.assignment.work = WorkType::Mining;
    w.colonists.push(miner);
    assert!(w.mining_job(1).is_none());
    w.step_mining(1, &fast(), 1.0);
    assert!(w.geometry.as_ref().unwrap().solid(Cell(2, 2, -1)));
}

#[test]
fn miners_contend_in_durable_id_order_without_duplicate_output_and_haul_finite_goods() {
    for policy in [HaulPolicy::SelfHaul, HaulPolicy::DedicatedHaulers] {
        let mut w = world();
        w.haul_policy = policy;
        designate(&mut w, Cell(3, 2, 0), 4);
        let mut second = w.colonists[0].clone();
        second.id = 2;
        w.colonists.push(second);
        for _ in 0..25 {
            sim::step(&mut w, &fast(), 60.0);
        }
        assert_eq!(w.geometry.as_ref().unwrap().designations[0].completed(), 4);
        assert_eq!(stone_total(&w), 4.0);
        assert_eq!(w.resources.stone, 4.0);
        assert!(w.stacks.is_empty());
    }
}

#[test]
fn complete_volume_placement_checks_support_clearance_overlap_and_elevations() {
    let mut w = world();
    let mut t = tile(0, Cell(3, 1, 0), TileKind::Recreation);
    t.width = 2;
    t.depth = 2;
    t.clearance_height = 5;
    assert!(w.validate_placement(&t).is_ok());
    w.geometry.as_mut().unwrap().set(Cell(4, 2, 4), STONE);
    assert!(w.validate_placement(&t).is_err());
    w.geometry.as_mut().unwrap().set(Cell(4, 2, 4), AIR);
    w.geometry.as_mut().unwrap().set(Cell(4, 2, -1), AIR);
    assert!(w.validate_placement(&t).is_err());
    w.geometry.as_mut().unwrap().set(Cell(4, 2, -1), STONE);
    w.tiles.push(tile(90, Cell(4, 2, 0), TileKind::Dining));
    assert!(w.validate_placement(&t).is_err());
    t.z = 5;
    assert!(w.validate_placement(&t).is_err()); // no support
    t.width = 0;
    assert!(w.validate_placement(&t).is_err());
}

#[test]
fn dynamic_elevation_ids_never_change_old_stack_keys() {
    let mut w = world();
    let a = w.allocate_tile(Cell(2, 2, 0), TileKind::Empty).unwrap();
    let b = w.allocate_tile(Cell(2, 2, -4), TileKind::Empty).unwrap();
    assert_ne!(a.id, b.id);
    assert_eq!(
        w.allocate_tile(Cell(2, 2, -4), TileKind::Empty).unwrap().id,
        b.id
    );
    assert_eq!(sim::stack_id(71, ResourceKind::Stone), 286);
    w.add_to_stack(&a, ResourceKind::Stone, 1.0);
    w.add_to_stack(&b, ResourceKind::Stone, 2.0);
    assert_ne!(w.stacks[0].id, w.stacks[1].id);
    assert_eq!(w.stacks[1].z, -4);
}

#[test]
fn exhausted_durable_ids_do_not_remove_terrain_without_a_pile_anchor() {
    let mut w = world();
    w.tiles[0].id = u32::MAX;
    designate(&mut w, Cell(3, 2, 0), 1);
    w.step_mining(0, &fast(), 1.0);
    assert!(w.geometry.as_ref().unwrap().solid(Cell(3, 2, 0)));
    assert_eq!(stone_total(&w), 0.0);
    assert_eq!(w.geometry.as_ref().unwrap().designations[0].completed(), 0);
}

#[test]
fn seven_cell_column_keeps_its_base_step_until_upper_cell_is_mined() {
    let mut w = world();
    designate(&mut w, Cell(3, 2, 0), 7);
    let mut used_step = false;
    for _ in 0..200 {
        sim::step(&mut w, &fast(), 60.0);
        let g = w.geometry.as_ref().unwrap();
        if g.solid(Cell(3, 2, 6)) {
            assert!(
                g.solid(Cell(3, 2, 0)),
                "base scaffold removed before upper access"
            );
        }
        if w.actor_cell(0) == Cell(3, 2, 1) {
            used_step = true;
        }
    }
    assert!(
        used_step,
        "miner must execute the supported elevation route"
    );
    assert_eq!(w.geometry.as_ref().unwrap().designations[0].completed(), 7);
    assert_eq!(stone_total(&w), 7.0);
    assert_eq!(w.resources.stone, 7.0);
}

#[test]
fn multicolumn_tall_room_finishes_without_consuming_required_base_scaffolds() {
    let mut w = world();
    let g = w.geometry.as_mut().unwrap();
    for x in 3..5 {
        for y in 2..4 {
            for z in 0..7 {
                g.set(Cell(x, y, z), STONE);
            }
        }
    }
    let d = g.designate(1, 3, 2, 4, 3, 0, 7, 2).unwrap();
    g.designations.push(d);
    let mut elevated = false;
    for _ in 0..300 {
        sim::step(&mut w, &fast(), 60.0);
        elevated |= w.actor_cell(0).2 > 0;
    }
    assert!(elevated);
    assert_eq!(w.geometry.as_ref().unwrap().designations[0].completed(), 28);
    assert_eq!(stone_total(&w), 28.0);
    assert_eq!(w.resources.stone, 28.0);
}

#[test]
fn nine_cell_excavation_uses_existing_upper_stair_access() {
    let mut w = world();
    w.colonists[0].position.x = 1;
    let g = w.geometry.as_mut().unwrap();
    g.set(Cell(2, 2, 0), STONE);
    g.set(Cell(3, 2, 0), STONE);
    g.set(Cell(3, 2, 1), STONE);
    designate(&mut w, Cell(4, 2, 0), 9);
    let mut reached_upper = false;
    for _ in 0..200 {
        sim::step(&mut w, &fast(), 60.0);
        reached_upper |= w.actor_cell(0).2 >= 3;
        let g = w.geometry.as_ref().unwrap();
        if g.solid(Cell(4, 2, 8)) {
            assert!(g.solid(Cell(4, 2, 2)));
        }
    }
    assert!(reached_upper);
    assert_eq!(w.geometry.as_ref().unwrap().designations[0].completed(), 9);
    assert_eq!(stone_total(&w), 9.0);
    assert_eq!(w.resources.stone, 9.0);
}

#[test]
fn actual_progress_marks_only_changed_job_vectors_and_completion_marks_public_row() {
    let mut w = world();
    designate(&mut w, Cell(3, 2, 0), 1);
    let g = w.geometry.as_mut().unwrap();
    let mut other = g.designate(2, 6, 5, 6, 5, -5, 1, 3).unwrap();
    other.enabled = false;
    g.designations.push(other);
    w.step_mining(0, &Tuning::default(), 0.1);
    let g = w.geometry.as_ref().unwrap();
    assert_eq!(g.dirty_jobs, std::collections::BTreeSet::from([1]));
    assert!(g.dirty_designations.is_empty());
    w.step_mining(0, &Tuning::default(), 0.1);
    let g = w.geometry.as_ref().unwrap();
    assert_eq!(g.dirty_jobs, std::collections::BTreeSet::from([1]));
    assert_eq!(g.dirty_designations, std::collections::BTreeSet::from([1]));
}

#[test]
fn body_reconfiguration_changes_actual_routes_and_mining_execution() {
    let mut w = world();
    w.colonists[0].position = sim::Position { x: 1, y: 1 };
    w.colonists[0].movement.target = sim::Position { x: 5, y: 1 };
    let g = w.geometry.as_mut().unwrap();
    g.height = 3;
    for z in 0..4 {
        g.set(Cell(3, 0, z), STONE);
        g.set(Cell(3, 1, z), STONE);
    }
    designate(&mut w, Cell(6, 1, 0), 1);
    assert!(w.actor_reachability(0).contains_key(&Cell(5, 1, 0)));
    // Mirrors configure_colonist_body's validated narrow Body assignment.
    let body = Body {
        width: 2,
        depth: 2,
        height: 4,
        step: 1,
    };
    assert!(w
        .geometry
        .as_ref()
        .unwrap()
        .supported(w.actor_cell(0), body));
    w.colonists[0].spatial.body = body;
    assert!(!w.actor_reachability(0).contains_key(&Cell(5, 0, 0)));
    assert!(w.mining_job(0).is_none());
    w.step_live_travel(0, &fast(), 1.0);
    assert_eq!(w.actor_cell(0), Cell(1, 1, 0));
    w.colonists[0].spatial.body = Body::default();
    w.step_live_travel(0, &fast(), 1.0);
    assert_eq!(w.actor_cell(0), Cell(5, 1, 0));
    w.step_mining(0, &fast(), 1.0);
    assert_eq!(stone_total(&w), 1.0);
}

#[test]
fn full_size_designations_return_reachable_jobs_and_reject_buried_jobs_without_cross_product() {
    let mut w = world();
    let g = w.geometry.as_mut().unwrap();
    g.width = 24;
    g.height = 24;
    let d = g.designate(1, 0, 0, 23, 23, -16, 16, 2).unwrap();
    assert_eq!(d.cells.len(), 9216);
    g.designations.push(d);
    let (_, _, p) = w.mining_job(0).unwrap();
    assert!(w.actor_reachability(0).contains_key(&p));
    let g = w.geometry.as_mut().unwrap();
    g.designations.clear();
    let d = g.designate(2, 0, 0, 23, 23, -16, 15, 2).unwrap();
    assert_eq!(d.cells.len(), 8640);
    g.designations.push(d);
    assert!(w.mining_job(0).is_none());
}

#[test]
fn need_and_logistics_destinations_ignore_unreachable_facilities_and_other_elevations() {
    let mut w = world();
    w.tiles.push(tile(80, Cell(2, 2, -8), TileKind::Dining));
    w.tiles.push(tile(81, Cell(6, 4, 0), TileKind::Dining));
    assert_eq!(w.live_destination(0, &fast(), Goal::Eat).unwrap().id, 81);
    w.tiles.iter_mut().find(|t| t.id == 81).unwrap().enabled = false;
    assert!(w.live_destination(0, &fast(), Goal::Eat).is_none());
    w.colonists[0].cargo.amount = 1.0;
    w.colonists[0].cargo.kind = ResourceKind::Stone;
    w.tiles[0].z = -8;
    assert!(w.live_destination(0, &fast(), Goal::Haul).is_none());
    sim::step(&mut w, &fast(), 60.0);
    assert_eq!(w.colonists[0].cargo.amount, 1.0);
}

#[test]
fn live_movement_publishes_actual_bfs_next_hop_and_stays_supported() {
    let mut w = world();
    w.colonists[0].position.x = 1;
    w.colonists[0].position.y = 1;
    w.colonists[0].movement.target = sim::Position { x: 3, y: 1 };
    for z in 0..4 {
        w.geometry.as_mut().unwrap().set(Cell(2, 1, z), STONE);
    }
    // Probe before completing even one hop at the default metric walking rate.
    w.step_live_travel(0, &Tuning::default(), 0.1 / 3600.0);
    assert_ne!(w.colonists[0].spatial.next, Cell(2, 1, 0));
    assert_ne!(w.colonists[0].spatial.next, w.actor_cell(0));
    w.step_live_travel(0, &fast(), 0.1);
    assert_eq!(w.actor_cell(0), Cell(3, 1, 0));
    assert_eq!(w.colonists[0].spatial.next, Cell(3, 1, 0));
    assert_eq!(w.colonists[0].movement.progress, 0.0);
    assert!(w
        .geometry
        .as_ref()
        .unwrap()
        .supported(w.actor_cell(0), w.colonists[0].spatial.body));
}

#[test]
fn seeded_operational_facilities_do_not_overlap_hillside_and_have_reachable_jobs() {
    let mut w = sim::new_world();
    w.geometry = Some(Geometry::seeded());
    let g = w.geometry.as_ref().unwrap();
    for t in &w.tiles {
        if t.kind != TileKind::Empty {
            assert!(g.supported(t.base(), t.body()));
        }
    }
    let miner = w
        .colonists
        .iter()
        .position(|c| c.assignment.work == WorkType::Mining)
        .unwrap();
    assert!(w.mining_job(miner).is_some());
    assert_eq!(w.colonists[miner].assignment.haul_role, HaulRole::Both);
}

#[test]
fn descending_excavation_uses_real_negative_elevation_and_stops_at_supported_reach() {
    let mut w = world();
    let g = w.geometry.as_mut().unwrap();
    let d = g.designate(1, 3, 2, 5, 3, -3, 3, 2).unwrap();
    g.designations.push(d);
    w.step_mining(0, &fast(), 1.0);
    assert_eq!(
        w.geometry.as_ref().unwrap().material(Cell(3, 2, -1)),
        Some(AIR)
    );
    assert_eq!(
        w.geometry.as_ref().unwrap().material(Cell(3, 2, -2)),
        Some(STONE)
    );
    let (_, _, position) = w.mining_job(0).unwrap();
    assert_eq!(position, Cell(3, 2, -1));
    assert!(w
        .geometry
        .as_ref()
        .unwrap()
        .reachable(w.actor_cell(0), w.colonists[0].spatial.body)
        .contains_key(&position));
    for _ in 0..100 {
        sim::step(&mut w, &fast(), 60.0);
    }
    // Digging a sheer pit does not conjure a ladder or teleport goods uphill.
    let completed = w.geometry.as_ref().unwrap().designations[0].completed();
    assert!(completed > 0 && completed < 18);
    assert_eq!(stone_total(&w), completed as f32);
    // An explicitly carved staircase outside the designation restores egress.
    let g = w.geometry.as_mut().unwrap();
    g.set(Cell(2, 2, -2), AIR);
    g.set(Cell(2, 2, -1), AIR);
    g.set(Cell(1, 2, -1), AIR);
    for _ in 0..50 {
        sim::step(&mut w, &fast(), 60.0);
    }
    assert_eq!(stone_total(&w), 18.0);
    assert_eq!(w.geometry.as_ref().unwrap().designations[0].completed(), 18);
    assert!(w.stacks.iter().all(|s| s.z <= 0));
}
