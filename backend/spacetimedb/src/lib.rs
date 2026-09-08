//! SpacetimeDB glue for the Continuum colony.
//!
//! Everything here is bookkeeping: table definitions, loading rows into the pure
//! [`sim`] world, running one tick, writing rows back, and reconciling alerts and
//! the event log. The actual colony behaviour lives in `sim.rs`.
//!
//! Clients never mutate state directly. They subscribe to the public tables and
//! call the intent-level reducers at the bottom of this file.

pub mod sim;

use sim::{Activity, Goal, Resources, SimEvent, TileKind, Tuning, WorkType, World};
use spacetimedb::{reducer, table, ReducerContext, Table, TimeDuration};

/// How often the scheduled tick reducer runs, in real time. In-game speed is
/// controlled by `Config::time_scale`, not by this interval.
const TICK_INTERVAL_MICROS: i64 = 1_000_000;

/// 4 real hours = 1 in-game day  =>  86400 / 14400 = 6 in-game seconds per real second.
pub const DEFAULT_TIME_SCALE: f64 = 6.0;

/// Cap on the event log, so a colony running for months does not grow forever.
const MAX_EVENTS: usize = 200;

/// Singleton colony configuration and clock. `id` is always 0.
#[table(accessor = config, public)]
pub struct Config {
    #[primary_key]
    pub id: u32,
    /// In-game seconds that pass per real second. 6.0 == 4 real hours per day.
    pub time_scale: f64,
    /// Total in-game seconds since the colony was founded.
    pub game_seconds: f64,
    /// Bumped every time the colony is reset; handy when debugging clients.
    pub generation: u32,
}

#[table(accessor = colony, public)]
pub struct Colony {
    #[primary_key]
    pub id: u32,
    pub food: f32,
    pub food_capacity: f32,
    /// Instantaneous colony averages.
    pub avg_mood: f32,
    pub avg_productivity: f32,
    /// Day-scale smoothed averages. Alerts are driven by these so they do not
    /// flap every time the whole colony goes to bed at once.
    pub smoothed_mood: f32,
    pub smoothed_productivity: f32,
    pub population: u32,
}

#[table(accessor = tile, public, index(accessor = by_kind, btree(columns = [kind])))]
pub struct Tile {
    #[primary_key]
    pub id: u32,
    pub x: i32,
    pub y: i32,
    pub kind: TileKind,
    pub enabled: bool,
}

#[table(accessor = colonist, public)]
pub struct Colonist {
    #[primary_key]
    pub id: u64,
    pub name: String,
    pub x: i32,
    pub y: i32,
    pub move_progress: f32,
    pub target_x: i32,
    pub target_y: i32,
    pub activity: Activity,
    pub work: WorkType,
    pub goal: Goal,
    pub hunger: f32,
    pub fatigue: f32,
    pub recreation: f32,
    pub mood: f32,
    pub productivity: f32,
    pub sleep_hours: f32,
    pub last_sleep_quality: f32,
}

#[derive(spacetimedb::SpacetimeType, Clone, Copy, PartialEq, Eq, Debug)]
pub enum Severity {
    Info,
    Warning,
    Critical,
}

/// One row per *kind* of problem, keyed by `code`. Raising an already-active
/// alert is a no-op, which is what keeps the log from being spammed.
#[table(accessor = alert, public)]
pub struct Alert {
    #[primary_key]
    #[auto_inc]
    pub id: u64,
    #[unique]
    pub code: String,
    pub severity: Severity,
    pub message: String,
    pub active: bool,
    pub acknowledged: bool,
    pub raised_game_seconds: f64,
    pub raised_at: spacetimedb::Timestamp,
}

#[table(accessor = event_log, public)]
pub struct EventLog {
    #[primary_key]
    #[auto_inc]
    pub id: u64,
    pub game_seconds: f64,
    pub day: u32,
    pub hour: u32,
    pub minute: u32,
    pub severity: Severity,
    pub message: String,
    pub at: spacetimedb::Timestamp,
}

/// Scheduling table for the simulation tick. Deleting the row stops the colony;
/// inserting it starts it again.
#[table(accessor = tick_schedule, scheduled(tick))]
pub struct TickSchedule {
    #[primary_key]
    pub scheduled_id: u64,
    pub scheduled_at: spacetimedb::ScheduleAt,
}

