use super::*;

// Fingerprint explicit observable fields, not struct layout or DefaultHasher.
// Captured before composition; a schedule/math change must explain a new trace.
struct Trace(u64);

impl Trace {
    fn record(&mut self, value: impl std::fmt::Debug) {
        for byte in format!("{value:?}\n").bytes() {
            self.0 = (self.0 ^ u64::from(byte)).wrapping_mul(0x100000001b3);
        }
    }

    fn world(&mut self, world: &World) {
        self.record((world.game_seconds, world.mood_ema, world.productivity_ema));
        self.record((&world.resources, world.haul_policy, world.meal_policy));
        self.record((&world.tiles, &world.work_orders, &world.stacks));
        for c in &world.colonists {
            self.record((
                c.id,
                &c.name,
                c.position.x,
                c.position.y,
                c.movement.target.x,
                c.movement.target.y,
                c.movement.progress,
            ));
            self.record((
                c.task.activity,
                c.task.goal,
                c.assignment.work,
                c.assignment.haul_role,
            ));
            self.record((c.cargo.kind, c.cargo.amount));
            self.record((
                c.needs.hunger,
                c.needs.fatigue,
                c.needs.recreation,
                c.wellbeing.mood,
                c.wellbeing.productivity,
            ));
            self.record((c.rest.hours, c.rest.last_quality));
        }
    }
}

#[test]
fn simulation_matches_pre_composition_trace() {
    let mut traces = Vec::new();
    for hauling in [HaulPolicy::SelfHaul, HaulPolicy::DedicatedHaulers] {
        for meals in [MealPolicy::Normal, MealPolicy::Rationed] {
            let mut world = new_world();
            world.haul_policy = hauling;
            world.meal_policy = meals;
            let mut trace = Trace(0xcbf29ce484222325);
            trace.world(&world);
            for phase in 0..3 {
                for tile in &mut world.tiles {
                    if tile.kind == TileKind::Recreation {
                        tile.enabled = phase != 1;
                    }
                }
                if phase == 1 {
                    world.resources.food = 0.0;
                }
                for _ in 0..48 {
                    for dt in [6.0, 60.0, 3600.0] {
                        trace.record(step(&mut world, &Tuning::default(), dt));
                        trace.world(&world);
                    }
                }
            }
            traces.push(trace.0);
        }
    }
    assert_eq!(
        traces,
        vec![
            6869741487606980237,
            16097870207008624385,
            8860477168860726982,
            16079113804947565384,
        ]
    );
}

#[test]
fn scheduling_and_aggregates_follow_ids_not_storage_order() {
    for policy in [HaulPolicy::SelfHaul, HaulPolicy::DedicatedHaulers] {
        let mut expected = new_world();
        expected.haul_policy = policy;
        expected.resources.food = 1.0;
        for c in &mut expected.colonists {
            c.needs.hunger = 80.0;
            c.position = Position { x: 2, y: 2 };
        }
        let mut reordered = expected.clone();
        reordered.colonists.reverse();
        reordered.tiles.reverse();
        reordered.work_orders.reverse();
        let storage_ids: Vec<_> = reordered.colonists.iter().map(|c| c.id).collect();
        for dt in [6.0, 60.0, 3600.0, 17.25] {
            assert_eq!(
                step(&mut expected, &Tuning::default(), dt),
                step(&mut reordered, &Tuning::default(), dt)
            );
            assert_eq!(expected.resources, reordered.resources);
            assert_eq!(expected.stacks, reordered.stacks);
            assert_eq!(expected.avg_mood(), reordered.avg_mood());
            assert_eq!(expected.avg_productivity(), reordered.avg_productivity());
            assert_eq!(expected.avg_fatigue(), reordered.avg_fatigue());
            assert_eq!(expected.avg_recreation(), reordered.avg_recreation());
            assert_eq!(expected.mood_ema, reordered.mood_ema);
            assert_eq!(expected.productivity_ema, reordered.productivity_ema);
            for c in &expected.colonists {
                assert_eq!(
                    Some(c),
                    reordered.colonists.iter().find(|other| other.id == c.id)
                );
            }
        }
        assert_eq!(
            storage_ids,
            reordered.colonists.iter().map(|c| c.id).collect::<Vec<_>>(),
            "the schedule must not rearrange storage"
        );
    }
}

#[test]
fn persisted_resource_keys_keep_the_legacy_encoding() {
    assert_eq!(
        RESOURCE_KINDS.len(),
        4,
        "adding resources requires an explicit ID encoding/migration decision"
    );
    for (kind, ordinal) in [
        (ResourceKind::Food, 0),
        (ResourceKind::Wood, 1),
        (ResourceKind::Stone, 2),
        (ResourceKind::Meat, 3),
    ] {
        assert_eq!(kind.index(), ordinal);
        for tile_id in [0, 1, 576, u32::MAX] {
            assert_eq!(stack_id(tile_id, kind), u64::from(tile_id) * 4 + ordinal);
        }
    }
}

#[test]
fn components_can_run_without_a_colonist_or_database() {
    let tuning = Tuning::default();
    let mut position = Position { x: 0, y: 0 };
    let mut movement = Movement {
        target: Position { x: 2, y: 1 },
        progress: 0.5,
    };
    super::movement::step_travel(&mut position, &mut movement, &tuning, 0.1);
    assert_eq!(position, movement.target);
    assert_eq!(movement.progress, 0.0);

    let mut needs = Needs {
        hunger: 70.0,
        fatigue: 80.0,
        recreation: 60.0,
    };
    let mut rest = Rest {
        hours: 0.0,
        last_quality: 1.0,
    };
    super::needs::step_sleep(&mut needs, &mut rest, 80.0, &tuning, 1.0);
    assert_eq!(rest.hours, 1.0);
    assert_eq!(
        needs.fatigue,
        80.0 - tuning.sleep_recovery_per_hour * sleep_quality(80.0, &tuning)
    );
    assert_eq!(needs.hunger, 70.0);
    assert_eq!(needs.recreation, 60.0);
    super::needs::step_recreate(&mut needs, &tuning, 0.5);
    assert_eq!(needs.recreation, 30.0);

    let task = ActivityState {
        activity: Activity::Idle,
        goal: Goal::Nothing,
    };
    let available = super::decisions::Availability {
        food: true,
        kitchen: true,
        sleep: true,
        recreation: true,
    };
    assert_eq!(
        super::decisions::decide(&task, &needs, &rest, &tuning, &available, None).goal,
        Goal::Eat
    );
}

#[test]
#[should_panic(expected = "colonist IDs must be unique")]
fn duplicate_actor_ids_are_rejected_before_scheduling() {
    let mut world = new_world();
    world.colonists[1].id = world.colonists[0].id;
    step(&mut world, &Tuning::default(), 6.0);
}
