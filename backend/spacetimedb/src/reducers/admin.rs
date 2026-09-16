use crate::auth::{authorize, identity_hex, RequiredRole};
use crate::events::log_event;
use crate::persistence::{seed_colony, upsert_config};
use crate::schema::*;
use crate::speed_policy;
use crate::DEFAULT_TIME_SCALE;
use spacetimedb::{reducer, Identity, ReducerContext, Table};

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

/// Grant admin to a distinct identity. This is intentionally not self-promotion.
#[reducer]
pub fn grant_admin(ctx: &ReducerContext, identity: Identity) -> Result<(), String> {
    authorize(ctx, RequiredRole::Admin)?;
    if identity == Identity::ZERO || identity == ctx.database_identity() {
        return Err("the anonymous and database identities cannot be admins".into());
    }
    if identity == ctx.sender() {
        return Err("an admin cannot grant admin to itself".into());
    }

    let Some(existing) = ctx.db.membership().identity().find(identity) else {
        ctx.db.membership().insert(Membership {
            identity,
            role: Role::Admin,
        });
        log_event(
            ctx,
            Severity::Info,
            format!(
                "Admin {} was granted by admin {}.",
                identity_hex(identity),
                identity_hex(ctx.sender())
            ),
        );
        return Ok(());
    };
    if existing.role == Role::Admin {
        return Ok(());
    }
    ctx.db.membership().identity().update(Membership {
        identity,
        role: Role::Admin,
    });
    log_event(
        ctx,
        Severity::Info,
        format!(
            "Operator {} was promoted to admin by admin {}.",
            identity_hex(identity),
            identity_hex(ctx.sender())
        ),
    );
    Ok(())
}
