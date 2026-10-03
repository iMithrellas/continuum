//! Connected baseline gameplay contracts through the public, pure simulation API.
use continuum_module::sim::geometry::{Cell, Geometry, AIR, STONE};
use continuum_module::sim::terrain::TerrainFields;
use continuum_module::sim::{
    default_work_orders, new_world, stack_id, step, Activity, Colonist, Goal, HaulPolicy,
    ItemStack, MealPolicy, ProductionPolicy, ResourceKind, SimEvent, Tile, TileKind, Tuning,
    WorkType, World,
};

const FARM_A: u32 = 91;
const FARM_B: u32 = 17;

fn tile(id: u32, x: i32, y: i32, kind: TileKind) -> Tile {
    Tile {
        id,
        x,
        y,
        kind,
        enabled: true,
        z: 0,
        width: 1,
        depth: 1,
        clearance_height: 4,
    }
}

/// Sparse operational rows over real material support/clearance and BFS routes.
/// Non-spatial durable IDs intentionally differ from vector and coordinate order.
fn physical_colony() -> World {
    let mut world = new_world();
    world.geometry = Some(Geometry::flat_with_dimensions(8, 8).unwrap());
    world.tiles = vec![
        tile(FARM_A, 1, 1, TileKind::Farm),
        tile(FARM_B, 5, 1, TileKind::Farm),
        tile(63, 3, 3, TileKind::Storage),
        tile(42, 3, 5, TileKind::Dining),
        tile(29, 1, 5, TileKind::Sleep),
        tile(78, 5, 5, TileKind::Recreation),
    ];
    world.work_orders = default_work_orders(&world.tiles);
    world.colonists = [41, 7, 83, 19]
        .into_iter()
        .enumerate()
        .map(|(i, id)| {
            let mut actor = Colonist::new(id, &format!("Farmer {id}"), 3, 3);
            actor.assignment.work = WorkType::Farming;
            actor.needs.hunger = 10.0 + i as f32 * 10.0;
            actor.needs.fatigue = 10.0 + i as f32 * 8.0;
            actor.needs.recreation = 5.0 + i as f32 * 12.0;
            actor
        })
        .collect();
    world.resources.food = 40.0;
    world.haul_policy = HaulPolicy::DedicatedHaulers;
    world
}

fn enabled(world: &mut World, kind: TileKind, value: bool) {
    for tile in &mut world.tiles {
        if tile.kind == kind {
            tile.enabled = value;
        }
    }
}

fn pile(world: &mut World, tile_id: u32, amount: f32) {
    let tile = world.tiles.iter().find(|tile| tile.id == tile_id).unwrap();
    world.stacks.push(ItemStack {
        id: stack_id(tile_id, ResourceKind::Food),
        tile_id,
        x: tile.x,
        y: tile.y,
        z: tile.z,
        kind: ResourceKind::Food,
        amount,
    });
    world.stacks.sort_by_key(|stack| stack.id);
}

fn food_total(world: &World) -> f32 {
    world.resources.food
        + world
            .stacks
            .iter()
            .filter(|s| s.kind == ResourceKind::Food)
            .map(|s| s.amount)
            .sum::<f32>()
        + world
            .colonists
            .iter()
            .filter(|c| c.cargo.kind == ResourceKind::Food)
            .map(|c| c.cargo.amount)
            .sum::<f32>()
}

fn close(actual: f32, expected: f32) {
    assert!(
        (actual - expected).abs() < 0.003,
        "actual {actual}, expected {expected}"
    );
}

fn sound(world: &World) {
    assert!(world.resources.food.is_finite() && world.resources.food >= 0.0);
    assert!(world.stacks.windows(2).all(|s| s[0].id < s[1].id));
    for stack in &world.stacks {
        assert!(stack.amount.is_finite() && stack.amount > 0.0);
        assert_eq!(stack.id, stack_id(stack.tile_id, stack.kind));
    }
    let geometry = world.geometry.as_ref().unwrap();
    for actor in &world.colonists {
        assert!(geometry.supported(
            Cell(actor.position.x, actor.position.y, actor.spatial.z),
            actor.spatial.body
        ));
        assert!(actor.cargo.amount.is_finite() && actor.cargo.amount >= 0.0);
        for need in [
            actor.needs.hunger,
            actor.needs.fatigue,
            actor.needs.recreation,
        ] {
            assert!(need.is_finite() && (0.0..=100.0).contains(&need));
        }
    }
}

