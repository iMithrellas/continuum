use super::decisions::{destination_for, destination_still_serves, Availability};
use super::intents::{plan_batch, uses_speculation, worker_count, DecisionInput};
use super::logistics::{assign_haul_roles, step_haul, step_work};
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
/// Actors execute by durable ID: decision, action, needs, then wellbeing. Shared
/// stock contention depends on this order. The roster is fixed during the step.
/// Large durations use bounded intervals; non-positive/non-finite durations are ignored.
pub fn step(world: &mut World, tuning: &Tuning, dt_game_seconds: f64) -> Vec<SimEvent> {
    step_with_workers(world, tuning, dt_game_seconds, worker_count())
}

fn step_with_workers(
    world: &mut World,
    tuning: &Tuning,
    dt_game_seconds: f64,
    workers: usize,
) -> Vec<SimEvent> {
    let mut events = Vec::new();
    if !dt_game_seconds.is_finite() || dt_game_seconds <= 0.0 {
        return events;
    }

    let order = world.colonist_order();
    let mut remaining = dt_game_seconds;
    while remaining > MAX_STEP_SECONDS {
        events.extend(step_bounded(
            world,
            tuning,
            MAX_STEP_SECONDS,
            &order,
            workers,
        ));
        remaining -= MAX_STEP_SECONDS;
    }
    events.extend(step_bounded(world, tuning, remaining, &order, workers));
    events
}

fn step_bounded(
    world: &mut World,
    tuning: &Tuning,
    dt_game_seconds: f64,
    order: &[usize],
    workers: usize,
) -> Vec<SimEvent> {
    let mut events = Vec::new();
    let dt_hours = (dt_game_seconds / 3600.0) as f32;
    world.game_seconds += dt_game_seconds;

    assign_haul_roles(world);

    let interval_availability = Availability {
        food: world.has_enabled(TileKind::Dining)
            && world.resources.amount(ResourceKind::Food) > 0.0,
        kitchen: world.has_enabled(TileKind::Dining),
        sleep: world.has_enabled(TileKind::Sleep),
        recreation: world.has_enabled(TileKind::Recreation),
    };

    let mut proposals = if uses_speculation(workers, order.len()) {
        let inputs = order
            .iter()
            .map(|&index| DecisionInput::speculate(&world.colonists[index], interval_availability))
            .collect();
        Some(plan_batch(inputs, tuning, workers).into_iter())
    } else {
        None
    };

    for &colonist_index in order {
        let current = DecisionInput::gather(world, colonist_index, tuning, interval_availability);
        let decision = if let Some(proposals) = &mut proposals {
            proposals
                .next()
                .expect("one proposal per scheduled actor")
                .validate(current, tuning)
        } else {
            current.decide(tuning)
        };
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
                .map(|tile| (tile.x, tile.y, tile.z));

            if desired.tile_kind(work, carrying).is_some() && dest.is_none() {
                desired = Goal::Nothing;
            }

            let colonist = &mut world.colonists[colonist_index];
            colonist.task.goal = desired;
            colonist.rest.hours = 0.0;
            match dest {
                Some((tx, ty, tz)) => {
                    if (
                        colonist.movement.target.x,
                        colonist.movement.target.y,
                        colonist.spatial.target_z,
                    ) != (tx, ty, tz)
                    {
                        colonist.movement.progress = 0.0;
                    }
                    colonist.movement.target.x = tx;
                    colonist.movement.target.y = ty;
                    colonist.spatial.target_z = tz;
                }
                None => {
                    colonist.movement.target.x = colonist.position.x;
                    colonist.movement.target.y = colonist.position.y;
                    colonist.spatial.target_z = colonist.spatial.z;
                    colonist.spatial.next = world_cell(colonist);
                }
            }
        }

        let arrived = {
            let colonist = &world.colonists[colonist_index];
            colonist.position.x == colonist.movement.target.x
                && colonist.position.y == colonist.movement.target.y
                && colonist.spatial.z == colonist.spatial.target_z
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
                if world.geometry.is_some() {
                    world.step_live_travel(colonist_index, tuning, dt_hours);
                } else {
                    let colonist = &mut world.colonists[colonist_index];
                    step_travel(
                        &mut colonist.position,
                        &mut colonist.movement,
                        tuning,
                        dt_hours,
                    )
                }
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
        if colonist.position.x == colonist.movement.target.x
            && colonist.position.y == colonist.movement.target.y
            && colonist.spatial.z == colonist.spatial.target_z
        {
            colonist.spatial.next = world_cell(colonist);
        }
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

fn world_cell(actor: &super::Colonist) -> super::geometry::Cell {
    super::geometry::Cell(actor.position.x, actor.position.y, actor.spatial.z)
}

#[cfg(test)]
#[path = "intent_tests.rs"]
mod intent_tests;
