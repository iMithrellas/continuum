use super::*;

#[test]
fn work_orders_validate_jobs_facilities_priorities_and_stable_ids() {
    let tile = Tile {
        id: u32::MAX,
        x: 0,
        y: 0,
        kind: TileKind::Forest,
        enabled: false,
    };
    assert!(WorkOrder::new(&tile, WorkType::None, 2, true).is_err());
    assert!(WorkOrder::new(&tile, WorkType::Farming, 2, true).is_err());
    for priority in [0, 4, u8::MAX] {
        assert!(WorkOrder::new(&tile, WorkType::Logging, priority, false).is_err());
    }
    for priority in 1..=3 {
        for enabled in [false, true] {
            let order = WorkOrder::new(&tile, WorkType::Logging, priority, enabled).unwrap();
            assert_eq!(order.id, u32::MAX as u64 * 4 + ResourceKind::Wood.index());
            assert_eq!(
                (order.tile_id, order.work, order.priority, order.enabled),
                (tile.id, WorkType::Logging, priority, enabled)
            );
        }
    }
    let orders = default_work_orders(&[tile]);
    assert_eq!(orders.len(), 2);
    assert_eq!(orders[0].work, WorkType::Logging);
    assert_eq!(orders[1].work, WorkType::Hunting);
    assert!(orders
        .iter()
        .all(|order| order.enabled && order.priority == 2));
    let world = new_world();
    assert_eq!(world.work_orders.len(), 78);
    let mut shuffled = world.tiles.clone();
    shuffled.reverse();
    assert_eq!(default_work_orders(&shuffled), world.work_orders);
}

#[test]
fn production_independently_rejects_missing_paused_and_malformed_orders() {
    let (world, tuning) = hauling_world(WorkType::Farming, HaulPolicy::SelfHaul);
    for invalid in 0..7 {
        let mut world = world.clone();
        match invalid {
            0 => world.work_orders.clear(),
            1 => world.work_orders[0].enabled = false,
            2 => world.work_orders[0].priority = 0,
            3 => world.work_orders[0].id += 1,
            4 => world.work_orders[0].tile_id += 1,
            5 => world.work_orders[0].work = WorkType::Hunting,
            _ => world.tiles[0].kind = TileKind::Forest,
        }
        step_work(&mut world, 0, &tuning, 1.0);
        assert!(world.stacks.is_empty(), "invalid case {invalid}");
        step(&mut world, &tuning, 120.0);
        assert!(world.stacks.is_empty());
        assert!(world.colonists.iter().all(|c| c.goal == Goal::Nothing));
    }
}

fn two_site_world(policy: HaulPolicy) -> (World, Tuning) {
    let (mut world, mut tuning) = hauling_world(WorkType::Farming, policy);
    world.tiles.push(Tile {
        id: 3,
        x: 8,
        y: 0,
        kind: TileKind::Farm,
        enabled: true,
    });
    world.work_orders = default_work_orders(&world.tiles);
    tuning.move_tiles_per_hour = 15.0;
    (world, tuning)
}

#[test]
fn work_priority_beats_distance_and_reprioritization_redirects_work_and_travel() {
    for policy in [HaulPolicy::SelfHaul, HaulPolicy::DedicatedHaulers] {
        let (mut world, tuning) = two_site_world(policy);
        // Keep pickups out of this test while production continues.
        world.tiles[1].enabled = false;
        step(&mut world, &tuning, 60.0);
        assert_eq!(world.colonists[0].activity, Activity::Working);
        world.work_orders[1].priority = 1;
        let before = world.stack_amount(1, ResourceKind::Food);
        step(&mut world, &tuning, 60.0);
        assert_eq!(world.colonists[0].target_x, 8);
        assert_eq!(world.colonists[0].activity, Activity::Travelling);
        assert_eq!(world.stack_amount(1, ResourceKind::Food), before);
        assert_eq!(world.colonists[0].move_progress, 0.25);
        step(&mut world, &tuning, 60.0);
        assert_eq!(world.colonists[0].move_progress, 0.5);
        world.work_orders[0].priority = 1;
        world.work_orders[1].priority = 3;
        step(&mut world, &tuning, 60.0);
        assert_eq!(world.colonists[0].target_x, 0);
        assert_eq!(world.colonists[0].activity, Activity::Working);
    }
}

#[test]
fn work_and_pickup_ties_use_distance_then_id_independent_of_row_order() {
    for policy in [HaulPolicy::SelfHaul, HaulPolicy::DedicatedHaulers] {
        for pickup in [false, true] {
            for reverse in [false, true] {
                let (mut world, tuning) = two_site_world(policy);
                for c in &mut world.colonists {
                    c.x = 4;
                }
                if pickup {
                    world.add_to_stack(
                        &world.tiles[0].clone(),
                        ResourceKind::Food,
                        tuning.stack_food,
                    );
                    world.add_to_stack(
                        &world.tiles[2].clone(),
                        ResourceKind::Food,
                        tuning.stack_food,
                    );
                }
                if reverse {
                    world.tiles.reverse();
                    world.work_orders.reverse();
                    world.colonists.reverse();
                }
                let index = world
                    .colonists
                    .iter()
                    .position(|c| c.id == if pickup { 2 } else { 1 })
                    .unwrap();
                let goal = if pickup { Goal::Haul } else { Goal::Work };
                assert_eq!(destination_for(&world, index, &tuning, goal).unwrap().id, 1);
                world.colonists[index].x = 5;
                assert_eq!(destination_for(&world, index, &tuning, goal).unwrap().id, 3);
                step(&mut world, &tuning, 60.0);
                assert_eq!(world.colonists[index].target_x, 8);
            }
        }
    }
}

#[test]
fn cancelling_work_preserves_travel_progress_when_cleanup_has_the_same_target() {
    let (mut world, mut tuning) = hauling_world(WorkType::Farming, HaulPolicy::SelfHaul);
    tuning.move_tiles_per_hour = 15.0;
    world.colonists.truncate(1);
    let c = &mut world.colonists[0];
    c.x = 4;
    c.goal = Goal::Work;
    c.activity = Activity::Travelling;
    c.move_progress = 0.5;
    world.add_to_stack(&world.tiles[0].clone(), ResourceKind::Food, 1.0);
    step(&mut world, &tuning, 60.0);
    assert_eq!(world.colonists[0].goal, Goal::Work);
    assert_eq!(world.colonists[0].move_progress, 0.75);
    world.work_orders.clear();
    step(&mut world, &tuning, 60.0);
    assert_eq!(world.colonists[0].goal, Goal::Haul);
    assert_eq!(world.colonists[0].x, 3);
    assert_eq!(world.colonists[0].move_progress, 0.0);
}

