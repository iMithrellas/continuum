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
        .map(|member| member.role);
    let role = effective_role(role, ctx.sender(), ctx.database_identity());

    if role_allows(role, required) {
        Ok(role)
    } else {
        Err("caller lacks the required colony role".to_string())
    }
}

/// Joining authenticated players operate; only a persisted assignment can revoke
/// that default. Anonymous/database senders never inherit player permissions.
pub(crate) fn effective_role(stored: Option<Role>, sender: Identity, database: Identity) -> Role {
    if sender == Identity::ZERO || sender == database {
        Role::Viewer
    } else {
        stored.unwrap_or(Role::Operator)
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
        assert!(!role_allows(Role::Viewer, RequiredRole::Operator));
        assert!(!role_allows(Role::Viewer, RequiredRole::Admin));
        assert!(!role_allows(Role::Viewer, RequiredRole::Scheduler));
    }

    #[test]
    fn default_players_operate_but_explicit_assignments_and_invalid_senders_are_preserved() {
        use super::effective_role;
        use spacetimedb::Identity;
        let player = Identity::from_byte_array([1; 32]);
        let database = Identity::from_byte_array([2; 32]);
        assert_eq!(effective_role(None, player, database), Role::Operator);
        for role in [Role::Admin, Role::Operator, Role::Viewer] {
            assert_eq!(effective_role(Some(role), player, database), role);
        }
        assert_eq!(effective_role(None, Identity::ZERO, database), Role::Viewer);
        assert_eq!(effective_role(None, database, database), Role::Viewer);
    }
}