fn unattended(world: &mut World, tuning: &Tuning, hours: u32) -> Vec<SimEvent> {
    unattended_checked(world, tuning, hours, |_| {})
}

fn unattended_checked(
    world: &mut World,
    tuning: &Tuning,
    hours: u32,
    mut observe: impl FnMut(&World),
) -> Vec<SimEvent> {
    let mut events = Vec::new();
    for _ in 0..hours {
        events.extend(step(world, tuning, 3600.0));
        sound(world);
        observe(world);
    }
    events
}

fn mean_hunger(world: &World) -> f32 {
    world.colonists.iter().map(|c| c.needs.hunger).sum::<f32>() / world.colonists.len() as f32
}

fn isolated_logistics() -> Tuning {
    Tuning {
        hunger_per_hour: 0.0,
        fatigue_per_hour: 0.0,
        work_fatigue_per_hour: 0.0,
        recreation_per_hour: 0.0,
        output_food_per_hour: 0.0,
        ..Tuning::default()
    }
}

#[test]
fn food_requires_delivery_and_storage_loss_preserves_carried_goods() {
    let mut world = physical_colony();
    let tuning = isolated_logistics();
    world.haul_policy = HaulPolicy::SelfHaul;
    world.work_orders.clear();
    world.resources.food = 0.0;
    let mut eater = Colonist::new(2, "Hungry", 3, 5);
    eater.needs.hunger = 80.0;
    let mut hauler = Colonist::new(9, "Carrier", 1, 1);
    hauler.assignment.work = WorkType::Farming;
    world.colonists = vec![hauler, eater];
    pile(&mut world, FARM_A, 30.0);
    enabled(&mut world, TileKind::Storage, false);

    let events = step(&mut world, &tuning, 600.0);
    assert!(!events.iter().any(|e| matches!(
        e,
        SimEvent::ActivityChanged {
            to: Activity::Eating,
            ..
        }
    )));
    close(
        world
            .colonists
            .iter()
            .find(|c| c.id == 2)
            .unwrap()
            .needs
            .hunger,
        80.0,
    );
    close(food_total(&world), 30.0);
    assert!(world.colonists.iter().all(|c| !c.is_carrying()));

    enabled(&mut world, TileKind::Storage, true);
    step(&mut world, &tuning, 60.0);
    assert!(world
        .colonists
        .iter()
        .find(|c| c.id == 9)
        .unwrap()
        .is_carrying());
    close(world.resources.food, 0.0);
    enabled(&mut world, TileKind::Storage, false);
    step(&mut world, &tuning, 600.0);
    close(food_total(&world), 30.0);
    close(
        world
            .colonists
            .iter()
            .find(|c| c.id == 9)
            .unwrap()
            .cargo
            .amount,
        30.0,
    );

    enabled(&mut world, TileKind::Storage, true);
    let mut saw_deposit = false;
    let mut saw_eat = false;
    for _ in 0..60 {
        let before = food_total(&world);
        let hunger_before: f32 = world.colonists.iter().map(|c| c.needs.hunger).sum();
        step(&mut world, &tuning, 60.0);
        let hunger_after: f32 = world.colonists.iter().map(|c| c.needs.hunger).sum();
        close(
            before - food_total(&world),
            (hunger_before - hunger_after) * tuning.food_per_hunger,
        );
        if world.resources.food > 0.0 {
            saw_deposit = true;
        }
        if hunger_after < hunger_before {
            assert!(saw_deposit, "consumption must follow a real delivery");
            saw_eat = true;
        }
        sound(&world);
    }
    assert!(saw_deposit && saw_eat);
    assert!(
        world
            .colonists
            .iter()
            .find(|c| c.id == 2)
            .unwrap()
            .needs
            .hunger
            <= tuning.eat_stop
    );
    close(
        food_total(&world),
        30.0 - (80.0
            - world
                .colonists
                .iter()
                .find(|c| c.id == 2)
                .unwrap()
                .needs
                .hunger)
            * tuning.food_per_hunger,
    );
}