#[test]
fn cancel_and_pause_stop_moving_and_working_producers_and_release_partial_piles() {
    for policy in [HaulPolicy::SelfHaul, HaulPolicy::DedicatedHaulers] {
        for cancel in [false, true] {
            for moving in [false, true] {
                let (mut world, tuning) = hauling_world(WorkType::Farming, policy);
                step(&mut world, &tuning, 60.0);
                let amount = world.stack_amount(1, ResourceKind::Food);
                assert!(amount > 0.0 && amount < tuning.stack_food);
                if moving {
                    for c in &mut world.colonists {
                        c.x = 2;
                        c.goal = Goal::Work;
                        c.activity = Activity::Travelling;
                    }
                }
                if cancel {
                    world.work_orders.clear();
                } else {
                    world.work_orders[0].enabled = false;
                }
                // A stale work activity must not bypass the order gate.
                step_work(&mut world, 0, &tuning, 1.0);
                assert_eq!(world.stack_amount(1, ResourceKind::Food), amount);
                let before = world.resources.food;
                step(&mut world, &tuning, 60.0);
                assert!(world.colonists.iter().all(|c| c.goal != Goal::Work));
                step(&mut world, &tuning, 10.0 * 60.0);
                assert!(world.stacks.is_empty());
                assert!(world.colonists.iter().all(|c| !c.is_carrying()));
                assert!((world.resources.food - before - amount).abs() < 1.0e-4);
            }
        }
    }
}

#[test]
fn pickup_priorities_redirect_empty_travel_and_cleanup_defaults_to_low() {
    for policy in [HaulPolicy::SelfHaul, HaulPolicy::DedicatedHaulers] {
        for cleanup in 0..3 {
            let (mut world, tuning) = two_site_world(policy);
            world.colonists.retain(|c| c.id == 2);
            // Preserve the dedicated hauler's rank with an unproductive producer.
            if policy == HaulPolicy::DedicatedHaulers {
                let mut producer = Colonist::new(1, "Producer", 0, 0);
                producer.work = WorkType::Farming;
                producer.carried_amount = 1.0;
                world.colonists.push(producer);
            }
            world.colonists[0].x = 2;
            world.add_to_stack(
                &world.tiles[0].clone(),
                ResourceKind::Food,
                tuning.stack_food,
            );
            world.add_to_stack(
                &world.tiles[2].clone(),
                ResourceKind::Food,
                tuning.stack_food,
            );
            step(&mut world, &tuning, 60.0);
            assert_eq!(world.colonists[0].target_x, 0);
            world.work_orders[1].priority = 1;
            step(&mut world, &tuning, 60.0);
            assert_eq!(world.colonists[0].target_x, 8);
            step(&mut world, &tuning, 60.0);
            assert_eq!(world.colonists[0].move_progress, 0.5);
            match cleanup {
                0 => {
                    world.work_orders.remove(1);
                }
                1 => world.work_orders[1].enabled = false,
                _ => world.tiles[2].enabled = false,
            }
            // Cleanup priority 3 loses to the other active order's normal 2.
            assert_eq!(
                destination_for(&world, 0, &tuning, Goal::Haul).unwrap().id,
                1
            );
            world.work_orders[0].priority = 3;
            world.colonists[0].x = 6;
            assert_eq!(
                destination_for(&world, 0, &tuning, Goal::Haul).unwrap().id,
                3
            );
        }
    }
}

#[test]
fn order_changes_preserve_needs_and_deliver_existing_cargo() {
    for policy in [HaulPolicy::SelfHaul, HaulPolicy::DedicatedHaulers] {
        for (kind, goal) in [
            (TileKind::Dining, Goal::Eat),
            (TileKind::Sleep, Goal::Sleep),
            (TileKind::Recreation, Goal::Recreate),
        ] {
            let (mut world, tuning) = two_site_world(policy);
            world.colonists.truncate(1);
            world.tiles.push(Tile {
                id: 4,
                x: 0,
                y: 1,
                kind,
                enabled: true,
            });
            let c = &mut world.colonists[0];
            c.carried_kind = ResourceKind::Wood;
            c.carried_amount = 7.0;
            match goal {
                Goal::Eat => c.hunger = 80.0,
                Goal::Sleep => c.fatigue = 80.0,
                _ => c.recreation = 80.0,
            }
            step(&mut world, &tuning, 60.0);
            assert_eq!(world.colonists[0].goal, goal);
            world.work_orders[1].priority = 1;
            step(&mut world, &tuning, 4.0 * 60.0);
            assert_eq!(world.colonists[0].activity, goal.activity());
            world.work_orders.clear();
            step(&mut world, &tuning, 60.0);
            assert_eq!(world.colonists[0].goal, goal);
            assert_eq!(world.colonists[0].carried_amount, 7.0);
            step(&mut world, &tuning, 8.0 * 3600.0);
            assert_eq!(world.resources.wood, 7.0);
            assert!(!world.colonists[0].is_carrying());
            assert!(world.stacks.is_empty());
        }
    }
}

#[test]
fn forest_orders_rank_and_pause_logging_and_hunting_independently() {
    for policy in [HaulPolicy::SelfHaul, HaulPolicy::DedicatedHaulers] {
        let (mut world, tuning) = hauling_world(WorkType::Logging, policy);
        world.tiles.push(Tile {
            id: 3,
            x: 8,
            y: 0,
            kind: TileKind::Forest,
            enabled: true,
        });
        world.work_orders = default_work_orders(&world.tiles);
        for id in 3..=4 {
            let mut hunter = Colonist::new(id, "Hunter", 0, 0);
            hunter.work = WorkType::Hunting;
            world.colonists.push(hunter);
        }
        for order in &mut world.work_orders {
            order.priority = if (order.work == WorkType::Logging) == (order.tile_id == 3) {
                1
            } else {
                3
            };
        }
        step(&mut world, &tuning, 60.0);
        assert_eq!(world.colonists[0].target_x, 8);
        assert_eq!(world.colonists[2].target_x, 0);
        // Cancel only logging, leaving both hunting orders active.
        world
            .work_orders
            .retain(|order| order.work != WorkType::Logging);
        world.add_to_stack(&world.tiles[0].clone(), ResourceKind::Wood, 2.0);
        step(&mut world, &tuning, 20.0 * 60.0);
        assert_eq!(world.resources.wood, 2.0);
        assert!(world.stack_amount(1, ResourceKind::Meat) > 0.0);
        assert!(world
            .stacks
            .iter()
            .all(|stack| stack.kind == ResourceKind::Meat));
        assert!(world
            .colonists
            .iter()
            .filter(|c| c.work == WorkType::Logging)
            .all(|c| c.goal != Goal::Work));
        assert!(world
            .colonists
            .iter()
            .filter(|c| c.is_carrying())
            .all(|c| c.carried_kind == c.work.definition().unwrap().output));
    }
}

