//! Stateless standing-production thresholds, independent of operator enablement.

use super::{ResourceKind, World};

/// Largest accepted target, in resource units (also limits accidental UI inputs).
pub const MAX_PRODUCTION_TARGET: f32 = 1_000_000.0;

/// Persistent intent: absent means unlimited; present means produce below target.
#[derive(Clone, Debug, PartialEq)]
pub struct ProductionPolicy {
    pub resource: ResourceKind,
    pub target: f32,
}

impl ProductionPolicy {
    /// Validate before any persistent writes. Zero is not an order-disable switch.
    pub fn new(resource: ResourceKind, target: f32) -> Result<Self, String> {
        if !target.is_finite() || target <= 0.0 || target > MAX_PRODUCTION_TARGET {
            return Err(format!(
                "Production target must be finite and in (0, {MAX_PRODUCTION_TARGET}]"
            ));
        }
        Ok(Self { resource, target })
    }
}

impl World {
    /// Stored + ground + carried goods, accumulated by durable ID, not row order.
    /// Partial excavation progress is not a resource until its cell is removed.
    pub fn total_supply(&self, resource: ResourceKind) -> f64 {
        let mut total = f64::from(self.resources.amount(resource));
        let mut stacks: Vec<_> = self.stacks.iter().filter(|s| s.kind == resource).collect();
        stacks.sort_unstable_by_key(|s| s.id);
        for stack in stacks {
            total += f64::from(stack.amount);
        }
        for index in self.colonist_order() {
            let cargo = &self.colonists[index].cargo;
            if cargo.kind == resource {
                total += f64::from(cargo.amount);
            }
        }
        total
    }

    /// Derived on every decision/action: consumption resumes production without
    /// a tick-owned pause flag or hysteresis. One bounded action may overshoot.
    pub fn production_allowed(&self, resource: ResourceKind) -> bool {
        self.production_policies
            .iter()
            .find(|p| p.resource == resource)
            .is_none_or(|p| self.total_supply(resource) < f64::from(p.target))
    }
}

#[cfg(test)]
mod tests;