#[test]
fn observe_stabilize_fail_and_recover_with_operator_policy_and_orders() {
    let mut world = physical_colony();
    let tuning = Tuning {
        output_food_per_hour: 6.0,
        ..Tuning::default()
    };
    let initial_seconds = world.game_seconds;
    let stable_events = unattended(&mut world, &tuning, 24);
    assert!(stable_events.iter().any(|e| matches!(
        e,
        SimEvent::ActivityChanged {
            to: Activity::Hauling,
            ..
        }
    )));
    assert!(world.resources.food > 0.0);
    assert!(world.avg_mood() > 60.0);
    let stable_mood = world.avg_mood();

    enabled(&mut world, TileKind::Storage, false);
    enabled(&mut world, TileKind::Recreation, false);
    let mut failure_events = unattended(&mut world, &tuning, 24);
    assert!(world.stacks.iter().any(|s| s.amount > 0.0));
    for order in &mut world.work_orders {
        order.enabled = false;
    }
    failure_events.extend(unattended(&mut world, &tuning, 144));
    assert!(failure_events
        .iter()
        .any(|e| matches!(e, SimEvent::MealMissed { .. })));
    assert!(failure_events
        .iter()
        .any(|e| matches!(e, SimEvent::RecreationDenied { .. })));
    assert!(mean_hunger(&world) > 90.0);
    assert!(world.avg_recreation() > 90.0);
    assert!(world.avg_mood() < stable_mood - 30.0);
    let failed_ema = world.mood_ema;
    let mut untreated = world.clone();

    enabled(&mut world, TileKind::Storage, true);
    enabled(&mut world, TileKind::Recreation, true);
    world.haul_policy = HaulPolicy::SelfHaul;
    world.meal_policy = MealPolicy::Rationed;
    for order in &mut world.work_orders {
        order.enabled = order.tile_id == FARM_B;
        if order.enabled {
            order.priority = 1;
        }
    }
    let recovery_food = food_total(&world);
    let mut old_pile = world.stack_amount(FARM_A, ResourceKind::Food);
    let mut saw_selected_work = false;
    let recovery_events = unattended_checked(&mut world, &tuning, 96, |world| {
        let remaining = world.stack_amount(FARM_A, ResourceKind::Food);
        assert!(
            remaining <= old_pile,
            "disabled order cannot replenish leftovers"
        );
        old_pile = remaining;
        for actor in &world.colonists {
            if actor.task.activity == Activity::Working {
                assert_eq!((actor.position.x, actor.position.y), (5, 1));
                saw_selected_work = true;
            }
        }
    });
    unattended(&mut untreated, &tuning, 96);
    assert!(recovery_events.iter().any(|e| matches!(
        e,
        SimEvent::ActivityChanged {
            to: Activity::Eating,
            ..
        }
    )));
    assert!(recovery_events.iter().any(|e| matches!(
        e,
        SimEvent::ActivityChanged {
            to: Activity::Recreating,
            ..
        }
    )));
    assert!(world.resources.food > 0.0);
    assert!(saw_selected_work);
    assert!(
        food_total(&world) > recovery_food + 100.0,
        "recovery includes new production, not just draining leftovers"
    );
    assert!(mean_hunger(&world) < 60.0);
    assert!(world.avg_recreation() < 60.0);
    assert!(world.mood_ema > failed_ema + 20.0);
    assert!(world.avg_productivity() > untreated.avg_productivity() + 20.0);
    assert!(untreated.avg_recreation() > 90.0 && mean_hunger(&untreated) > 90.0);
    assert_eq!(
        world.game_seconds,
        initial_seconds + (24.0 + 168.0 + 96.0) * 3600.0
    );
    close(world.stack_amount(FARM_A, ResourceKind::Food), 0.0);
    assert!(world
        .work_orders
        .iter()
        .filter(|o| o.enabled)
        .all(|o| o.tile_id == FARM_B && o.priority == 1));
}

/// Model unordered database row arrival at the pure-core boundary. Stacks are
/// normalized here because World explicitly requires ascending stack IDs.
fn reload_permuted(mut world: World, rotation: usize) -> World {
    world.colonists.reverse();
    world.colonists.rotate_left(rotation);
    world.tiles.reverse();
    world.tiles.rotate_left(rotation);
    world.work_orders.reverse();
    world.production_policies.reverse();
    if let Some(geometry) = &mut world.geometry {
        geometry.designations.reverse();
    }
    world.stacks.reverse();
    world.stacks.sort_by_key(|s| s.id);
    world.navigation = Default::default();
    world
}

