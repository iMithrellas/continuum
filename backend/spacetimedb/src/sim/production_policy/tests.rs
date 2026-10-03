use super::*;
use crate::sim::{
    self,
    geometry::{Cell, Geometry, STONE},
    Colonist, Goal, HaulRole, TileKind, Tuning, WorkType,
};

fn policy(w: &mut World, kind: ResourceKind, target: f32) {
    w.production_policies
        .push(ProductionPolicy::new(kind, target).unwrap());
}

#[test]
fn validates_every_resource_and_rejects_non_finite_non_positive_or_over_bound() {
    for kind in sim::RESOURCE_KINDS {
        for target in [
            f32::NAN,
            f32::INFINITY,
            f32::NEG_INFINITY,
            -1.0,
            -0.0,
            0.0,
            MAX_PRODUCTION_TARGET + 1.0,
        ] {
            assert!(ProductionPolicy::new(kind, target).is_err());
        }
        for target in [f32::MIN_POSITIVE, 1.0, MAX_PRODUCTION_TARGET] {
            assert_eq!(ProductionPolicy::new(kind, target).unwrap().target, target);
        }
    }
}

#[test]
fn storage_piles_and_cargo_count_and_transfers_conserve_supply() {
    let mut w = sim::new_world();
    let tile = w
        .tiles
        .iter()
        .find(|t| t.kind == TileKind::Forest)
        .unwrap()
        .clone();
    w.resources.wood = 2.0;
    w.add_to_stack(&tile, ResourceKind::Wood, 3.0);
    w.colonists[0].cargo = sim::Cargo {
        kind: ResourceKind::Wood,
        amount: 4.0,
    };
    policy(&mut w, ResourceKind::Wood, 9.0);
    assert_eq!(w.total_supply(ResourceKind::Wood), 9.0);
    assert!(!w.production_allowed(ResourceKind::Wood));
    let amount = w.take_from_stack(tile.id, ResourceKind::Wood, 3.0);
    w.colonists[0].cargo.amount += amount;
    assert_eq!(w.total_supply(ResourceKind::Wood), 9.0);
    w.resources
        .add(ResourceKind::Wood, w.colonists[0].cargo.amount);
    w.colonists[0].cargo.amount = 0.0;
    assert_eq!(w.total_supply(ResourceKind::Wood), 9.0);
    w.resources.take(ResourceKind::Wood, 1.0);
    assert!(w.production_allowed(ResourceKind::Wood));
}

#[test]
fn missing_rows_unlimited_independent_rows_and_disabled_order_precedence() {
    let mut w = sim::new_world();
    let forest = w
        .tiles
        .iter()
        .find(|t| t.kind == TileKind::Forest)
        .unwrap()
        .clone();
    let hunting = w
        .tiles
        .iter()
        .find(|t| t.kind == WorkType::Hunting.definition().unwrap().facility)
        .unwrap()
        .clone();
    w.resources.wood = 10.0;
    assert!(w.active_work_order(&forest, WorkType::Logging).is_some());
    policy(&mut w, ResourceKind::Wood, 10.0);
    policy(&mut w, ResourceKind::Meat, 20.0);
    let intents = w.work_orders.clone();
    assert!(w.active_work_order(&forest, WorkType::Logging).is_none());
    assert!(w.active_work_order(&hunting, WorkType::Hunting).is_some());
    w.production_policies
        .retain(|p| p.resource != ResourceKind::Wood);
    assert!(w.active_work_order(&forest, WorkType::Logging).is_some());
    assert_eq!(w.work_orders, intents);
    let order = w
        .work_orders
        .iter_mut()
        .find(|o| o.tile_id == forest.id)
        .unwrap();
    order.enabled = false;
    assert!(w.active_work_order(&forest, WorkType::Logging).is_none());
}

#[test]
fn suspension_flushes_small_leftovers_without_disabling_hauling() {
    let mut w = sim::new_world();
    let tile = w
        .tiles
        .iter()
        .find(|t| t.kind == TileKind::Forest)
        .unwrap()
        .clone();
    w.add_to_stack(&tile, ResourceKind::Wood, 0.5);
    policy(&mut w, ResourceKind::Wood, 0.5);
    let tuning = Tuning::default();
    assert!(w.supply_ready(&tile, WorkType::Logging, &tuning));
    assert_eq!(
        w.best_supply_tile(WorkType::Logging, &tuning, tile.x, tile.y)
            .unwrap()
            .id,
        tile.id
    );
    assert!(
        w.work_orders
            .iter()
            .find(|o| o.tile_id == tile.id)
            .unwrap()
            .enabled
    );
}

