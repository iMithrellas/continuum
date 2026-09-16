use super::decisions::{decide, destination_for, destination_still_serves, Availability};
use super::logistics::{assign_haul_roles, labour_goal, step_haul, step_work};
use super::movement::step_travel;
use super::needs::{accrue_needs, step_eat, step_recreate, step_sleep, update_wellbeing};
use super::{Activity, Goal, ResourceKind, TileKind, Tuning, World, MAX_STEP_SECONDS};

/// Notable things that happened during a step. Emitted only on *changes*, never
/// once per tick.
#[derive(Clone, Debug, PartialEq)]
pub enum SimEvent {
    ActivityChanged {
        colonist: u64,
        name: String,
        from: Activity,
        to: Activity,
    },
    SleptWithLowMood {
        colonist: u64,
        name: String,
        mood: f32,
    },
    WokePoorlyRested {
        colonist: u64,
        name: String,
        fatigue: f32,
        quality: f32,
    },
    /// Wanted to eat but the colony had no food left.
    MealMissed { colonist: u64, name: String },
    /// Wanted recreation but no recreation tile is enabled.
    RecreationDenied { colonist: u64, name: String },
}

/// Advance the world by `dt_game_seconds` in-game seconds.
///
/// Returns the notable events that occurred. Pure: given the same world, tuning
/// and dt, this always produces the same result. Large durations are processed
/// as ordered, bounded intervals so decisions and activities can change during
/// accelerated time. Non-positive and non-finite durations are ignored.
pub fn step(world: &mut World, tuning: &Tuning, dt_game_seconds: f64) -> Vec<SimEvent> {
    let mut events = Vec::new();
    if !dt_game_seconds.is_finite() || dt_game_seconds <= 0.0 {
        return events;
    }

    // Resolve storage indices once. No system may add/remove colonists during a
    // step; future structural commands must be applied at its boundary.
    let order = world.colonist_order();
    let mut remaining = dt_game_seconds;
    while remaining > MAX_STEP_SECONDS {
        events.extend(step_bounded(world, tuning, MAX_STEP_SECONDS, &order));
        remaining -= MAX_STEP_SECONDS;
    }
    events.extend(step_bounded(world, tuning, remaining, &order));
    events
}

