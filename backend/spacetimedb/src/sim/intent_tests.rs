//! Regression scenarios for speculative planning and ordered conflict resolution.

use super::step_with_workers;
use crate::sim::*;

fn fixture() -> (World, Tuning) {
    let mut world = new_world();
    world.tiles = [TileKind::Farm, TileKind::Storage, TileKind::Dining]
        .into_iter()
        .enumerate()
        .map(|(i, kind)| Tile {
            id: i as u32 + 1,
            x: i as i32,
            y: 0,
            kind,
            enabled: true,
            z: 0,
            width: 1,
            depth: 1,
            clearance_height: 4,
        })
        .collect();
    world.work_orders = default_work_orders(&world.tiles);
    world.colonists = [10, 90]
        .into_iter()
        .map(|id| {
            let mut c = Colonist::new(id, "Planner", 0, 0);
            c.assignment.work = WorkType::Farming;
            c
        })
        .collect();
    world.resources.food = 0.0;
    let tuning = Tuning {
        hunger_per_hour: 0.0,
        fatigue_per_hour: 0.0,
        recreation_per_hour: 0.0,
        output_food_per_hour: 0.0,
        ..Tuning::default()
    };
    (world, tuning)
}

/// Exercise actual schedule gathering, batch evaluation, revalidation and action
/// commit with multiple executor sizes and different persisted-row permutations.
fn run_parity(initial: &World, tuning: &Tuning, dt: f64) -> World {
    let mut expected = initial.clone();
    let events = step_with_workers(&mut expected, tuning, dt, 1);
    for workers in [1, 2, 4, 8, 32] {
        for reverse in [false, true] {
            let mut actual = initial.clone();
            if reverse {
                actual.colonists.reverse();
                actual.tiles.reverse();
                actual.work_orders.reverse();
            }
            assert_eq!(step_with_workers(&mut actual, tuning, dt, workers), events);
            actual.colonists.sort_by_key(|c| c.id);
            actual.tiles.sort_by_key(|t| t.id);
            actual.work_orders.sort_by_key(|o| o.id);
            assert_eq!(actual, expected);
        }
    }
    expected
}

#[test]
fn contended_food_keeps_interval_snapshot_and_ordered_consumption() {
    let (mut world, tuning) = fixture();
    world.resources.food = 0.01;
    for c in &mut world.colonists {
        c.position.x = 2;
        c.needs.hunger = 80.0;
    }
    let result = run_parity(&world, &tuning, 60.0);
    assert_eq!(result.resources.food, 0.0);
    assert!(result.colonists[0].needs.hunger < 80.0);
    assert_eq!(result.colonists[1].needs.hunger, 80.0);
    assert!(result.colonists.iter().all(|c| c.task.goal == Goal::Eat));
}

#[test]
fn depleted_pile_invalidates_later_haul_proposal() {
    let (mut world, tuning) = fixture();
    let amount = tuning.stack_size(ResourceKind::Food);
    world.add_to_stack(&world.tiles[0].clone(), ResourceKind::Food, amount);
    let result = run_parity(&world, &tuning, 60.0);
    assert_eq!(result.colonists[0].cargo.amount, amount);
    assert_eq!(result.colonists[1].cargo.amount, 0.0);
    assert_eq!(result.colonists[1].task.goal, Goal::Work);
    assert!(result.stacks.is_empty());
}

#[test]
fn earlier_production_invalidates_later_work_proposal() {
    let (world, mut tuning) = fixture();
    let amount = tuning.stack_size(ResourceKind::Food);
    tuning.output_food_per_hour = amount * 60.0 / 0.8;
    let result = run_parity(&world, &tuning, 60.0);
    assert_eq!(result.colonists[0].task.goal, Goal::Work);
    assert_eq!(result.colonists[1].task.goal, Goal::Haul);
    assert_eq!(result.colonists[1].cargo.amount, amount);
    assert!(result.stacks.is_empty());
}

#[test]
fn earlier_deposit_is_edible_same_interval_but_does_not_refresh_food_snapshot() {
    for initial_food in [0.0, 0.01] {
        let (mut world, tuning) = fixture();
        world.resources.food = initial_food;
        world.colonists[0].position.x = 1;
        world.colonists[0].cargo.amount = 30.0;
        world.colonists[1].position.x = 2;
        world.colonists[1].needs.hunger = 80.0;
        let result = run_parity(&world, &tuning, 60.0);
        assert_eq!(result.colonists[0].cargo.amount, 0.0);
        if initial_food > 0.0 {
            assert_eq!(result.colonists[1].task.goal, Goal::Eat);
            assert!(result.colonists[1].needs.hunger < 80.0);
            assert!(result.resources.food < 30.0);
        } else {
            assert_ne!(result.colonists[1].task.goal, Goal::Eat);
            assert_eq!(result.resources.food, 30.0);
            let next = run_parity(&result, &tuning, 60.0);
            assert_eq!(next.colonists[1].task.goal, Goal::Eat);
        }
    }
}

