//! SpacetimeDB entrypoint and intent-level reducers for the Continuum colony.
//! Simulation is pure; schema, authorization, persistence and events are separate.

mod auth;
mod blocks;
mod events;
mod persistence;
mod reducers;
mod schema;
pub mod sim;
mod speed_policy;

use auth::{authorize, identity_hex, RequiredRole};
use events::{emit_sim_events, log_event, reconcile_alerts, trim_event_log};
use persistence::{load_world, save_world, seed_colony};
pub use reducers::*;
pub use schema::*;
use sim::Tuning;
use spacetimedb::{reducer, view, Identity, ReducerContext, Table, TimeDuration, ViewContext};

/// Real-time scheduler interval; in-game speed is controlled by `Config::time_scale`.
const TICK_INTERVAL_MICROS: i64 = 1_000_000;

/// 4 real hours = 1 in-game day: 6 in-game seconds per real second.
pub const DEFAULT_TIME_SCALE: f64 = 6.0;

/// Authenticated, sender-filtered role discovery. Missing membership is Viewer.
#[view(accessor = my_role, public)]
pub fn my_role(ctx: &ViewContext) -> Option<Membership> {
    ctx.db.membership().identity().find(ctx.sender())
}

#[reducer(init)]
pub fn init(ctx: &ReducerContext) -> Result<(), String> {
    let owner = ctx.sender();
    if owner == Identity::ZERO || owner == ctx.database_identity() {
        return Err("database initialization requires an authenticated publishing identity".into());
    }
    ctx.db.membership().insert(Membership {
        identity: owner,
        role: Role::Admin,
    });

    seed_colony(ctx, DEFAULT_TIME_SCALE);
    ctx.db.tick_schedule().insert(TickSchedule {
        scheduled_id: 0,
        scheduled_at: TimeDuration::from_micros(TICK_INTERVAL_MICROS).into(),
    });
    log_event(
        ctx,
        Severity::Info,
        format!(
            "Colony founded by admin {}. Simulation running.",
            identity_hex(owner)
        ),
    );
    Ok(())
}

#[reducer]
pub fn tick(ctx: &ReducerContext, _arg: TickSchedule) -> Result<(), String> {
    authorize(ctx, RequiredRole::Scheduler)?;
    let Some(config) = ctx.db.config().id().find(0) else {
        return Ok(());
    };
    let tuning = Tuning::default();
    let mut world = load_world(ctx);
    let dt_real_seconds = TICK_INTERVAL_MICROS as f64 / 1_000_000.0;
    let dt_game_seconds = dt_real_seconds * config.time_scale;
    let events = sim::step(&mut world, &tuning, dt_game_seconds);
    save_world(ctx, &world, config);
    emit_sim_events(ctx, &world, &events);
    reconcile_alerts(ctx, &world);
    trim_event_log(ctx);
    Ok(())
}

/// Authenticated transport diagnostic with no world or permission dependency.
#[reducer]
pub fn diagnostic_echo(_ctx: &ReducerContext, _nonce: u64) -> Result<(), String> {
    Ok(())
}
