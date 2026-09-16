//! Pure simulation core for Continuum.
//!
//! This module deliberately contains **no** SpacetimeDB glue: no `ReducerContext`,
//! no table handles, no database scheduling. It owns a plain-old-data `World` and advances
//! it by a number of in-game seconds. `lib.rs` is responsible for loading rows into
//! a `World`, calling [`step`], and writing the result back.
//!
//! Actors compose independent state; the explicit simulation schedule preserves
//! per-actor ordering. Persistence translates components to the public schema.
//! See `docs/simulation-architecture.md` for extension guardrails.

mod definitions;
mod tuning;
mod work_orders;
pub use definitions::{
    validate_facility_build, Activity, Goal, HaulPolicy, HaulRole, MealPolicy, ResourceKind,
    TileKind, WorkDefinition, WorkType, FACILITY_BUILD_WOOD_COST, RESOURCE_KINDS,
};
pub use tuning::Tuning;
pub use work_orders::{default_work_orders, WorkOrder};
pub mod terrain;

pub const GRID_W: i32 = 24;
pub const GRID_H: i32 = 24;

/// In-game seconds in one in-game day.
pub const SECONDS_PER_DAY: f64 = 86_400.0;

/// Maximum decision/activity interval processed by the simulation core.
const MAX_STEP_SECONDS: f64 = 60.0;

mod components;
mod decisions;
mod logistics;
mod movement;
mod needs;
mod schedule;
mod seed;
mod world;

pub use components::{
    ActivityState, Cargo, Colonist, Movement, Needs, Position, Rest, Wellbeing, WorkAssignment,
};
pub use needs::sleep_quality;
pub use schedule::{step, SimEvent};
pub use seed::{default_colonists, default_tiles, new_world};
pub use world::{stack_id, ItemStack, Resources, Tile, World};

#[cfg(test)]
mod contracts;
#[cfg(test)]
mod tests;