#[reducer(init)]
pub fn init(ctx: &ReducerContext) {
    seed_colony(ctx, DEFAULT_TIME_SCALE);

    ctx.db.tick_schedule().insert(TickSchedule {
        scheduled_id: 0,
        scheduled_at: TimeDuration::from_micros(TICK_INTERVAL_MICROS).into(),
    });

    log_event(
        ctx,
        Severity::Info,
        "Colony founded. Simulation running.".to_string(),
    );
}

/// Wipe colony state and recreate it from the default layout.
fn seed_colony(ctx: &ReducerContext, time_scale: f64) {
    for tile in ctx.db.tile().iter() {
        ctx.db.tile().id().delete(&tile.id);
    }
    for colonist in ctx.db.colonist().iter() {
        ctx.db.colonist().id().delete(&colonist.id);
    }
    for alert in ctx.db.alert().iter() {
        ctx.db.alert().id().delete(&alert.id);
    }
    for event in ctx.db.event_log().iter() {
        ctx.db.event_log().id().delete(&event.id);
    }

    let world = sim::new_world();

    for tile in &world.tiles {
        ctx.db.tile().insert(Tile {
            id: tile.id,
            x: tile.x,
            y: tile.y,
            kind: tile.kind,
            enabled: tile.enabled,
        });
    }
    for colonist in &world.colonists {
        ctx.db.colonist().insert(colonist_row(colonist));
    }

    let generation = ctx
        .db
        .config()
        .id()
        .find(0)
        .map(|config| config.generation + 1)
        .unwrap_or(1);
    upsert_config(
        ctx,
        Config {
            id: 0,
            time_scale,
            game_seconds: world.game_seconds,
            generation,
        },
    );
    upsert_colony(
        ctx,
        Colony {
            id: 0,
            food: world.resources.food,
            food_capacity: world.resources.food_capacity,
            avg_mood: world.avg_mood(),
            avg_productivity: world.avg_productivity(),
            smoothed_mood: world.mood_ema,
            smoothed_productivity: world.productivity_ema,
            population: world.colonists.len() as u32,
        },
    );
}

fn upsert_config(ctx: &ReducerContext, row: Config) {
    if ctx.db.config().id().find(0).is_some() {
        ctx.db.config().id().update(row);
    } else {
        ctx.db.config().insert(row);
    }
}

fn upsert_colony(ctx: &ReducerContext, row: Colony) {
    if ctx.db.colony().id().find(0).is_some() {
        ctx.db.colony().id().update(row);
    } else {
        ctx.db.colony().insert(row);
    }
}

fn load_world(ctx: &ReducerContext) -> World {
    let mut tiles: Vec<sim::Tile> = ctx
        .db
        .tile()
        .iter()
        .map(|tile| sim::Tile {
            id: tile.id,
            x: tile.x,
            y: tile.y,
            kind: tile.kind,
            enabled: tile.enabled,
        })
        .collect();
    tiles.sort_by_key(|tile| tile.id);

    let mut colonists: Vec<sim::Colonist> = ctx
        .db
        .colonist()
        .iter()
        .map(|colonist| sim::Colonist {
            id: colonist.id,
            name: colonist.name,
            x: colonist.x,
            y: colonist.y,
            move_progress: colonist.move_progress,
            target_x: colonist.target_x,
            target_y: colonist.target_y,
            activity: colonist.activity,
            work: colonist.work,
            goal: colonist.goal,
            hunger: colonist.hunger,
            fatigue: colonist.fatigue,
            recreation: colonist.recreation,
            mood: colonist.mood,
            productivity: colonist.productivity,
            sleep_hours: colonist.sleep_hours,
            last_sleep_quality: colonist.last_sleep_quality,
        })
        .collect();
    colonists.sort_by_key(|colonist| colonist.id);

    let colony = ctx.db.colony().id().find(0);
    let config = ctx.db.config().id().find(0);

    World {
        tiles,
        colonists,
        resources: Resources {
            food: colony.as_ref().map(|colony| colony.food).unwrap_or(0.0),
            food_capacity: colony
                .as_ref()
                .map(|colony| colony.food_capacity)
                .unwrap_or(100.0),
        },
        game_seconds: config
            .as_ref()
            .map(|config| config.game_seconds)
            .unwrap_or(0.0),
        mood_ema: colony
            .as_ref()
            .map(|colony| colony.smoothed_mood)
            .unwrap_or(80.0),
        productivity_ema: colony
            .as_ref()
            .map(|colony| colony.smoothed_productivity)
            .unwrap_or(90.0),
    }
}