fn canonical(mut world: World) -> World {
    world.colonists.sort_by_key(|c| c.id);
    world.tiles.sort_by_key(|t| t.id);
    world.work_orders.sort_by_key(|o| o.id);
    world
        .production_policies
        .sort_by_key(|p| p.resource.index());
    if let Some(geometry) = &mut world.geometry {
        geometry.designations.sort_by_key(|d| d.id);
    }
    world.navigation = Default::default();
    world
}

/// Compare every public step's events and full authority, including new ecology,
/// targets, excavation progress/materials and dirty sets, not just food totals.
fn mirrored_step(world: &mut World, variants: &mut [World], tuning: &Tuning, seconds: f64) {
    let events = step(world, tuning, seconds);
    sound(world);
    for variant in variants {
        assert_eq!(step(variant, tuning, seconds), events);
        assert_eq!(canonical(variant.clone()), canonical(world.clone()));
    }
}

fn mirrored_edit(world: &mut World, variants: &mut [World], edit: impl Fn(&mut World)) {
    edit(world);
    for variant in variants {
        edit(variant);
    }
}

fn constant_productivity() -> Tuning {
    Tuning {
        output_food_per_hour: 60.0,
        output_stone_per_hour: 15.0,
        mood_rate_per_hour: 0.0,
        prod_base: 100.0,
        prod_w_fatigue: 0.0,
        prod_w_mood_deficit: 0.0,
        ..isolated_logistics()
    }
}

