//! Authorization shared by all externally callable reducers.

use crate::schema::{membership, Role};
use spacetimedb::{Identity, ReducerContext};

#[derive(Clone, Copy)]
pub(crate) enum RequiredRole {
    Scheduler,
    Operator,
    Admin,
}

pub(crate) fn authorize(ctx: &ReducerContext, required: RequiredRole) -> Result<Role, String> {
    if matches!(required, RequiredRole::Scheduler) {
        return (ctx.sender() == ctx.database_identity())
            .then_some(Role::Admin)
            .ok_or_else(|| "`tick` may only be invoked by the scheduler".to_string());
    }

    let role = ctx
        .db
        .membership()
        .identity()
        .find(ctx.sender())
        .map(|member| member.role)
        .ok_or_else(|| "caller is not an authorized colony member".to_string())?;

    if role_allows(role, required) {
        Ok(role)
    } else {
        Err("this command requires a colony admin".to_string())
    }
}

fn role_allows(role: Role, required: RequiredRole) -> bool {
    matches!(
        (required, role),
        (RequiredRole::Operator, Role::Operator | Role::Admin) | (RequiredRole::Admin, Role::Admin)
    )
}

pub(crate) fn identity_hex(identity: Identity) -> String {
    identity.to_hex().to_string()
}

#[cfg(test)]
mod tests {
    use super::{role_allows, RequiredRole, Role};

    #[test]
    fn admins_inherit_operator_access_but_operators_do_not_get_admin_access() {
        assert!(role_allows(Role::Admin, RequiredRole::Admin));
        assert!(role_allows(Role::Admin, RequiredRole::Operator));
        assert!(role_allows(Role::Operator, RequiredRole::Operator));
        assert!(!role_allows(Role::Operator, RequiredRole::Admin));
        assert!(!role_allows(Role::Admin, RequiredRole::Scheduler));
        assert!(!role_allows(Role::Operator, RequiredRole::Scheduler));
    }
}
