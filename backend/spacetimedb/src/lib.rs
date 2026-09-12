//! SpacetimeDB entrypoint and intent-level reducers for the Continuum colony.
//! Simulation is pure; schema, authorization, persistence and events are separate.

mod auth;
mod blocks;
mod events;
mod persistence;
mod schema;
pub mod sim;
mod speed_policy;

use auth::{authorize, identity_hex, RequiredRole};
use events::{emit_sim_events, log_event, reconcile_alerts, trim_event_log};
use persistence::{load_world, save_world, seed_colony, upsert_config};
pub use schema::*;
use sim::{
    validate_facility_build, HaulPolicy, MealPolicy, TileKind, Tuning, WorkType,
    FACILITY_BUILD_WOOD_COST,
};
use spacetimedb::{reducer, Identity, ReducerContext, Table, TimeDuration};

/// Real-time scheduler interval; in-game speed is controlled by `Config::time_scale`.
const TICK_INTERVAL_MICROS: i64 = 1_000_000;

/// 4 real hours = 1 in-game day: 6 in-game seconds per real second.
pub const DEFAULT_TIME_SCALE: f64 = 6.0;

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

/// Enable or disable a single tile. Disabling recreation starts the failure chain.
#[reducer]
pub fn set_tile_enabled(ctx: &ReducerContext, tile_id: u32, enabled: bool) -> Result<(), String> {
    authorize(ctx, RequiredRole::Operator)?;
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
            "{:?} tile ({x},{y}) was {} by operator {}",
            kind,
            if enabled { "enabled" } else { "disabled" },
            identity_hex(ctx.sender())
        ),
    );
    Ok(())
}

/// Instantly turn an empty grid tile into a needs facility.
#[reducer]
pub fn build_facility(ctx: &ReducerContext, tile_id: u32, kind: TileKind) -> Result<(), String> {
    authorize(ctx, RequiredRole::Operator)?;
    let mut tile = ctx
        .db
        .tile()
        .id()
        .find(tile_id)
        .ok_or_else(|| format!("no such tile: {tile_id}"))?;
    let mut colony = ctx
        .db
        .colony()
        .id()
        .find(0)
        .ok_or_else(|| "colony is not initialised".to_string())?;
    validate_facility_build(
        &sim::Tile {
            id: tile.id,
            x: tile.x,
            y: tile.y,
            kind: tile.kind,
            enabled: tile.enabled,
        },
        kind,
        colony.wood,
    )?;
    colony.wood -= FACILITY_BUILD_WOOD_COST;
    tile.kind = kind;
    tile.enabled = true;
    ctx.db.colony().id().update(colony);
    ctx.db.tile().id().update(tile);
    log_event(
        ctx,
        Severity::Info,
        format!(
            "Built {kind:?} facility on tile {tile_id} for {:.0} stored wood by operator {}.",
            FACILITY_BUILD_WOOD_COST,
            identity_hex(ctx.sender())
        ),
    );
    Ok(())
}

/// Enable or disable every tile of a kind at once.
#[reducer]
pub fn set_zone_enabled(ctx: &ReducerContext, kind: TileKind, enabled: bool) -> Result<(), String> {
    authorize(ctx, RequiredRole::Operator)?;
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
                "{:?} zone was {} by operator {} ({changed} tiles)",
                kind,
                if enabled { "enabled" } else { "disabled" },
                identity_hex(ctx.sender())
            ),
        );
    }
    Ok(())
}

/// Create or update an intent using only the server's tile and validated tuple ID.
#[reducer]
pub fn set_work_order(
    ctx: &ReducerContext,
    tile_id: u32,
    work: WorkType,
    priority: u8,
    enabled: bool,
) -> Result<(), String> {
    authorize(ctx, RequiredRole::Operator)?;
    let tile = ctx
        .db
        .tile()
        .id()
        .find(tile_id)
        .ok_or_else(|| format!("no such tile: {tile_id}"))?;
    let order = sim::WorkOrder::new(
        &sim::Tile {
            id: tile.id,
            x: tile.x,
            y: tile.y,
            kind: tile.kind,
            enabled: tile.enabled,
        },
        work,
        priority,
        enabled,
    )?;
    let existing = ctx.db.work_order().id().find(order.id);
    if existing.as_ref().is_some_and(|existing| {
        existing.tile_id == order.tile_id
            && existing.work == order.work
            && existing.priority == order.priority
            && existing.enabled == order.enabled
    }) {
        return Ok(());
    }
    let row = WorkOrder {
        id: order.id,
        tile_id: order.tile_id,
        work: order.work,
        priority: order.priority,
        enabled: order.enabled,
    };
    if existing.is_some() {
        ctx.db.work_order().id().update(row);
    } else {
        ctx.db.work_order().insert(row);
    }
    log_event(
        ctx,
        Severity::Info,
        format!(
            "Work order {} ({work:?}, tile {tile_id}) set to priority {priority}, enabled {enabled} by operator {}.",
            order.id,
            identity_hex(ctx.sender())
        ),
    );
    Ok(())
}

