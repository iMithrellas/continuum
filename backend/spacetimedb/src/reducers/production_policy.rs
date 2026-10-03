//! Authorized, idempotent production intent writes; no simulation advancement.
use crate::auth::{authorize, identity_hex, RequiredRole};
use crate::events::log_event;
use crate::schema::*;
use crate::sim::ResourceKind;
use spacetimedb::{reducer, ReducerContext, Table};

/// Set one resource-wide target. Admins inherit operator permission.
/// Reject invalid inputs atomically, before touching any intent or audit row.
#[reducer]
pub fn set_production_policy(
    ctx: &ReducerContext,
    resource: ResourceKind,
    target: f32,
) -> Result<(), String> {
    authorize(ctx, RequiredRole::Operator)?;
    let policy = crate::sim::ProductionPolicy::new(resource, target)?;
    let existing = ctx.db.production_policy().resource().find(resource);
    if existing
        .as_ref()
        .is_some_and(|row| row.target == policy.target)
    {
        return Ok(());
    }
    let row = ProductionPolicy {
        resource,
        target: policy.target,
    };
    if existing.is_some() {
        ctx.db.production_policy().resource().update(row);
    } else {
        ctx.db.production_policy().insert(row);
    }
    log_event(
        ctx,
        Severity::Info,
        format!(
            "Production policy {resource:?} target set to {target} by operator {}.",
            identity_hex(ctx.sender())
        ),
    );
    Ok(())
}

/// Restore unlimited production for one resource. Missing rows are a no-op.
#[reducer]
pub fn remove_production_policy(
    ctx: &ReducerContext,
    resource: ResourceKind,
) -> Result<(), String> {
    authorize(ctx, RequiredRole::Operator)?;
    if ctx
        .db
        .production_policy()
        .resource()
        .find(resource)
        .is_none()
    {
        return Ok(());
    }
    ctx.db.production_policy().resource().delete(resource);
    log_event(
        ctx,
        Severity::Info,
        format!(
            "Production policy {resource:?} removed by operator {}.",
            identity_hex(ctx.sender())
        ),
    );
    Ok(())
}