#[test]
fn threshold_stops_actions_resumes_after_spending_and_zero_step_is_unchanged() {
    let mut w = sim::new_world();
    let tile = w
        .tiles
        .iter()
        .find(|t| t.kind == TileKind::Forest)
        .unwrap()
        .clone();
    w.colonists = vec![Colonist::new(1, "Logger", tile.x, tile.y)];
    w.colonists[0].assignment.work = WorkType::Logging;
    w.colonists[0].assignment.haul_role = HaulRole::Producer;
    w.colonists[0].wellbeing.productivity = 100.0;
    w.colonists[0].task.goal = Goal::Work;
    policy(&mut w, ResourceKind::Wood, 1.0);
    let tuning = Tuning::default();
    sim::logistics::step_work(&mut w, 0, &tuning, 1.0);
    let supply = w.total_supply(ResourceKind::Wood);
    assert!(supply >= 1.0);
    sim::logistics::step_work(&mut w, 0, &tuning, 1.0);
    assert_eq!(w.total_supply(ResourceKind::Wood), supply);
    let snapshot = w.clone();
    sim::step(&mut w, &tuning, 0.0);
    assert_eq!(w, snapshot);
    let goods = w.take_from_stack(tile.id, ResourceKind::Wood, supply as f32);
    w.resources.add(ResourceKind::Wood, goods);
    w.resources.take(ResourceKind::Wood, goods);
    sim::logistics::step_work(&mut w, 0, &tuning, 1.0);
    assert!(w.total_supply(ResourceKind::Wood) > 0.0);
}

#[test]
fn supply_accumulation_is_stable_under_storage_permutations() {
    let mut w = sim::new_world();
    let tiles: Vec<_> = w.tiles.iter().take(3).cloned().collect();
    for (tile, amount) in tiles.iter().zip([1.0e10, 0.25, 1.0]) {
        w.add_to_stack(tile, ResourceKind::Wood, amount);
    }
    for (c, amount) in w.colonists.iter_mut().zip([1.0e10, 0.25, 1.0]) {
        c.cargo = sim::Cargo {
            kind: ResourceKind::Wood,
            amount,
        };
    }
    let total = w.total_supply(ResourceKind::Wood);
    w.stacks.reverse();
    w.colonists.reverse();
    assert_eq!(w.total_supply(ResourceKind::Wood), total);
}

#[test]
fn physical_excavation_suspends_without_losing_progress_and_resumes() {
    let mut w = sim::new_world();
    w.tiles.clear();
    w.work_orders.clear();
    w.colonists = vec![Colonist::new(1, "Miner", 2, 2)];
    w.colonists[0].assignment.work = WorkType::Mining;
    w.colonists[0].wellbeing.productivity = 100.0;
    let mut g = Geometry::flat();
    g.width = 8;
    g.height = 6;
    let cell = Cell(3, 2, 0);
    g.set(cell, STONE);
    let d = g.designate(1, 3, 2, 3, 2, 0, 1, 2).unwrap();
    g.designations.push(d);
    w.geometry = Some(g);
    let tuning = Tuning {
        output_stone_per_hour: 1.0,
        ..Tuning::default()
    };
    w.step_mining(0, &tuning, 0.5);
    assert_eq!(
        w.geometry.as_ref().unwrap().designations[0].cells[0].progress,
        0.5
    );
    policy(&mut w, ResourceKind::Stone, 1.0);
    w.resources.stone = 1.0;
    assert!(w.mining_job(0).is_none());
    w.step_mining(0, &tuning, 1.0);
    assert_eq!(
        w.geometry.as_ref().unwrap().designations[0].cells[0].progress,
        0.5
    );
    w.resources.take(ResourceKind::Stone, 1.0);
    w.step_mining(0, &tuning, 0.5);
    assert_eq!(w.total_supply(ResourceKind::Stone), 1.0);
    assert_eq!(w.geometry.as_ref().unwrap().designations[0].completed(), 1);
    assert!(w.geometry.as_ref().unwrap().designations[0].enabled);
    assert!(!w.production_allowed(ResourceKind::Stone));
}

#[test]
fn eating_stored_food_resumes_farming_without_mutating_intent() {
    let mut w = sim::new_world();
    policy(&mut w, ResourceKind::Food, 400.0);
    let intents = w.work_orders.clone();
    assert!(!w.production_allowed(ResourceKind::Food));
    w.colonists[0].needs.hunger = 50.0;
    sim::needs::step_eat(
        &mut w.colonists[0].needs,
        &mut w.resources,
        w.meal_policy,
        &Tuning::default(),
        1.0,
    );
    assert!(w.production_allowed(ResourceKind::Food));
    assert_eq!(w.work_orders, intents);
    assert_eq!(w.production_policies[0].target, 400.0);
}
