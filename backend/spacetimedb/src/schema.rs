//! Database rows and public wire types. Accessor names are stable across refactors.

use crate::sim::{Activity, Goal, HaulPolicy, HaulRole, ResourceKind, TileKind, WorkType};
use crate::tick;
use spacetimedb::{table, Identity};

#[derive(spacetimedb::SpacetimeType, Clone, Copy, PartialEq, Eq, Debug)]
pub enum Role {
    Admin,
    Operator,
}

/// Private authorization state. The publishing identity is the sole initial admin.
#[table(accessor = membership)]
pub struct Membership {
    #[primary_key]
    pub identity: Identity,
    pub role: Role,
}

/// Singleton colony configuration and clock. `id` is always 0.
#[table(accessor = config, public)]
pub struct Config {
    #[primary_key]
    pub id: u32,
    /// In-game seconds that pass per real second. 6.0 == 4 real hours per day.
    pub time_scale: f64,
    pub game_seconds: f64,
    /// Bumped every time the colony is reset.
    pub generation: u32,
    pub haul_policy: HaulPolicy,
}

/// Singleton admin policy for speed changes. Missing rows on additive updates
/// behave as the disabled default until the first policy or speed write.
#[table(accessor = speed_control, public)]
pub struct SpeedControl {
    #[primary_key]
    pub id: u32,
    pub cooldown_seconds: u32,
    pub last_changed_at: Option<spacetimedb::Timestamp>,
}

#[table(accessor = colony, public)]
pub struct Colony {
    #[primary_key]
    pub id: u32,
    pub food: f32,
    pub wood: f32,
    pub stone: f32,
    pub meat: f32,
    pub avg_mood: f32,
    pub avg_productivity: f32,
    /// Day-scale smoothed averages drive alerts rather than instantaneous values.
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
    pub haul_role: HaulRole,
    pub carried_kind: ResourceKind,
    pub carried_amount: f32,
    pub goal: Goal,
    pub hunger: f32,
    pub fatigue: f32,
    pub recreation: f32,
    pub mood: f32,
    pub productivity: f32,
    pub sleep_hours: f32,
    pub last_sleep_quality: f32,
}

#[table(accessor = item_stack, public)]
pub struct ItemStack {
    #[primary_key]
    pub id: u64,
    pub tile_id: u32,
    pub x: i32,
    pub y: i32,
    pub kind: ResourceKind,
    pub amount: f32,
}

/// Persistent operator intent, not a worker assignment. Ticks never rewrite orders.
#[table(accessor = work_order, public)]
pub struct WorkOrder {
    #[primary_key]
    pub id: u64,
    pub tile_id: u32,
    pub work: WorkType,
    pub priority: u8,
    pub enabled: bool,
}

#[derive(spacetimedb::SpacetimeType, Clone, Copy, PartialEq, Eq, Debug)]
pub enum Severity {
    Info,
    Warning,
    Critical,
}

/// One row per kind of problem, keyed by `code`; raising an active alert is a no-op.
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

/// Deleting the scheduling row stops the colony; inserting it starts it again.
#[table(accessor = tick_schedule, scheduled(tick))]
pub struct TickSchedule {
    #[primary_key]
    pub scheduled_id: u64,
    pub scheduled_at: spacetimedb::ScheduleAt,
}