fn hauling_world(work: WorkType, policy: HaulPolicy) -> (World, Tuning) {
    let mut world = new_world();
    world.haul_policy = policy;
    world.tiles = [work.definition().unwrap().facility, TileKind::Storage]
        .into_iter()
        .enumerate()
        .map(|(index, kind)| Tile {
            id: index as u32 + 1,
            x: index as i32 * 3,
            y: 0,
            kind,
            enabled: true,
        })
        .collect();
    world.work_orders = default_work_orders(&world.tiles);
    world.colonists = (1..=2)
        .map(|id| {
            let mut colonist = Colonist::new(id, "Worker", 0, 0);
            colonist.work = work;
            colonist.productivity = 100.0;
            colonist
        })
        .collect();
    let tuning = Tuning {
        hunger_per_hour: 0.0,
        fatigue_per_hour: 0.0,
        work_fatigue_per_hour: 0.0,
        recreation_per_hour: 0.0,
        prod_base: 100.0,
        prod_w_fatigue: 0.0,
        prod_w_mood_deficit: 0.0,
        move_tiles_per_hour: 60.0,
        ..Tuning::default()
    };
    (world, tuning)
}

#[test]
fn each_job_produces_and_delivers_under_both_policies() {
    for work in [
        WorkType::Farming,
        WorkType::Logging,
        WorkType::Mining,
        WorkType::Hunting,
    ] {
        for policy in [HaulPolicy::SelfHaul, HaulPolicy::DedicatedHaulers] {
            let (mut world, tuning) = hauling_world(work, policy);
            let before = world.resources.clone();
            let kind = work.definition().unwrap().output;
            for _ in 0..360 {
                step(&mut world, &tuning, 60.0);
                for colonist in &world.colonists {
                    assert!(colonist.carried_amount <= tuning.stack_size(kind));
                    if policy == HaulPolicy::DedicatedHaulers {
                        if colonist.id == 1 {
                            assert!(!colonist.is_carrying());
                        } else {
                            assert_ne!(colonist.activity, Activity::Working);
                        }
                    }
                }
            }
            assert!(
                world.resources.amount(kind) > before.amount(kind),
                "{work:?} / {policy:?}"
            );
            for other in RESOURCE_KINDS {
                if other != kind {
                    assert_eq!(world.resources.amount(other), before.amount(other));
                }
            }
        }
    }
}

#[test]
fn dedicated_roles_follow_ids_not_row_order() {
    let mut world = new_world();
    world.haul_policy = HaulPolicy::DedicatedHaulers;
    world.colonists.reverse();
    assign_haul_roles(&mut world);
    for colonist in &world.colonists {
        assert_eq!(
            colonist.haul_role,
            if colonist.id % 2 == 1 {
                HaulRole::Producer
            } else {
                HaulRole::Hauler
            }
        );
    }
}

#[test]
fn policy_changes_cancel_incompatible_work_and_empty_pickups() {
    let (mut world, tuning) = hauling_world(WorkType::Farming, HaulPolicy::SelfHaul);
    step(&mut world, &tuning, 60.0);
    assert!(world.colonists.iter().all(|c| c.goal == Goal::Work));
    world.haul_policy = HaulPolicy::DedicatedHaulers;
    step(&mut world, &tuning, 60.0);
    assert_eq!(world.colonists[1].goal, Goal::Nothing);
    world.haul_policy = HaulPolicy::SelfHaul;
    step(&mut world, &tuning, 60.0);
    assert_eq!(world.colonists[1].goal, Goal::Work);

    world.add_to_stack(
        &world.tiles[0].clone(),
        ResourceKind::Food,
        tuning.stack_food,
    );
    world.colonists[0].goal = Goal::Haul;
    world.colonists[0].activity = Activity::Travelling;
    world.colonists[0].x = 1;
    world.haul_policy = HaulPolicy::DedicatedHaulers;
    step(&mut world, &tuning, 60.0);
    assert_eq!(world.colonists[0].goal, Goal::Work);
    assert!(!world.colonists[0].is_carrying());
    assert_eq!(world.colonists[1].carried_amount, tuning.stack_food);
}

#[test]
fn carried_goods_survive_policy_changes_and_unassignment() {
    for policy in [HaulPolicy::SelfHaul, HaulPolicy::DedicatedHaulers] {
        for work in [WorkType::Farming, WorkType::None] {
            let (mut world, tuning) = hauling_world(WorkType::Farming, policy);
            world.colonists.truncate(1);
            world.colonists[0].carried_kind = ResourceKind::Wood;
            world.colonists[0].carried_amount = tuning.stack_wood;
            world.colonists[0].goal = Goal::Work;
            step(&mut world, &tuning, 60.0);
            assert_eq!(world.colonists[0].goal, Goal::Haul);
            world.haul_policy = match policy {
                HaulPolicy::SelfHaul => HaulPolicy::DedicatedHaulers,
                HaulPolicy::DedicatedHaulers => HaulPolicy::SelfHaul,
            };
            world.colonists[0].work = work;
            step(&mut world, &tuning, 3.0 * 60.0);
            assert_eq!(world.resources.wood, tuning.stack_wood);
            assert!(!world.colonists[0].is_carrying());
        }
    }
}

#[test]
fn disabled_storage_blocks_pickup_but_not_production() {
    let (mut world, tuning) = hauling_world(WorkType::Farming, HaulPolicy::DedicatedHaulers);
    world.tiles[1].enabled = false;
    world.add_to_stack(
        &world.tiles[0].clone(),
        ResourceKind::Food,
        tuning.stack_food,
    );
    let before = world.resources.food;
    step(&mut world, &tuning, 60.0);
    assert!(world.stack_amount(1, ResourceKind::Food) > tuning.stack_food);
    assert!(world.colonists.iter().all(|c| !c.is_carrying()));
    assert_eq!(world.colonists[1].goal, Goal::Nothing);
    assert_eq!(world.resources.food, before);
    world.tiles[1].enabled = true;
    step(&mut world, &tuning, 5.0 * 60.0);
    assert_eq!(world.resources.food, before + tuning.stack_food);
}