#[reducer]
pub fn remove_work_order(ctx: &ReducerContext, order_id: u64) -> Result<(), String> {
    authorize(ctx, RequiredRole::Operator)?;
    let order = ctx
        .db
        .work_order()
        .id()
        .find(order_id)
        .ok_or_else(|| format!("no such work order: {order_id}"))?;
    ctx.db.work_order().id().delete(order_id);
    log_event(
        ctx,
        Severity::Info,
        format!(
            "Work order {order_id} ({:?}, tile {}) removed by operator {}.",
            order.work,
            order.tile_id,
            identity_hex(ctx.sender())
        ),
    );
    Ok(())
}

#[reducer]
pub fn set_haul_policy(ctx: &ReducerContext, policy: HaulPolicy) -> Result<(), String> {
    authorize(ctx, RequiredRole::Operator)?;
    let mut config = ctx
        .db
        .config()
        .id()
        .find(0)
        .ok_or_else(|| "colony is not initialised".to_string())?;
    if config.haul_policy == policy {
        return Ok(());
    }
    config.haul_policy = policy;
    ctx.db.config().id().update(config);
    log_event(
        ctx,
        Severity::Info,
        format!(
            "Hauling mode changed to {policy:?} by operator {}.",
            identity_hex(ctx.sender())
        ),
    );
    Ok(())
}

/// Set the colony-wide meal policy. Rationing saves food at the cost of slower
/// hunger recovery; the simulation's normal hunger-to-mood relationship applies.
#[reducer]
pub fn set_meal_policy(ctx: &ReducerContext, policy: MealPolicy) -> Result<(), String> {
    authorize(ctx, RequiredRole::Operator)?;
    let mut config = ctx
        .db
        .config()
        .id()
        .find(0)
        .ok_or_else(|| "colony is not initialised".to_string())?;
    if config.meal_policy == policy {
        return Ok(());
    }
    config.meal_policy = policy;
    ctx.db.config().id().update(config);
    log_event(
        ctx,
        Severity::Info,
        format!(
            "Meal policy changed to {policy:?} by operator {}.",
            identity_hex(ctx.sender())
        ),
    );
    Ok(())
}

#[reducer]
pub fn acknowledge_alert(ctx: &ReducerContext, alert_id: u64) -> Result<(), String> {
    authorize(ctx, RequiredRole::Operator)?;
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
        format!(
            "Alert acknowledged by operator {}: {message}",
            identity_hex(ctx.sender())
        ),
    );
    Ok(())
}

/// Admin-only development helper. `6.0` is 4 real hours per in-game day.
#[reducer]
pub fn set_time_scale(ctx: &ReducerContext, time_scale: f64) -> Result<(), String> {
    authorize(ctx, RequiredRole::Admin)?;
    speed_policy::validate_time_scale(time_scale)?;
    let Some(config) = ctx.db.config().id().find(0) else {
        return Err("colony is not initialised".into());
    };
    let previous = config.time_scale;
    if previous == time_scale {
        return Ok(());
    }
    let control = ctx.db.speed_control().id().find(0).unwrap_or(SpeedControl {
        id: 0,
        cooldown_seconds: 0,
        last_changed_at: None,
    });
    if let Some(last_changed_at) = control.last_changed_at {
        let remaining = speed_policy::remaining_cooldown_seconds(
            control.cooldown_seconds,
            ctx.timestamp.to_micros_since_unix_epoch(),
            last_changed_at.to_micros_since_unix_epoch(),
        );
        if remaining > 0 {
            return Err(format!(
                "speed changes are on cooldown; {remaining} seconds remaining"
            ));
        }
    }
    upsert_config(
        ctx,
        Config {
            time_scale,
            ..config
        },
    );
    let updated_control = SpeedControl {
        last_changed_at: Some(ctx.timestamp),
        ..control
    };
    if ctx.db.speed_control().id().find(0).is_some() {
        ctx.db.speed_control().id().update(updated_control);
    } else {
        ctx.db.speed_control().insert(updated_control);
    }
    log_event(
        ctx,
        Severity::Info,
        format!(
            "Simulation speed changed by admin {}: {previous:.0}x -> {time_scale:.0}x in-game seconds per real second",
            identity_hex(ctx.sender())
        ),
    );
    Ok(())
}