#[test]
fn ecological_piles_target_hold_delivery_and_consumption_preserve_manual_intent() {
    let mut world = physical_colony();
    let tuning = constant_productivity();
    world.haul_policy = HaulPolicy::SelfHaul;
    world.resources.food = 2.0;
    world.ecology.insert(
        FARM_A,
        TerrainFields {
            soil_fertility: 0.0,
            moisture: 0.0,
            forest_density: 0.0,
        },
    );
    world.ecology.insert(
        FARM_B,
        TerrainFields {
            soil_fertility: 1.0,
            moisture: 1.0,
            forest_density: 0.0,
        },
    );
    world.production_policies = vec![
        ProductionPolicy::new(ResourceKind::Food, 5.0).unwrap(),
        ProductionPolicy::new(ResourceKind::Wood, 9.0).unwrap(),
    ];
    for actor in &mut world.colonists {
        actor.needs.hunger = 0.0;
        actor.needs.fatigue = 0.0;
        actor.needs.recreation = 0.0;
        actor.wellbeing.productivity = 100.0;
        let (x, y) = match actor.id {
            7 => (1, 1),
            19 => (5, 1),
            41 => {
                actor.assignment.work = WorkType::None;
                (3, 5)
            }
            83 => {
                actor.assignment.work = WorkType::None;
                actor.cargo.kind = ResourceKind::Food;
                actor.cargo.amount = 1.0;
                (3, 3)
            }
            _ => unreachable!(),
        };
        actor.position.x = x;
        actor.position.y = y;
        actor.movement.target = actor.position;
        actor.spatial.next = Cell(x, y, 0);
    }
    enabled(&mut world, TileKind::Storage, false);
    let original_orders = world.work_orders.clone();
    let mut variants: Vec<_> = (0..4).map(|r| reload_permuted(world.clone(), r)).collect();

    mirrored_step(&mut world, &mut variants, &tuning, 60.0);
    close(world.stack_amount(FARM_A, ResourceKind::Food), 0.5);
    close(world.stack_amount(FARM_B, ResourceKind::Food), 1.5);
    close(world.resources.food, 2.0);
    assert_eq!(world.total_supply(ResourceKind::Food), 5.0);
    assert!(!world.production_allowed(ResourceKind::Food));
    mirrored_step(&mut world, &mut variants, &tuning, 600.0);
    assert_eq!(world.total_supply(ResourceKind::Food), 5.0);
    assert_eq!(world.work_orders, original_orders);
    assert!(world.work_orders.iter().all(|o| o.enabled));

    mirrored_edit(&mut world, &mut variants, |w| {
        enabled(w, TileKind::Storage, true)
    });
    mirrored_step(&mut world, &mut variants, &tuning, 60.0);
    close(world.resources.food, 3.0);
    close(world.colonists.iter().map(|c| c.cargo.amount).sum(), 2.0);
    assert!(world.stacks.is_empty());
    for _ in 0..10 {
        mirrored_step(&mut world, &mut variants, &tuning, 60.0);
        assert_eq!(world.total_supply(ResourceKind::Food), 5.0);
        assert!(!world.production_allowed(ResourceKind::Food));
    }
    close(world.resources.food, 5.0);
    assert_eq!(world.work_orders, original_orders);

    mirrored_edit(&mut world, &mut variants, |w| {
        for order in &mut w.work_orders {
            order.enabled = false;
            order.priority = if order.tile_id == FARM_B { 1 } else { 3 };
        }
        w.colonists
            .iter_mut()
            .find(|c| c.id == 41)
            .unwrap()
            .needs
            .hunger = 80.0;
    });
    mirrored_step(&mut world, &mut variants, &tuning, 60.0);
    assert!(world.production_allowed(ResourceKind::Food));
    assert!(
        world
            .colonists
            .iter()
            .find(|c| c.id == 41)
            .unwrap()
            .needs
            .hunger
            < 80.0
    );
    for _ in 0..10 {
        mirrored_step(&mut world, &mut variants, &tuning, 60.0);
    }
    close(world.resources.food, 0.0);
    assert!(world.stacks.is_empty());
    assert!(world.work_orders.iter().all(|o| !o.enabled));

    mirrored_edit(&mut world, &mut variants, |w| {
        w.work_orders
            .iter_mut()
            .find(|o| o.tile_id == FARM_A)
            .unwrap()
            .enabled = true;
        let actor = w.colonists.iter_mut().find(|c| c.id == 19).unwrap();
        actor.position.x = 5;
        actor.position.y = 1;
        actor.movement.target = actor.position;
        actor.spatial.next = Cell(5, 1, 0);
    });
    let manual_orders = world.work_orders.clone();
    mirrored_step(&mut world, &mut variants, &tuning, 60.0);
    let redirected = world.colonists.iter().find(|c| c.id == 19).unwrap();
    assert_eq!(
        (redirected.movement.target.x, redirected.movement.target.y),
        (1, 1)
    );
    let mut saw_work = false;
    for _ in 0..30 {
        mirrored_step(&mut world, &mut variants, &tuning, 60.0);
        for actor in world
            .colonists
            .iter()
            .filter(|c| c.task.activity == Activity::Working)
        {
            assert_eq!((actor.position.x, actor.position.y), (1, 1));
            saw_work = true;
        }
        close(world.stack_amount(FARM_B, ResourceKind::Food), 0.0);
        assert_eq!(world.work_orders, manual_orders);
    }
    assert!(saw_work);
    close(world.resources.food, 5.0);
    assert_eq!(world.total_supply(ResourceKind::Food), 5.0);
    assert!(!world.production_allowed(ResourceKind::Food));
    mirrored_edit(&mut world, &mut variants, |w| {
        w.resources.food -= 0.5;
        w.work_orders
            .iter_mut()
            .find(|o| o.tile_id == FARM_B)
            .unwrap()
            .enabled = true;
        for actor in w.colonists.iter_mut().filter(|c| [7, 19].contains(&c.id)) {
            actor.position.x = 1;
            actor.position.y = 1;
            actor.movement.target = actor.position;
            actor.spatial.next = Cell(1, 1, 0);
            actor.task.goal = Goal::Nothing;
            actor.task.activity = Activity::Idle;
        }
    });
    let prioritized_orders = world.work_orders.clone();
    let travel_only = Tuning {
        output_food_per_hour: 0.0,
        ..tuning
    };
    mirrored_step(&mut world, &mut variants, &travel_only, 60.0);
    for actor in world.colonists.iter().filter(|c| [7, 19].contains(&c.id)) {
        assert_eq!((actor.movement.target.x, actor.movement.target.y), (5, 1));
    }
    mirrored_step(&mut world, &mut variants, &tuning, 60.0);
    assert_eq!(
        world
            .colonists
            .iter()
            .find(|c| c.id == 7)
            .unwrap()
            .task
            .activity,
        Activity::Working
    );
    let later = world.colonists.iter().find(|c| c.id == 19).unwrap();
    assert_eq!(later.task.goal, Goal::Haul);
    close(later.cargo.amount, 1.5);
    assert_eq!(world.total_supply(ResourceKind::Food), 6.0);
    for _ in 0..10 {
        mirrored_step(&mut world, &mut variants, &tuning, 60.0);
    }
    close(world.resources.food, 6.0);
    assert_eq!(world.work_orders, prioritized_orders);
}

