use crate::auth::{authorize, identity_hex, RequiredRole};
use crate::events::log_event;
use crate::schema::*;
use crate::sim::{HaulPolicy, MealPolicy};
use spacetimedb::{reducer, ReducerContext};

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