/// Set the admin-only real-time cooldown between actual speed changes.
#[reducer]
pub fn set_speed_change_cooldown(
    ctx: &ReducerContext,
    cooldown_seconds: u32,
) -> Result<(), String> {
    authorize(ctx, RequiredRole::Admin)?;
    speed_policy::validate_cooldown(cooldown_seconds)?;
    let control = ctx.db.speed_control().id().find(0).unwrap_or(SpeedControl {
        id: 0,
        cooldown_seconds: 0,
        last_changed_at: None,
    });
    if control.cooldown_seconds == cooldown_seconds {
        return Ok(());
    }
    let updated_control = SpeedControl {
        cooldown_seconds,
        ..control
    };
    if ctx.db.speed_control().id().find(0).is_some() {
        ctx.db.speed_control().id().update(updated_control);
    } else {
        ctx.db.speed_control().insert(updated_control);
    }
    log_event(
        ctx,
        Severity::Info,
        format!(
            "Speed-change cooldown set to {cooldown_seconds} seconds by admin {}.",
            identity_hex(ctx.sender())
        ),
    );
    Ok(())
}

/// Development helper: wipe the colony and start over from the default layout.
#[reducer]
pub fn reset_colony(ctx: &ReducerContext) -> Result<(), String> {
    authorize(ctx, RequiredRole::Admin)?;
    let time_scale = ctx
        .db
        .config()
        .id()
        .find(0)
        .map(|config| config.time_scale)
        .unwrap_or(DEFAULT_TIME_SCALE);
    seed_colony(ctx, time_scale);
    log_event(
        ctx,
        Severity::Info,
        format!("Colony was reset by admin {}.", identity_hex(ctx.sender())),
    );
    Ok(())
}

/// Admin-only membership management; the bootstrap admin cannot be removed.
#[reducer]
pub fn set_operator(
    ctx: &ReducerContext,
    identity: Identity,
    authorized: bool,
) -> Result<(), String> {
    authorize(ctx, RequiredRole::Admin)?;
    if identity == Identity::ZERO || identity == ctx.database_identity() {
        return Err("the anonymous and database identities cannot be operators".into());
    }
    let existing = ctx.db.membership().identity().find(identity);
    if existing
        .as_ref()
        .is_some_and(|member| member.role == Role::Admin)
    {
        return Err("admin membership cannot be changed with `set_operator`".into());
    }
    let changed = if authorized {
        if existing.is_some() {
            false
        } else {
            ctx.db.membership().insert(Membership {
                identity,
                role: Role::Operator,
            });
            true
        }
    } else {
        ctx.db.membership().identity().delete(identity)
    };
    if changed {
        log_event(
            ctx,
            Severity::Info,
            format!(
                "Operator {} was {} by admin {}.",
                identity_hex(identity),
                if authorized { "authorized" } else { "revoked" },
                identity_hex(ctx.sender())
            ),
        );
    }
    Ok(())
}

#[cfg(test)]
mod work_order_validation_tests {
    use super::sim::{Tile, TileKind, WorkOrder, WorkType};

    #[test]
    fn work_order_input_rejects_non_producing_work_wrong_facility_and_invalid_priorities() {
        let tile = Tile {
            id: 7,
            x: 0,
            y: 0,
            kind: TileKind::Farm,
            enabled: true,
        };
        assert!(WorkOrder::new(&tile, WorkType::None, 2, true).is_err());
        assert!(WorkOrder::new(&tile, WorkType::Mining, 2, true).is_err());
        for priority in [0, 4, u8::MAX] {
            assert!(WorkOrder::new(&tile, WorkType::Farming, priority, false).is_err());
        }
    }

    #[test]
    fn work_order_id_is_stable_across_priority_and_enabled_changes() {
        for work in [
            WorkType::Farming,
            WorkType::Logging,
            WorkType::Mining,
            WorkType::Hunting,
        ] {
            let tile = Tile {
                id: u32::MAX,
                x: 0,
                y: 0,
                kind: work.definition().unwrap().facility,
                enabled: false,
            };
            let original = WorkOrder::new(&tile, work, 1, true).unwrap();
            for priority in 1..=3 {
                for enabled in [false, true] {
                    let order = WorkOrder::new(&tile, work, priority, enabled).unwrap();
                    assert_eq!(order.id, original.id);
                    assert_eq!(order.tile_id, tile.id);
                    assert_eq!(order.work, work);
                    assert_eq!(order.priority, priority);
                    assert_eq!(order.enabled, enabled);
                }
            }
        }
    }
}