#[test]
fn carriers_wait_with_goods_and_retarget_enabled_storage() {
    let (mut world, tuning) = hauling_world(WorkType::Farming, HaulPolicy::SelfHaul);
    world.colonists.truncate(1);
    world.colonists[0].carried_amount = 12.0;
    let before = world.resources.food;
    step(&mut world, &tuning, 60.0);
    assert_eq!(world.colonists[0].target_x, 3);
    world.tiles[1].enabled = false;
    step(&mut world, &tuning, 60.0);
    assert_eq!(world.colonists[0].goal, Goal::Nothing);
    assert_eq!(world.colonists[0].carried_amount, 12.0);
    assert!(world.stacks.is_empty());
    world.tiles.push(Tile {
        id: 3,
        x: 2,
        y: 0,
        kind: TileKind::Storage,
        enabled: true,
    });
    step(&mut world, &tuning, 2.0 * 60.0);
    assert_eq!(world.colonists[0].target_x, 2);
    assert_eq!(world.resources.food, before + 12.0);
    assert!(!world.colonists[0].is_carrying());
}

#[test]
fn disabled_work_tiles_stop_production_but_allow_partial_pickups() {
    for policy in [HaulPolicy::SelfHaul, HaulPolicy::DedicatedHaulers] {
        let (mut world, tuning) = hauling_world(WorkType::Farming, policy);
        step(&mut world, &tuning, 60.0);
        let amount = world.stack_amount(1, ResourceKind::Food);
        let before = world.resources.food;
        world.tiles[0].enabled = false;
        step(&mut world, &tuning, 5.0 * 60.0);
        assert!(world.stacks.is_empty());
        assert!((world.resources.food - before - amount).abs() < 1.0e-4);
        assert!(world
            .colonists
            .iter()
            .all(|c| c.activity != Activity::Working));
    }
}

#[test]
fn dedicated_haulers_batch_active_output_and_collect_when_producer_rests() {
    let (mut world, tuning) = hauling_world(WorkType::Farming, HaulPolicy::DedicatedHaulers);
    step(&mut world, &tuning, 10.0 * 60.0);
    assert_eq!(world.colonists[1].goal, Goal::Nothing);
    assert!(world.stack_amount(1, ResourceKind::Food) > 0.0);
    world.tiles.push(Tile {
        id: 3,
        x: 0,
        y: 1,
        kind: TileKind::Sleep,
        enabled: true,
    });
    world.colonists[0].fatigue = 80.0;
    let amount = world.stack_amount(1, ResourceKind::Food);
    step(&mut world, &tuning, 60.0);
    assert_eq!(world.colonists[0].goal, Goal::Sleep);
    assert_eq!(world.colonists[1].carried_amount, amount);
    assert!(world.stacks.is_empty());
}

#[test]
fn competing_pickups_conserve_goods_and_retarget_depleted_piles() {
    for amount in [30.0, 35.0] {
        let (mut world, mut tuning) = hauling_world(WorkType::Farming, HaulPolicy::SelfHaul);
        tuning.output_food_per_hour = 0.0;
        let before = world.resources.food;
        world.add_to_stack(&world.tiles[0].clone(), ResourceKind::Food, amount);
        for colonist in &mut world.colonists {
            colonist.goal = Goal::Haul;
            colonist.activity = Activity::Hauling;
        }
        step(&mut world, &tuning, 60.0);
        assert_eq!(world.colonists[0].carried_amount, 30.0);
        assert_eq!(world.colonists[1].carried_amount, amount - 30.0);
        assert!(world.stacks.is_empty());
        if amount == 30.0 {
            assert_eq!(world.colonists[1].goal, Goal::Work);
        }
        step(&mut world, &tuning, 4.0 * 60.0);
        assert_eq!(world.resources.food, before + amount);
    }
}

#[test]
fn work_and_pickup_targets_follow_remaining_facilities_and_piles() {
    let (mut world, tuning) = hauling_world(WorkType::Farming, HaulPolicy::SelfHaul);
    world.colonists.truncate(1);
    world.tiles.push(Tile {
        id: 3,
        x: 6,
        y: 0,
        kind: TileKind::Farm,
        enabled: true,
    });
    world.work_orders = default_work_orders(&world.tiles);
    step(&mut world, &tuning, 60.0);
    world.tiles[0].enabled = false;
    world.stacks.clear();
    step(&mut world, &tuning, 60.0);
    assert_eq!(world.colonists[0].goal, Goal::Work);
    assert_eq!(world.colonists[0].target_x, 6);

    world.add_to_stack(
        &world.tiles[0].clone(),
        ResourceKind::Food,
        tuning.stack_food,
    );
    world.add_to_stack(
        &world.tiles[2].clone(),
        ResourceKind::Food,
        tuning.stack_food,
    );
    // Equal cleanup/active priority isolates retargeting from priority ranking.
    world
        .work_orders
        .iter_mut()
        .for_each(|order| order.priority = 3);
    step(&mut world, &tuning, 60.0);
    assert_eq!(world.colonists[0].goal, Goal::Haul);
    assert_eq!(world.colonists[0].target_x, 0);
    world.take_from_stack(1, ResourceKind::Food, tuning.stack_food);
    step(&mut world, &tuning, 60.0);
    assert_eq!(world.colonists[0].goal, Goal::Haul);
    assert_eq!(world.colonists[0].target_x, 6);
    assert!(!world.colonists[0].is_carrying());
}

#[test]
fn shared_forest_piles_are_sorted_and_picked_up_by_resource() {
    let (mut world, tuning) = hauling_world(WorkType::Logging, HaulPolicy::SelfHaul);
    world.colonists[1].work = WorkType::Hunting;
    let tile = world.tiles[0].clone();
    world.add_to_stack(&tile, ResourceKind::Meat, tuning.stack_meat);
    world.add_to_stack(&tile, ResourceKind::Wood, tuning.stack_wood);
    assert!(world.stacks[0].id < world.stacks[1].id);
    step(&mut world, &tuning, 60.0);
    assert_eq!(world.colonists[0].carried_kind, ResourceKind::Wood);
    assert_eq!(world.colonists[0].carried_amount, tuning.stack_wood);
    assert_eq!(world.colonists[1].carried_kind, ResourceKind::Meat);
    assert_eq!(world.colonists[1].carried_amount, tuning.stack_meat);
    assert!(world.stacks.is_empty());
    world.add_to_stack(&tile, ResourceKind::Wood, 1.0);
    assert_eq!(world.stacks[0].id, stack_id(tile.id, ResourceKind::Wood));
}