fn step_bounded(
    world: &mut World,
    tuning: &Tuning,
    dt_game_seconds: f64,
    order: &[usize],
) -> Vec<SimEvent> {
    let mut events = Vec::new();
    let dt_hours = (dt_game_seconds / 3600.0) as f32;
    world.game_seconds += dt_game_seconds;

    assign_haul_roles(world);

    // Snapshot of what the world offers this tick. Colonists all see the same
    // availability, independent of iteration order.
    let availability = Availability {
        // A colonist can only eat if there is both a working kitchen *and*
        // something in the larder.
        food: world.has_enabled(TileKind::Dining)
            && world.resources.amount(ResourceKind::Food) > 0.0,
        kitchen: world.has_enabled(TileKind::Dining),
        sleep: world.has_enabled(TileKind::Sleep),
        recreation: world.has_enabled(TileKind::Recreation),
    };

    // Keep the existing authoritative order: role assignment and availability,
    // then decision -> action -> needs -> wellbeing for each ascending ID.
    // Batching all actors by system would change shared-stock contention.
    for &colonist_index in order {
        let labour = labour_goal(world, colonist_index, tuning);
        let colonist = &world.colonists[colonist_index];
        let decision = decide(
            &colonist.task,
            &colonist.needs,
            &colonist.rest,
            tuning,
            &availability,
            labour,
        );
        let mut desired = decision.goal;

        if decision.denied_recreation {
            let colonist = &world.colonists[colonist_index];
            events.push(SimEvent::RecreationDenied {
                colonist: colonist.id,
                name: colonist.name.clone(),
            });
        }
        if decision.denied_food {
            let colonist = &world.colonists[colonist_index];
            events.push(SimEvent::MealMissed {
                colonist: colonist.id,
                name: colonist.name.clone(),
            });
        }

        let work = world.colonists[colonist_index].assignment.work;
        let carrying = world.colonists[colonist_index].is_carrying();
        let destination_invalid = !destination_still_serves(world, colonist_index, tuning, desired);
        if world.colonists[colonist_index].task.goal != desired || destination_invalid {
            let dest = destination_for(world, colonist_index, tuning, desired)
                .map(|tile| (tile.x, tile.y));

            if desired.tile_kind(work, carrying).is_some() && dest.is_none() {
                desired = Goal::Nothing;
            }

            let colonist = &mut world.colonists[colonist_index];
            colonist.task.goal = desired;
            colonist.rest.hours = 0.0;
            match dest {
                Some((tx, ty)) => {
                    if (colonist.movement.target.x, colonist.movement.target.y) != (tx, ty) {
                        colonist.movement.progress = 0.0;
                    }
                    colonist.movement.target.x = tx;
                    colonist.movement.target.y = ty;
                }
                None => {
                    colonist.movement.target.x = colonist.position.x;
                    colonist.movement.target.y = colonist.position.y;
                }
            }
        }

        let arrived = {
            let colonist = &world.colonists[colonist_index];
            colonist.position.x == colonist.movement.target.x
                && colonist.position.y == colonist.movement.target.y
        };

        let next_activity = if world.colonists[colonist_index].task.goal == Goal::Nothing {
            Activity::Idle
        } else if arrived {
            world.colonists[colonist_index].task.goal.activity()
        } else {
            Activity::Travelling
        };

        let prev_activity = world.colonists[colonist_index].task.activity;
        if prev_activity != next_activity {
            // Report going to bed in a bad mood before the sleep is simulated.
            if next_activity == Activity::Sleeping {
                let colonist = &world.colonists[colonist_index];
                if colonist.wellbeing.mood < tuning.low_mood_sleep_threshold {
                    events.push(SimEvent::SleptWithLowMood {
                        colonist: colonist.id,
                        name: colonist.name.clone(),
                        mood: colonist.wellbeing.mood,
                    });
                }
            }
            // Report a sleep that ended without actually clearing the fatigue.
            if prev_activity == Activity::Sleeping {
                let colonist = &world.colonists[colonist_index];
                if colonist.needs.fatigue > tuning.poorly_rested_fatigue {
                    events.push(SimEvent::WokePoorlyRested {
                        colonist: colonist.id,
                        name: colonist.name.clone(),
                        fatigue: colonist.needs.fatigue,
                        quality: colonist.rest.last_quality,
                    });
                }
            }
            let colonist = &mut world.colonists[colonist_index];
            colonist.task.activity = next_activity;
            if next_activity == Activity::Sleeping {
                colonist.rest.hours = 0.0;
            }
            events.push(SimEvent::ActivityChanged {
                colonist: colonist.id,
                name: colonist.name.clone(),
                from: prev_activity,
                to: next_activity,
            });
        }

        match next_activity {
            Activity::Travelling => {
                let colonist = &mut world.colonists[colonist_index];
                step_travel(
                    &mut colonist.position,
                    &mut colonist.movement,
                    tuning,
                    dt_hours,
                )
            }
            Activity::Eating => step_eat(
                &mut world.colonists[colonist_index].needs,
                &mut world.resources,
                world.meal_policy,
                tuning,
                dt_hours,
            ),
            Activity::Sleeping => {
                let colonist = &mut world.colonists[colonist_index];
                step_sleep(
                    &mut colonist.needs,
                    &mut colonist.rest,
                    colonist.wellbeing.mood,
                    tuning,
                    dt_hours,
                )
            }
            Activity::Recreating => {
                step_recreate(&mut world.colonists[colonist_index].needs, tuning, dt_hours)
            }
            Activity::Working => step_work(world, colonist_index, tuning, dt_hours),
            Activity::Hauling => step_haul(world, colonist_index, tuning),
            Activity::Idle => {}
        }

        let colonist = &mut world.colonists[colonist_index];
        accrue_needs(
            &mut colonist.needs,
            colonist.task.activity,
            tuning,
            dt_hours,
        );
        update_wellbeing(&mut colonist.wellbeing, &colonist.needs, tuning, dt_hours);
    }

    let dt = dt_game_seconds as f32;
    let alpha = dt / (tuning.stat_ema_tau_seconds.max(dt) + dt);
    world.mood_ema += (world.avg_mood() - world.mood_ema) * alpha;
    world.productivity_ema += (world.avg_productivity() - world.productivity_ema) * alpha;

    events
}