#[test]
fn prioritized_physical_excavation_holds_partial_progress_then_resumes_after_expenditure() {
    let mut world = physical_colony();
    let tuning = constant_productivity();
    world.tiles.retain(|t| t.kind == TileKind::Storage);
    world.work_orders.clear();
    world.haul_policy = HaulPolicy::SelfHaul;
    world.production_policies = vec![ProductionPolicy::new(ResourceKind::Stone, 1.0).unwrap()];
    world.colonists.retain(|c| [7, 19].contains(&c.id));
    for actor in &mut world.colonists {
        actor.assignment.work = WorkType::Mining;
        actor.position.x = 2;
        actor.position.y = 1;
        actor.movement.target = actor.position;
        actor.spatial.next = Cell(2, 1, 0);
        actor.needs.hunger = 0.0;
        actor.needs.fatigue = 0.0;
        actor.needs.recreation = 0.0;
        actor.wellbeing.productivity = 100.0;
    }
    let geometry = world.geometry.as_mut().unwrap();
    geometry.set(Cell(3, 1, 0), STONE);
    geometry.set(Cell(1, 1, 0), STONE);
    let low = geometry.designate(5, 1, 1, 1, 1, 0, 1, 3).unwrap();
    let high = geometry.designate(73, 3, 1, 3, 1, 0, 1, 1).unwrap();
    geometry.designations = vec![low, high];
    enabled(&mut world, TileKind::Storage, false);
    let mut variants: Vec<_> = (0..2).map(|r| reload_permuted(world.clone(), r)).collect();
    mirrored_step(&mut world, &mut variants, &tuning, 60.0);
    let job = |w: &World, id| {
        w.geometry
            .as_ref()
            .unwrap()
            .designations
            .iter()
            .find(|d| d.id == id)
            .unwrap()
            .cells[0]
            .clone()
    };
    close(job(&world, 73).progress, 0.5);
    close(job(&world, 5).progress, 0.0);
    assert_eq!(world.total_supply(ResourceKind::Stone), 0.0);

    mirrored_edit(&mut world, &mut variants, |w| w.resources.stone = 1.0);
    mirrored_step(&mut world, &mut variants, &tuning, 600.0);
    close(job(&world, 73).progress, 0.5);
    assert_eq!(
        world.geometry.as_ref().unwrap().material(Cell(3, 1, 0)),
        Some(STONE)
    );
    assert!(world
        .geometry
        .as_ref()
        .unwrap()
        .designations
        .iter()
        .all(|d| d.enabled));
    mirrored_edit(&mut world, &mut variants, |w| w.resources.stone -= 1.0);
    mirrored_step(&mut world, &mut variants, &tuning, 60.0);
    assert_eq!(job(&world, 73).material, AIR);
    close(job(&world, 73).progress, 1.0);
    close(job(&world, 5).progress, 0.0);
    assert_eq!(world.total_supply(ResourceKind::Stone), 1.0);
    assert_eq!(
        world.geometry.as_ref().unwrap().material(Cell(3, 1, 0)),
        Some(AIR)
    );

    mirrored_edit(&mut world, &mut variants, |w| {
        enabled(w, TileKind::Storage, true)
    });
    mirrored_step(&mut world, &mut variants, &tuning, 60.0);
    close(
        world
            .colonists
            .iter()
            .find(|c| c.id == 7)
            .unwrap()
            .cargo
            .amount,
        1.0,
    );
    for _ in 0..10 {
        mirrored_step(&mut world, &mut variants, &tuning, 60.0);
        assert_eq!(world.total_supply(ResourceKind::Stone), 1.0);
        close(job(&world, 5).progress, 0.0);
    }
    close(world.resources.stone, 1.0);

    mirrored_edit(&mut world, &mut variants, |w| {
        w.geometry
            .as_mut()
            .unwrap()
            .designations
            .iter_mut()
            .find(|d| d.id == 5)
            .unwrap()
            .enabled = false;
        w.resources.stone -= 1.0;
    });
    mirrored_step(&mut world, &mut variants, &tuning, 600.0);
    assert!(world.production_allowed(ResourceKind::Stone));
    close(job(&world, 5).progress, 0.0);
    assert_eq!(
        world.geometry.as_ref().unwrap().material(Cell(1, 1, 0)),
        Some(STONE)
    );
    mirrored_edit(&mut world, &mut variants, |w| {
        w.geometry
            .as_mut()
            .unwrap()
            .designations
            .iter_mut()
            .find(|d| d.id == 5)
            .unwrap()
            .enabled = true;
    });
    for _ in 0..20 {
        mirrored_step(&mut world, &mut variants, &tuning, 60.0);
    }
    assert_eq!(job(&world, 5).material, AIR);
    close(world.resources.stone, 1.0);
    assert_eq!(world.total_supply(ResourceKind::Stone), 1.0);
    assert!(world.stacks.is_empty());
    assert!(world.colonists.iter().all(|c| !c.is_carrying()));
    assert!(world
        .geometry
        .as_ref()
        .unwrap()
        .designations
        .iter()
        .all(|d| d.enabled && d.completed() == 1));
}