#[test]
fn mining_geometry_mutations_keep_worker_and_row_order_parity() {
    use crate::sim::geometry::{Cell, Geometry, STONE};

    for policy in [HaulPolicy::SelfHaul, HaulPolicy::DedicatedHaulers] {
        let (mut world, mut tuning) = fixture();
        world.haul_policy = policy;
        world.tiles.retain(|tile| tile.kind == TileKind::Storage);
        world.tiles[0].x = 0;
        world.work_orders.clear();
        world.resources.stone = 0.0;
        let mut geometry = Geometry::flat();
        geometry.width = 8;
        geometry.height = 6;
        for z in 0..4 {
            geometry.set(Cell(3, 2, z), STONE);
        }
        let designation = geometry.designate(1, 3, 2, 3, 2, 0, 4, 2).unwrap();
        geometry.designations.push(designation);
        world.geometry = Some(geometry);
        for c in &mut world.colonists {
            c.position = Position { x: 2, y: 2 };
            c.assignment.work = WorkType::Mining;
            c.wellbeing.productivity = 100.0;
        }
        tuning.output_stone_per_hour = 600.0;
        tuning.move_tiles_per_hour = 600.0;
        let result = run_parity(&world, &tuning, 25.0 * 60.0);
        assert_eq!(
            result.geometry.as_ref().unwrap().designations[0].completed(),
            4
        );
        assert_eq!(result.resources.stone, 4.0);
        assert!(result.stacks.is_empty());
    }
}

#[test]
fn ordered_path_gathers_once_per_actor_per_bounded_interval() {
    use crate::sim::intents::GATHER_COUNT;

    for workers in [1, 2, 8] {
        let (mut world, tuning) = fixture();
        GATHER_COUNT.with(|count| count.set(0));
        step_with_workers(&mut world, &tuning, 121.0, workers);
        GATHER_COUNT.with(|count| assert_eq!(count.get(), world.colonists.len() * 3));
        step_with_workers(&mut world, &tuning, 0.0, workers);
        GATHER_COUNT.with(|count| assert_eq!(count.get(), world.colonists.len() * 3));
    }
}

#[test]
fn speculation_cannot_warm_navigation_or_evict_saved_routes() {
    use crate::sim::decisions::Availability;
    use crate::sim::geometry::{Cell, Geometry};
    use crate::sim::intents::{plan_batch, DecisionInput, GATHER_COUNT};

    for diverse_bodies in [false, true] {
        let (mut world, mut tuning) = fixture();
        world.geometry = Some(Geometry::flat_with_dimensions(8, 8).unwrap());
        world.tiles[0].x = 6;
        world.tiles[0].y = 6;
        world.colonists = (0..48)
            .map(|id| {
                let mut actor = Colonist::new(id + 1, "Cache pressure", 0, 0);
                actor.assignment.work = WorkType::Farming;
                actor.task.goal = Goal::Work;
                actor.task.activity = Activity::Travelling;
                actor.movement.target = Position { x: 6, y: 6 };
                actor.movement.progress = 0.25;
                actor.spatial.next = Cell(0, 1, 0);
                if diverse_bodies {
                    actor.spatial.body.height = (id % 9 + 1) as u16;
                }
                actor
            })
            .collect();
        tuning.move_tiles_per_hour = 40.0;
        let interval = Availability {
            food: false,
            kitchen: true,
            sleep: false,
            recreation: false,
        };
        GATHER_COUNT.with(|count| count.set(0));
        let inputs = world
            .colonists
            .iter()
            .map(|actor| DecisionInput::speculate(actor, interval))
            .collect();
        let _ = plan_batch(inputs, &tuning, 8);
        GATHER_COUNT.with(|count| assert_eq!(count.get(), 0));
        assert_eq!(world.navigation.borrow().cached_counts(), (0, 0, 0));
        assert_eq!(world.navigation.borrow().graph_builds, 0);

        let mut serial = world.clone();
        let mut native = world;
        native.colonists.reverse();
        for _ in 0..10 {
            assert_eq!(
                step_with_workers(&mut native, &tuning, 60.0, 8),
                step_with_workers(&mut serial, &tuning, 60.0, 1)
            );
            native.colonists.sort_by_key(|actor| actor.id);
            assert_eq!(native, serial);
            let a = serial.navigation.borrow();
            let b = native.navigation.borrow();
            assert_eq!(a.cached_counts(), b.cached_counts());
            assert_eq!(a.graph_builds, b.graph_builds);
            assert_eq!(a.searches, b.searches);
            assert_eq!(a.route_builds, b.route_builds);
        }
    }
}