#[test]
fn needs_interrupt_hauling_without_losing_the_carried_stack() {
    let (mut world, tuning) = hauling_world(WorkType::Farming, HaulPolicy::SelfHaul);
    world.colonists.truncate(1);
    world.tiles.push(Tile {
        id: 3,
        x: 0,
        y: 1,
        kind: TileKind::Dining,
        enabled: true,
    });
    world.colonists[0].carried_kind = ResourceKind::Wood;
    world.colonists[0].carried_amount = tuning.stack_wood;
    world.colonists[0].hunger = 80.0;
    step(&mut world, &tuning, 2.0 * 60.0);
    assert_eq!(world.colonists[0].activity, Activity::Eating);
    assert_eq!(world.colonists[0].carried_amount, tuning.stack_wood);
    step(&mut world, &tuning, 30.0 * 60.0);
    assert_eq!(world.resources.wood, tuning.stack_wood);
    assert!(!world.colonists[0].is_carrying());
}

#[test]
fn idle_haulers_do_not_repeat_need_denials() {
    let (mut world, tuning) = hauling_world(WorkType::Farming, HaulPolicy::DedicatedHaulers);
    world.tiles[0].enabled = false;
    world.colonists[1].recreation = 80.0;
    world.colonists[1].goal = Goal::Recreate;
    let events = step(&mut world, &tuning, 60.0);
    assert!(events
        .iter()
        .any(|event| matches!(event, SimEvent::RecreationDenied { colonist: 2, .. })));
    assert!(step(&mut world, &tuning, 10.0 * 60.0).is_empty());
}

/// Aggregated statistics gathered while running the simulation for a while.
struct Run {
    avg_mood: f32,
    avg_fatigue: f32,
    avg_productivity: f32,
    avg_sleep_quality: f32,
    food_produced: f32,
    recreation_end: f32,
}

fn run(recreation_enabled: bool, days: f64) -> Run {
    let t = Tuning::default();
    let mut w = new_world();
    if !recreation_enabled {
        for tile in w.tiles.iter_mut() {
            if tile.kind == TileKind::Recreation {
                tile.enabled = false;
            }
        }
    }

    let dt = 60.0;
    let ticks = (days * SECONDS_PER_DAY / dt) as usize;

    // Keep food available to isolate the recreation failure chain.
    w.resources.food = 5_000.0;
    let start_food = w.resources.food;

    let mut mood = 0.0f64;
    let mut fatigue = 0.0f64;
    let mut prod = 0.0f64;
    let mut quality = 0.0f64;

    for _ in 0..ticks {
        step(&mut w, &t, dt);
        mood += w.avg_mood() as f64;
        fatigue += w.avg_fatigue() as f64;
        prod += w.avg_productivity() as f64;
        quality += average(
            w.colonists
                .iter()
                .map(|colonist| sleep_quality(colonist.mood, &t)),
        ) as f64;
    }

    let n = ticks as f64;
    Run {
        avg_mood: (mood / n) as f32,
        avg_fatigue: (fatigue / n) as f32,
        avg_productivity: (prod / n) as f32,
        avg_sleep_quality: (quality / n) as f32,
        // Food net change; eating is subtracted out, so this is production
        // minus consumption. Both runs eat the same amount per hunger point,
        // so comparing the two is a fair comparison of production.
        food_produced: w.resources.food - start_food,
        recreation_end: w.avg_recreation(),
    }
}

#[test]
fn colony_layout_has_all_zone_types() {
    let w = new_world();
    assert_eq!(w.tiles.len(), (GRID_W * GRID_H) as usize);
    for kind in [
        TileKind::Dining,
        TileKind::Sleep,
        TileKind::Farm,
        TileKind::Forest,
        TileKind::Mine,
        TileKind::Storage,
        TileKind::Recreation,
    ] {
        assert!(w.has_enabled(kind), "missing tile kind {kind:?}");
    }
    assert_eq!(w.colonists.len(), 8);
    for work in [
        WorkType::Farming,
        WorkType::Logging,
        WorkType::Mining,
        WorkType::Hunting,
    ] {
        assert_eq!(w.colonists.iter().filter(|c| c.work == work).count(), 2);
    }
}

#[test]
fn work_definitions_are_the_source_of_facilities_and_outputs() {
    assert_eq!(WorkType::None.definition(), None);
    assert_eq!(Goal::Work.tile_kind(WorkType::None, false), None);

    for (work, facility, output) in [
        (WorkType::Farming, TileKind::Farm, ResourceKind::Food),
        (WorkType::Logging, TileKind::Forest, ResourceKind::Wood),
        (WorkType::Mining, TileKind::Mine, ResourceKind::Stone),
        (WorkType::Hunting, TileKind::Forest, ResourceKind::Meat),
    ] {
        let definition = work.definition().unwrap();
        assert_eq!(definition.facility, facility);
        assert_eq!(definition.output, output);
        assert_eq!(Goal::Work.tile_kind(work, false), Some(facility));
        assert_eq!(Goal::Haul.tile_kind(work, false), Some(facility));
        assert_eq!(Goal::Haul.tile_kind(work, true), Some(TileKind::Storage));
    }
}

#[test]
fn producing_work_creates_only_its_declared_pile_not_stored_resources() {
    let tuning = Tuning::default();

    for (work, output) in [
        (WorkType::Farming, ResourceKind::Food),
        (WorkType::Logging, ResourceKind::Wood),
        (WorkType::Mining, ResourceKind::Stone),
        (WorkType::Hunting, ResourceKind::Meat),
    ] {
        let mut world = new_world();
        let tile = world
            .tiles
            .iter()
            .find(|tile| tile.kind == work.definition().unwrap().facility)
            .unwrap()
            .clone();
        world.colonists[0].work = work;
        world.colonists[0].x = tile.x;
        world.colonists[0].y = tile.y;
        let before = world.resources.clone();

        step_work(&mut world, 0, &tuning, 1.0);

        assert_eq!(world.resources, before);
        assert_eq!(world.stacks.len(), 1);
        assert_eq!(world.stacks[0].id, stack_id(tile.id, output));
        assert_eq!(world.stacks[0].kind, output);
        assert_eq!(world.stacks[0].amount, tuning.output_per_hour(output) * 0.8);
    }
}