#[test]
fn durable_ids_resolve_contended_food_and_piles_independent_of_row_arrival() {
    for policy in [HaulPolicy::SelfHaul, HaulPolicy::DedicatedHaulers] {
        let mut reference = physical_colony();
        let tuning = isolated_logistics();
        reference.haul_policy = policy;
        reference.work_orders.clear();
        reference.resources.food = 0.2;
        reference.colonists.clear();
        for id in [83, 7, 41, 19] {
            let mut actor = Colonist::new(id, "Contender", 3, 5);
            actor.needs.hunger = 80.0;
            actor.needs.fatigue = 0.0;
            actor.needs.recreation = 0.0;
            reference.colonists.push(actor);
        }
        let mut contenders: Vec<_> = (0..4)
            .map(|r| reload_permuted(reference.clone(), r))
            .collect();
        let events = step(&mut reference, &tuning, 60.0);
        close(reference.resources.food, 0.0);
        for actor in &reference.colonists {
            if actor.id == 7 {
                assert!(actor.needs.hunger < 80.0);
            } else {
                close(actor.needs.hunger, 80.0);
            }
        }
        for candidate in &mut contenders {
            assert_eq!(step(candidate, &tuning, 60.0), events);
            assert_eq!(canonical(candidate.clone()), canonical(reference.clone()));
        }

        for actor in &mut reference.colonists {
            actor.needs.hunger = 0.0;
            actor.assignment.work = WorkType::Farming;
            actor.position.x = 3;
            actor.position.y = 1;
            actor.movement.target = actor.position;
            actor.spatial.next = Cell(3, 1, 0);
        }
        pile(&mut reference, FARM_A, 31.0);
        pile(&mut reference, FARM_B, 29.0);
        let initial_total = food_total(&reference);
        contenders = (0..4)
            .map(|r| reload_permuted(reference.clone(), r))
            .collect();
        let mut saw_cargo = false;
        for (interval, duration) in [15.0, 45.0, 60.0, 120.0, 30.0, 90.0, 3600.0]
            .into_iter()
            .enumerate()
        {
            let events = step(&mut reference, &tuning, duration);
            if interval == 0 {
                for actor in reference
                    .colonists
                    .iter()
                    .filter(|c| c.task.activity == Activity::Travelling)
                {
                    assert_eq!((actor.movement.target.x, actor.movement.target.y), (5, 1));
                }
            }
            if interval == 1 {
                let winner = match policy {
                    HaulPolicy::SelfHaul => 7,
                    HaulPolicy::DedicatedHaulers => 19,
                };
                close(
                    reference
                        .colonists
                        .iter()
                        .find(|c| c.id == winner)
                        .unwrap()
                        .cargo
                        .amount,
                    29.0,
                );
            }
            saw_cargo |= reference.colonists.iter().any(|c| c.is_carrying());
            close(food_total(&reference), initial_total);
            sound(&reference);
            for candidate in &mut contenders {
                assert_eq!(step(candidate, &tuning, duration), events);
                assert_eq!(canonical(candidate.clone()), canonical(reference.clone()));
            }
        }
        assert!(saw_cargo);
        close(reference.resources.food, 60.0);
        assert!(reference.stacks.is_empty());
        assert!(reference.colonists.iter().all(|c| !c.is_carrying()));
    }
}