fn colonist_row(colonist: &sim::Colonist) -> Colonist {
    Colonist {
        id: colonist.id,
        name: colonist.name.clone(),
        x: colonist.x,
        y: colonist.y,
        move_progress: colonist.move_progress,
        target_x: colonist.target_x,
        target_y: colonist.target_y,
        activity: colonist.activity,
        work: colonist.work,
        goal: colonist.goal,
        hunger: colonist.hunger,
        fatigue: colonist.fatigue,
        recreation: colonist.recreation,
        mood: colonist.mood,
        productivity: colonist.productivity,
        sleep_hours: colonist.sleep_hours,
        last_sleep_quality: colonist.last_sleep_quality,
    }
}

#[reducer]
pub fn tick(ctx: &ReducerContext, _arg: TickSchedule) -> Result<(), String> {
    if ctx.sender() != ctx.database_identity() {
        return Err("`tick` may only be invoked by the scheduler".into());
    }

    let Some(config) = ctx.db.config().id().find(0) else {
        return Ok(());
    };

    let tuning = Tuning::default();
    let mut world = load_world(ctx);

    let dt_real_seconds = TICK_INTERVAL_MICROS as f64 / 1_000_000.0;
    let dt_game_seconds = dt_real_seconds * config.time_scale;

    let events = sim::step(&mut world, &tuning, dt_game_seconds);

    for colonist in &world.colonists {
        ctx.db.colonist().id().update(colonist_row(colonist));
    }
    upsert_colony(
        ctx,
        Colony {
            id: 0,
            food: world.resources.food,
            food_capacity: world.resources.food_capacity,
            avg_mood: world.avg_mood(),
            avg_productivity: world.avg_productivity(),
            smoothed_mood: world.mood_ema,
            smoothed_productivity: world.productivity_ema,
            population: world.colonists.len() as u32,
        },
    );
    upsert_config(
        ctx,
        Config {
            id: 0,
            game_seconds: world.game_seconds,
            ..config
        },
    );

    emit_sim_events(ctx, &world, &events);
    reconcile_alerts(ctx, &world);
    trim_event_log(ctx);

    Ok(())
}