#[test]
fn non_producing_work_does_not_manufacture_resources() {
    let tuning = Tuning::default();
    let mut world = new_world();
    world.colonists[0].work = WorkType::None;
    let before = world.resources.clone();

    step_work(&mut world, 0, &tuning, 1.0);

    assert_eq!(world.resources, before);
    assert!(world.stacks.is_empty());
}

#[test]
fn unassigned_colonists_do_not_work_or_produce() {
    let t = Tuning::default();
    let mut w = new_world();
    for colonist in &mut w.colonists {
        colonist.work = WorkType::None;
    }
    let food = w.resources.food;

    step(&mut w, &t, 60.0);

    assert_eq!(w.resources.food, food);
    assert!(w
        .colonists
        .iter()
        .all(|colonist| { colonist.goal == Goal::Nothing && colonist.activity == Activity::Idle }));
}

#[test]
fn sleep_cap_wakes_a_still_critically_fatigued_colonist() {
    let t = Tuning {
        move_tiles_per_hour: 0.0,
        ..Tuning::default()
    };
    let mut w = new_world();
    w.colonists.truncate(1);
    let colonist = &mut w.colonists[0];
    colonist.x = 19;
    colonist.y = 2;
    colonist.target_x = 19;
    colonist.target_y = 2;
    colonist.activity = Activity::Sleeping;
    colonist.goal = Goal::Sleep;
    colonist.fatigue = 100.0;
    colonist.mood = 100.0;
    colonist.sleep_hours = t.max_sleep_hours - 60.0 / 3600.0;

    step(&mut w, &t, 60.0);
    let colonist = &w.colonists[0];
    assert_eq!(colonist.sleep_hours, t.max_sleep_hours);
    assert!(colonist.fatigue < 100.0);

    step(&mut w, &t, 60.0);
    let colonist = &w.colonists[0];
    assert_ne!(colonist.goal, Goal::Sleep);
    assert_ne!(colonist.activity, Activity::Sleeping);
}

#[test]
fn disabled_target_retargets_an_enabled_facility_of_the_same_kind() {
    let t = Tuning {
        move_tiles_per_hour: 0.0,
        ..Tuning::default()
    };
    let mut w = new_world();
    w.colonists.truncate(1);
    for tile in &mut w.tiles {
        if tile.kind == TileKind::Dining {
            tile.enabled = tile.x == 3 && tile.y == 2;
        }
    }
    let colonist = &mut w.colonists[0];
    colonist.x = 0;
    colonist.y = 0;
    colonist.target_x = 2;
    colonist.target_y = 2;
    colonist.activity = Activity::Travelling;
    colonist.goal = Goal::Eat;
    colonist.hunger = 80.0;
    let food = w.resources.food;

    step(&mut w, &t, 60.0);

    let colonist = &w.colonists[0];
    assert_eq!((colonist.target_x, colonist.target_y), (3, 2));
    assert_eq!(colonist.activity, Activity::Travelling);
    assert_eq!(w.resources.food, food);
}

#[test]
fn disabled_only_facility_falls_back_without_performing_the_activity() {
    let t = Tuning {
        move_tiles_per_hour: 0.0,
        ..Tuning::default()
    };
    let mut w = new_world();
    w.colonists.truncate(1);
    for tile in &mut w.tiles {
        if tile.kind == TileKind::Dining {
            tile.enabled = false;
        }
    }
    let colonist = &mut w.colonists[0];
    colonist.x = 2;
    colonist.y = 2;
    colonist.target_x = 2;
    colonist.target_y = 2;
    colonist.activity = Activity::Eating;
    colonist.goal = Goal::Eat;
    colonist.hunger = 80.0;
    let food = w.resources.food;

    step(&mut w, &t, 60.0);

    let colonist = &w.colonists[0];
    assert_eq!(colonist.goal, Goal::Work);
    assert_ne!(colonist.activity, Activity::Eating);
    assert_eq!(w.resources.food, food);
}

#[test]
fn colonists_cycle_through_all_activities() {
    let t = Tuning::default();
    let mut w = new_world();
    let mut seen = std::collections::HashSet::new();
    for _ in 0..(3.0 * SECONDS_PER_DAY / 60.0) as usize {
        step(&mut w, &t, 60.0);
        for c in &w.colonists {
            seen.insert(c.activity);
        }
    }
    for a in [
        Activity::Travelling,
        Activity::Working,
        Activity::Hauling,
        Activity::Eating,
        Activity::Sleeping,
        Activity::Recreating,
    ] {
        assert!(seen.contains(&a), "colonists never did {a:?}");
    }
}

#[test]
fn working_produces_food_and_eating_consumes_it() {
    let t = Tuning::default();
    let mut w = new_world();
    w.resources.food = 50.0;
    let mut min_food = w.resources.food;
    let mut max_food = w.resources.food;
    for _ in 0..(2.0 * SECONDS_PER_DAY / 60.0) as usize {
        step(&mut w, &t, 60.0);
        min_food = min_food.min(w.resources.food);
        max_food = max_food.max(w.resources.food);
    }
    assert!(max_food > 50.0, "food never increased ({max_food})");
    assert!(min_food < max_food, "food never decreased");
}

#[test]
fn deliveries_have_no_storage_limit() {
    let t = Tuning::default();
    let mut w = new_world();
    w.colonists[0].x = 10;
    w.colonists[0].y = 10;
    for kind in RESOURCE_KINDS {
        let before = w.resources.amount(kind);
        for _ in 0..100 {
            w.colonists[0].carried_kind = kind;
            w.colonists[0].carried_amount = t.stack_size(kind);
            step_haul(&mut w, 0, &t);
            assert_eq!(w.colonists[0].carried_amount, 0.0);
        }
        assert_eq!(
            w.resources.amount(kind),
            before + 100.0 * t.stack_size(kind)
        );
    }
}

