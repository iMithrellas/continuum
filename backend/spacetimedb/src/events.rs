//! Simulation event logging and idempotent alert reconciliation.

use crate::schema::{alert, config, event_log, Alert, EventLog, Severity};
use crate::sim::{self, Activity, SimEvent, TileKind, World};
use spacetimedb::{ReducerContext, Table};

const MAX_EVENTS: usize = 200;

/// Activity changes omit travelling; recreation denial drives an alert instead.
pub(crate) fn emit_sim_events(ctx: &ReducerContext, world: &World, events: &[SimEvent]) {
    for event in events {
        match event {
            SimEvent::ActivityChanged { name, to, .. } => {
                let verb = match to {
                    Activity::Working => "started working",
                    Activity::Hauling => "started hauling",
                    Activity::Eating => "started eating",
                    Activity::Sleeping => "went to sleep",
                    Activity::Recreating => "started recreating",
                    Activity::Idle => "went idle with nothing to do",
                    Activity::Travelling => continue,
                };
                log_event_at(ctx, world, Severity::Info, format!("{name} {verb}"));
            }
            SimEvent::SleptWithLowMood { name, mood, .. } => log_event_at(
                ctx,
                world,
                Severity::Warning,
                format!("{name} went to sleep with low mood ({:.0}%)", mood),
            ),
            SimEvent::WokePoorlyRested {
                name,
                fatigue,
                quality,
                ..
            } => log_event_at(
                ctx,
                world,
                Severity::Warning,
                format!(
                    "{name} woke poorly rested (fatigue {:.0}%, sleep quality {:.0}%)",
                    fatigue,
                    quality * 100.0
                ),
            ),
            SimEvent::MealMissed { name, .. } => log_event_at(
                ctx,
                world,
                Severity::Critical,
                format!("{name} could not eat: the colony is out of food"),
            ),
            SimEvent::RecreationDenied { .. } => {}
        }
    }
}

struct AlertSpec {
    code: &'static str,
    severity: Severity,
    /// Separate, stricter clear thresholds provide hysteresis.
    raise: bool,
    clear: bool,
    message: String,
}

pub(crate) fn reconcile_alerts(ctx: &ReducerContext, world: &World) {
    let food_per_colonist = world.resources.food / world.colonists.len().max(1) as f32;
    let mood = world.mood_ema;
    let prod = world.productivity_ema;
    let recreation_available = world.has_enabled(TileKind::Recreation);

    let specs = [
        AlertSpec {
            code: "recreation_unavailable",
            severity: Severity::Warning,
            raise: !recreation_available,
            clear: recreation_available,
            message: "Recreation became unavailable. Colonist mood will decay.".to_string(),
        },
        AlertSpec {
            code: "low_food",
            severity: Severity::Critical,
            raise: food_per_colonist < 10.0,
            clear: food_per_colonist > 20.0,
            message: format!(
                "Food reserves are low ({:.0} stored, {:.0} per colonist).",
                world.resources.food, food_per_colonist
            ),
        },
        AlertSpec {
            code: "low_mood",
            severity: Severity::Warning,
            raise: mood < 45.0,
            clear: mood > 55.0,
            message: format!("Average colonist mood dropped below 45% ({:.0}%).", mood),
        },
        AlertSpec {
            code: "low_productivity",
            severity: Severity::Warning,
            raise: prod < 80.0,
            clear: prod > 83.0,
            message: format!("Colony productivity dropped below 80% ({:.0}%).", prod),
        },
    ];

    for spec in specs {
        let existing = ctx.db.alert().code().find(spec.code.to_string());
        match existing {
            Some(mut a) if a.active => {
                if spec.clear {
                    a.active = false;
                    let code = a.code.clone();
                    ctx.db.alert().id().update(a);
                    log_event_at(
                        ctx,
                        world,
                        Severity::Info,
                        format!("Alert resolved: {}", pretty_code(&code)),
                    );
                }
            }
            Some(mut a) => {
                if spec.raise {
                    a.active = true;
                    a.acknowledged = false;
                    a.severity = spec.severity;
                    a.message = spec.message.clone();
                    a.raised_game_seconds = world.game_seconds;
                    a.raised_at = ctx.timestamp;
                    ctx.db.alert().id().update(a);
                    log_event_at(ctx, world, spec.severity, spec.message);
                }
            }
            None => {
                if spec.raise {
                    ctx.db.alert().insert(Alert {
                        id: 0,
                        code: spec.code.to_string(),
                        severity: spec.severity,
                        message: spec.message.clone(),
                        active: true,
                        acknowledged: false,
                        raised_game_seconds: world.game_seconds,
                        raised_at: ctx.timestamp,
                    });
                    log_event_at(ctx, world, spec.severity, spec.message);
                }
            }
        }
    }
}

fn pretty_code(code: &str) -> String {
    code.replace('_', " ")
}

pub(crate) fn log_event(ctx: &ReducerContext, severity: Severity, message: String) {
    let world_seconds = ctx
        .db
        .config()
        .id()
        .find(0)
        .map(|config| config.game_seconds)
        .unwrap_or(0.0);
    let day = (world_seconds / sim::SECONDS_PER_DAY) as u32 + 1;
    let sod = world_seconds.rem_euclid(sim::SECONDS_PER_DAY);
    insert_event(
        ctx,
        world_seconds,
        day,
        (sod / 3600.0) as u32,
        ((sod % 3600.0) / 60.0) as u32,
        severity,
        message,
    );
}

fn log_event_at(ctx: &ReducerContext, world: &World, severity: Severity, message: String) {
    let (hour, minute) = world.clock();
    insert_event(
        ctx,
        world.game_seconds,
        world.day(),
        hour,
        minute,
        severity,
        message,
    );
}

#[allow(clippy::too_many_arguments)]
fn insert_event(
    ctx: &ReducerContext,
    game_seconds: f64,
    day: u32,
    hour: u32,
    minute: u32,
    severity: Severity,
    message: String,
) {
    log::info!("[day {day} {hour:02}:{minute:02}] {message}");
    ctx.db.event_log().insert(EventLog {
        id: 0,
        game_seconds,
        day,
        hour,
        minute,
        severity,
        message,
        at: ctx.timestamp,
    });
}

pub(crate) fn trim_event_log(ctx: &ReducerContext) {
    let count = ctx.db.event_log().count() as usize;
    if count <= MAX_EVENTS {
        return;
    }
    let mut ids: Vec<u64> = ctx.db.event_log().iter().map(|e| e.id).collect();
    ids.sort_unstable();
    for id in ids.into_iter().take(count - MAX_EVENTS) {
        ctx.db.event_log().id().delete(id);
    }
}