/// Turn simulation events into human-readable log lines.
///
/// Activity changes are only logged when they are interesting (not every
/// `Travelling` hop), and `RecreationDenied` is intentionally not logged here at
/// all: it drives the `recreation_unavailable` alert instead, which is
/// idempotent, so the log does not fill with the same line every few minutes.
fn emit_sim_events(ctx: &ReducerContext, world: &World, events: &[SimEvent]) {
    for event in events {
        match event {
            SimEvent::ActivityChanged { name, to, .. } => {
                let verb = match to {
                    Activity::Working => "started working",
                    Activity::Eating => "started eating",
                    Activity::Sleeping => "went to sleep",
                    Activity::Recreating => "started recreating",
                    Activity::Idle => "went idle with nothing to do",
                    // Travelling is noise; a colonist is always travelling
                    // between the interesting states.
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
    /// Condition to raise. Hysteresis is handled by `clear` being a *separate*,
    /// stricter condition, so alerts do not flap around a single threshold.
    raise: bool,
    clear: bool,
    message: String,
}

fn reconcile_alerts(ctx: &ReducerContext, world: &World) {
    let food_pct = if world.resources.food_capacity > 0.0 {
        world.resources.food / world.resources.food_capacity * 100.0
    } else {
        0.0
    };
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
            raise: food_pct < 25.0,
            clear: food_pct > 40.0,
            message: format!(
                "Food reached low threshold ({:.0} / {:.0}).",
                world.resources.food, world.resources.food_capacity
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

fn log_event(ctx: &ReducerContext, severity: Severity, message: String) {
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

fn trim_event_log(ctx: &ReducerContext) {
    let count = ctx.db.event_log().count() as usize;
    if count <= MAX_EVENTS {
        return;
    }
    let mut ids: Vec<u64> = ctx.db.event_log().iter().map(|e| e.id).collect();
    ids.sort_unstable();
    for id in ids.into_iter().take(count - MAX_EVENTS) {
        ctx.db.event_log().id().delete(&id);
    }
}

/// Enable or disable a single tile. Disabling the recreation tiles is what kicks
/// off the failure chain.
#[reducer]
pub fn set_tile_enabled(ctx: &ReducerContext, tile_id: u32, enabled: bool) -> Result<(), String> {
    let mut tile = ctx
        .db
        .tile()
        .id()
        .find(tile_id)
        .ok_or_else(|| format!("no such tile: {tile_id}"))?;

    if tile.kind == TileKind::Empty {
        return Err("empty tiles cannot be enabled or disabled".into());
    }
    if tile.enabled == enabled {
        return Ok(());
    }

    tile.enabled = enabled;
    let kind = tile.kind;
    let (x, y) = (tile.x, tile.y);
    ctx.db.tile().id().update(tile);

    log_event(
        ctx,
        Severity::Info,
        format!(
            "{:?} tile ({x},{y}) was {} by a colony operator",
            kind,
            if enabled { "enabled" } else { "disabled" }
        ),
    );
    Ok(())
}

/// Enable or disable every tile of a kind at once. This is what the Godot client
/// uses for its "Recreation: on/off" toggle.
#[reducer]
pub fn set_zone_enabled(ctx: &ReducerContext, kind: TileKind, enabled: bool) -> Result<(), String> {
    if kind == TileKind::Empty {
        return Err("empty tiles cannot be enabled or disabled".into());
    }
    let mut changed = 0u32;
    for mut tile in ctx.db.tile().iter().filter(|tile| tile.kind == kind) {
        if tile.enabled != enabled {
            tile.enabled = enabled;
            ctx.db.tile().id().update(tile);
            changed += 1;
        }
    }
    if changed > 0 {
        log_event(
            ctx,
            Severity::Info,
            format!(
                "{:?} zone was {} by a colony operator ({changed} tiles)",
                kind,
                if enabled { "enabled" } else { "disabled" }
            ),
        );
    }
    Ok(())
}

#[reducer]
pub fn acknowledge_alert(ctx: &ReducerContext, alert_id: u64) -> Result<(), String> {
    let mut alert = ctx
        .db
        .alert()
        .id()
        .find(alert_id)
        .ok_or_else(|| format!("no such alert: {alert_id}"))?;
    if alert.acknowledged {
        return Ok(());
    }
    alert.acknowledged = true;
    let message = alert.message.clone();
    ctx.db.alert().id().update(alert);
    log_event(
        ctx,
        Severity::Info,
        format!("Alert acknowledged: {message}"),
    );
    Ok(())
}

/// Development helper: change how fast in-game time passes.
/// `6.0` is the intended rate (4 real hours per in-game day).
#[reducer]
pub fn set_time_scale(ctx: &ReducerContext, time_scale: f64) -> Result<(), String> {
    if !(0.0..=100_000.0).contains(&time_scale) {
        return Err("time_scale must be between 0 and 100000".into());
    }
    let Some(config) = ctx.db.config().id().find(0) else {
        return Err("colony is not initialised".into());
    };
    let previous = config.time_scale;
    upsert_config(
        ctx,
        Config {
            time_scale,
            ..config
        },
    );
    log_event(
        ctx,
        Severity::Info,
        format!("Simulation speed changed: {previous:.0}x -> {time_scale:.0}x in-game seconds per real second"),
    );
    Ok(())
}

/// Development helper: wipe the colony and start over from the default layout.
#[reducer]
pub fn reset_colony(ctx: &ReducerContext) -> Result<(), String> {
    let time_scale = ctx
        .db
        .config()
        .id()
        .find(0)
        .map(|config| config.time_scale)
        .unwrap_or(DEFAULT_TIME_SCALE);
    seed_colony(ctx, time_scale);
    log_event(ctx, Severity::Info, "Colony was reset.".to_string());
    Ok(())
}