#[test]
fn all_stats_stay_in_range() {
    let t = Tuning::default();
    let mut w = new_world();
    for tile in w.tiles.iter_mut() {
        if tile.kind == TileKind::Recreation {
            tile.enabled = false;
        }
    }
    for _ in 0..(10.0 * SECONDS_PER_DAY / 60.0) as usize {
        step(&mut w, &t, 60.0);
        for c in &w.colonists {
            for (label, v) in [
                ("hunger", c.hunger),
                ("fatigue", c.fatigue),
                ("recreation", c.recreation),
                ("mood", c.mood),
                ("productivity", c.productivity),
            ] {
                assert!((0.0..=100.0).contains(&v), "{label} out of range: {v}");
            }
            assert!(c.x >= 0 && c.x < GRID_W);
            assert!(c.y >= 0 && c.y < GRID_H);
        }
        assert!(w.resources.food >= 0.0);
    }
}

/// recreation disabled -> unmet recreation need
#[test]
fn chain_1_disabling_recreation_leaves_the_need_unmet() {
    let healthy = run(true, 6.0);
    let broken = run(false, 6.0);
    assert!(
        broken.recreation_end > 90.0,
        "recreation need should saturate when unavailable, got {}",
        broken.recreation_end
    );
    assert!(
        healthy.recreation_end < 80.0,
        "recreation need should be manageable when available, got {}",
        healthy.recreation_end
    );
}

/// unmet recreation -> mood falls
#[test]
fn chain_2_unmet_recreation_lowers_mood() {
    let healthy = run(true, 6.0);
    let broken = run(false, 6.0);
    assert!(
        broken.avg_mood < healthy.avg_mood - 15.0,
        "mood should fall clearly: healthy {} vs broken {}",
        healthy.avg_mood,
        broken.avg_mood
    );
}

/// mood falls -> sleep quality falls
#[test]
fn chain_3_low_mood_lowers_sleep_quality() {
    let t = Tuning::default();
    assert!(sleep_quality(20.0, &t) < sleep_quality(90.0, &t));

    let healthy = run(true, 6.0);
    let broken = run(false, 6.0);
    assert!(
        broken.avg_sleep_quality < healthy.avg_sleep_quality - 0.1,
        "sleep quality should fall: healthy {} vs broken {}",
        healthy.avg_sleep_quality,
        broken.avg_sleep_quality
    );
}

/// sleep quality falls -> fatigue gets worse
#[test]
fn chain_4_bad_sleep_raises_fatigue() {
    let healthy = run(true, 6.0);
    let broken = run(false, 6.0);
    assert!(
        broken.avg_fatigue > healthy.avg_fatigue + 5.0,
        "fatigue should rise: healthy {} vs broken {}",
        healthy.avg_fatigue,
        broken.avg_fatigue
    );
}

/// fatigue gets worse -> productivity falls
#[test]
fn chain_5_fatigue_and_mood_lower_productivity() {
    let healthy = run(true, 6.0);
    let broken = run(false, 6.0);
    assert!(
        broken.avg_productivity < healthy.avg_productivity - 15.0,
        "productivity should fall: healthy {} vs broken {}",
        healthy.avg_productivity,
        broken.avg_productivity
    );
}

/// productivity falls -> food production falls
#[test]
fn chain_6_lower_productivity_lowers_food_production() {
    let healthy = run(true, 6.0);
    let broken = run(false, 6.0);
    assert!(
        broken.food_produced < healthy.food_produced,
        "food production should fall: healthy {} vs broken {}",
        healthy.food_produced,
        broken.food_produced
    );
}

/// Re-enabling recreation must actually let the colony recover.
#[test]
fn chain_7_recovery_after_re_enabling_recreation() {
    let t = Tuning::default();
    let mut w = new_world();
    for tile in w.tiles.iter_mut() {
        if tile.kind == TileKind::Recreation {
            tile.enabled = false;
        }
    }
    for _ in 0..(6.0 * SECONDS_PER_DAY / 60.0) as usize {
        step(&mut w, &t, 60.0);
    }
    let degraded_mood = w.avg_mood();
    let degraded_prod = w.avg_productivity();

    for tile in w.tiles.iter_mut() {
        if tile.kind == TileKind::Recreation {
            tile.enabled = true;
        }
    }
    for _ in 0..(4.0 * SECONDS_PER_DAY / 60.0) as usize {
        step(&mut w, &t, 60.0);
    }

    assert!(
        w.avg_mood() > degraded_mood + 15.0,
        "mood should recover: {} -> {}",
        degraded_mood,
        w.avg_mood()
    );
    assert!(
        w.avg_productivity() > degraded_prod + 10.0,
        "productivity should recover: {} -> {}",
        degraded_prod,
        w.avg_productivity()
    );
}

#[test]
fn events_are_not_emitted_every_tick() {
    let t = Tuning::default();
    let mut w = new_world();
    let ticks = (2.0 * SECONDS_PER_DAY / 60.0) as usize;
    let mut total = 0usize;
    for _ in 0..ticks {
        total += step(&mut w, &t, 60.0).len();
    }
    assert!(
        total < ticks * w.colonists.len() / 10,
        "too chatty: {total} events over {ticks} ticks"
    );
    assert!(total > 0, "no events at all");
}

#[test]
fn poorly_rested_events_appear_only_in_the_broken_colony() {
    fn count_poorly_rested(recreation: bool) -> usize {
        let t = Tuning::default();
        let mut w = new_world();
        if !recreation {
            for tile in w.tiles.iter_mut() {
                if tile.kind == TileKind::Recreation {
                    tile.enabled = false;
                }
            }
        }
        let mut n = 0;
        for _ in 0..(8.0 * SECONDS_PER_DAY / 60.0) as usize {
            for e in step(&mut w, &t, 60.0) {
                if matches!(e, SimEvent::WokePoorlyRested { .. }) {
                    n += 1;
                }
            }
        }
        n
    }
    assert_eq!(count_poorly_rested(true), 0);
    assert!(count_poorly_rested(false) > 0);
}

#[test]
fn missing_food_is_reported() {
    let t = Tuning::default();
    let mut w = new_world();
    w.resources.food = 0.0;
    for tile in w.tiles.iter_mut() {
        if tile.kind == TileKind::Farm {
            tile.enabled = false;
        }
    }
    let mut missed = false;
    for _ in 0..(3.0 * SECONDS_PER_DAY / 60.0) as usize {
        for e in step(&mut w, &t, 60.0) {
            if matches!(e, SimEvent::MealMissed { .. }) {
                missed = true;
            }
        }
    }
    assert!(missed, "starving colony never reported a missed meal");
}

/// The tuning is only useful if a *working* colony actually looks healthy.
///
/// These are the exact levels the alert thresholds in `lib.rs` are set
/// against, measured on the smoothed values the alerts actually read, so a
/// healthy colony never flaps an alert on and off.
#[test]
fn alert_thresholds_separate_a_healthy_colony_from_a_broken_one() {
    /// `(min_smoothed_productivity, max_smoothed_productivity,
    ///   min_smoothed_mood, max_smoothed_mood)` after a two-day warmup.
    fn envelope(recreation: bool) -> (f32, f32, f32, f32) {
        let t = Tuning::default();
        let mut w = new_world();
        if !recreation {
            for tile in w.tiles.iter_mut() {
                if tile.kind == TileKind::Recreation {
                    tile.enabled = false;
                }
            }
        }
        w.resources.food = 5_000.0;
        let (mut lo_p, mut hi_p, mut lo_m, mut hi_m) = (100.0f32, 0.0f32, 100.0f32, 0.0f32);
        let warmup = (2.0 * SECONDS_PER_DAY / 60.0) as usize;
        for i in 0..(10.0 * SECONDS_PER_DAY / 60.0) as usize {
            step(&mut w, &t, 60.0);
            if i > warmup {
                lo_p = lo_p.min(w.productivity_ema);
                hi_p = hi_p.max(w.productivity_ema);
                lo_m = lo_m.min(w.mood_ema);
                hi_m = hi_m.max(w.mood_ema);
            }
        }
        (lo_p, hi_p, lo_m, hi_m)
    }

    let (h_lo_p, _, h_lo_m, _) = envelope(true);
    let (_, b_hi_p, _, b_hi_m) = envelope(false);

    // `low_productivity` raises below 80 and clears above 83.
    assert!(
        h_lo_p > 83.0,
        "healthy colony would flap the productivity alert (min {h_lo_p})"
    );
    assert!(
        b_hi_p < 80.0,
        "broken colony would not trip the productivity alert (max {b_hi_p})"
    );

    // `low_mood` raises below 45 and clears above 55.
    assert!(
        h_lo_m > 55.0,
        "healthy colony would flap the mood alert (min {h_lo_m})"
    );
    assert!(
        b_hi_m < 45.0,
        "broken colony would not trip the mood alert (max {b_hi_m})"
    );
}

/// The last link of the chain, measured the way a player sees it: the larder.
#[test]
fn chain_8_broken_colony_runs_out_of_food_and_a_healthy_one_does_not() {
    fn food_after(recreation: bool, days: f64) -> (f32, f32) {
        let t = Tuning::default();
        let mut w = new_world();
        if !recreation {
            for tile in w.tiles.iter_mut() {
                if tile.kind == TileKind::Recreation {
                    tile.enabled = false;
                }
            }
        }
        let mut low = w.resources.food;
        for _ in 0..(days * SECONDS_PER_DAY / 60.0) as usize {
            step(&mut w, &t, 60.0);
            low = low.min(w.resources.food);
        }
        (w.resources.food, low)
    }

    let (healthy_food, healthy_low) = food_after(true, 30.0);
    let (broken_food, _) = food_after(false, 30.0);

    assert!(
        healthy_low > 0.0 && healthy_food > new_world().resources.food,
        "a working colony should keep its larder stocked, got {healthy_food}"
    );
    assert!(
        broken_food < 0.25 * new_world().resources.food,
        "a colony without recreation should drain its larder, got {broken_food}"
    );
}

#[test]
fn dedicated_pairs_keep_a_healthy_colony_supplied() {
    let tuning = Tuning::default();
    let mut world = new_world();
    world.haul_policy = HaulPolicy::DedicatedHaulers;
    for _ in 0..(30.0 * SECONDS_PER_DAY / 60.0) as usize {
        step(&mut world, &tuning, 60.0);
        assert!(
            world.resources.food > 0.0,
            "dedicated farmers ran out of food"
        );
    }
    for kind in [ResourceKind::Wood, ResourceKind::Stone, ResourceKind::Meat] {
        assert!(world.resources.amount(kind) > 0.0);
    }
}

/// Colonists must not share one schedule, or the colony eats and sleeps as a
/// single organism and the map shows eight markers moving as one.
#[test]
fn colonists_do_not_move_in_lockstep() {
    let t = Tuning::default();
    let mut w = new_world();
    let mut ticks_all_identical = 0usize;
    let total = (4.0 * SECONDS_PER_DAY / 60.0) as usize;
    for _ in 0..total {
        step(&mut w, &t, 60.0);
        let first = w.colonists[0].activity;
        if w.colonists.iter().all(|c| c.activity == first) {
            ticks_all_identical += 1;
        }
    }
    assert!(
        ticks_all_identical < total / 2,
        "colonists shared an activity for {ticks_all_identical}/{total} ticks"
    );
}

#[test]
fn simulation_is_deterministic() {
    let t = Tuning::default();
    for policy in [HaulPolicy::SelfHaul, HaulPolicy::DedicatedHaulers] {
        let mut a = new_world();
        a.haul_policy = policy;
        let mut b = a.clone();
        for _ in 0..5000 {
            let ea = step(&mut a, &t, 60.0);
            let eb = step(&mut b, &t, 60.0);
            assert_eq!(ea, eb);
        }
        assert_eq!(a, b);
    }
}

#[test]
fn large_step_matches_repeated_bounded_steps() {
    let t = Tuning::default();
    let mut actual = new_world();
    let mut expected = actual.clone();
    let full_steps = 360;
    let remainder = 17.25;

    let actual_events = step(
        &mut actual,
        &t,
        full_steps as f64 * MAX_STEP_SECONDS + remainder,
    );
    let mut expected_events = Vec::new();
    for _ in 0..full_steps {
        expected_events.extend(step(&mut expected, &t, MAX_STEP_SECONDS));
    }
    expected_events.extend(step(&mut expected, &t, remainder));

    assert!(!actual_events.is_empty());
    assert_eq!(actual_events, expected_events);
    assert_eq!(actual, expected);
}

#[test]
fn large_step_advances_time_through_remainder() {
    let t = Tuning::default();
    let mut w = new_world();
    let start = w.game_seconds;

    step(&mut w, &t, 2.0 * MAX_STEP_SECONDS + 12.5);

    assert_eq!(w.game_seconds, start + 132.5);
}

#[test]
fn invalid_step_durations_are_ignored() {
    let t = Tuning::default();
    let initial = new_world();

    for dt in [0.0, -1.0, f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
        let mut w = initial.clone();
        assert!(step(&mut w, &t, dt).is_empty());
        assert_eq!(w, initial);
    }
}
