use super::{Tile, GRID_H, GRID_W};
use spacetimedb::SpacetimeType;

#[derive(SpacetimeType, Clone, Copy, PartialEq, Eq, Debug)]
pub enum TileKind {
    Empty,
    Sleep,
    Forest,
    Storage,
    Farm,
    Mine,
    Dining,
    Recreation,
}

pub const FACILITY_BUILD_WOOD_COST: f32 = 20.0;

impl TileKind {
    pub fn is_buildable(self) -> bool {
        matches!(
            self,
            TileKind::Dining | TileKind::Sleep | TileKind::Recreation
        )
    }
}

pub fn validate_facility_build(
    tile: &Tile,
    kind: TileKind,
    stored_wood: f32,
) -> Result<(), String> {
    if !kind.is_buildable() {
        return Err("only dining, sleep, or recreation facilities can be built".into());
    }
    if tile.x < 0 || tile.x >= GRID_W || tile.y < 0 || tile.y >= GRID_H {
        return Err("facility must be built inside the colony grid".into());
    }
    if tile.kind != TileKind::Empty {
        return Err("facility can only be built on an empty tile".into());
    }
    if !stored_wood.is_finite() || stored_wood < FACILITY_BUILD_WOOD_COST {
        return Err(format!(
            "building requires {:.0} stored wood; colony has {:.1}",
            FACILITY_BUILD_WOOD_COST, stored_wood
        ));
    }
    Ok(())
}

#[derive(SpacetimeType, Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Activity {
    Idle,
    Travelling,
    Working,
    /// Picking a stack up at a production site or dropping it into storage.
    Hauling,
    Eating,
    Sleeping,
    Recreating,
}

/// What a colonist is trained to do. Every work type produces exactly one
/// resource; moving that resource is a *role* (see [`HaulRole`]), not a work type.
#[derive(SpacetimeType, Clone, Copy, PartialEq, Eq, Debug)]
pub enum WorkType {
    None,
    Logging,
    Mining,
    Hunting,
    Farming,
}

#[derive(SpacetimeType, Clone, Copy, PartialEq, Eq, Debug)]
pub enum ResourceKind {
    Food,
    Wood,
    Stone,
    Meat,
}

pub const RESOURCE_KINDS: [ResourceKind; 4] = [
    ResourceKind::Food,
    ResourceKind::Wood,
    ResourceKind::Stone,
    ResourceKind::Meat,
];

impl ResourceKind {
    /// Stable ordinal, used to derive item stack ids.
    pub fn index(self) -> u64 {
        match self {
            ResourceKind::Food => 0,
            ResourceKind::Wood => 1,
            ResourceKind::Stone => 2,
            ResourceKind::Meat => 3,
        }
    }
}

/// Who carries produced goods to storage.
#[derive(SpacetimeType, Clone, Copy, PartialEq, Eq, Debug)]
pub enum HaulPolicy {
    /// Everybody works their facility and delivers their own output.
    SelfHaul,
    /// Within each work type the first colonist only produces and the second
    /// only hauls that work type's output to storage.
    DedicatedHaulers,
}

/// Colony-wide meal policy. Rationed meals use less food per eating interval,
/// but remove hunger more slowly, so the existing hunger-to-mood consequences
/// remain the only mood penalty.
#[derive(SpacetimeType, Clone, Copy, PartialEq, Eq, Debug)]
pub enum MealPolicy {
    Normal,
    Rationed,
}

impl MealPolicy {
    pub fn food_cost_multiplier(self) -> f32 {
        match self {
            MealPolicy::Normal => 1.0,
            MealPolicy::Rationed => 0.5,
        }
    }

    pub fn hunger_recovery_multiplier(self) -> f32 {
        match self {
            MealPolicy::Normal => 1.0,
            MealPolicy::Rationed => 0.65,
        }
    }

    /// Food units spent per hunger point recovered, relative to normal meals.
    /// This keeps rationed meals at 50% of normal food cost despite recovering
    /// only 65% as much hunger during the same eating interval.
    pub fn food_cost_per_hunger_multiplier(self) -> f32 {
        self.food_cost_multiplier() / self.hunger_recovery_multiplier()
    }
}

/// A colonist's part in the production loop, derived from [`HaulPolicy`] every
/// tick so it can never drift out of sync with the policy.
#[derive(SpacetimeType, Clone, Copy, PartialEq, Eq, Debug)]
pub enum HaulRole {
    /// Produces and delivers.
    Both,
    /// Produces only; leaves output on the ground.
    Producer,
    /// Delivers only; never works the facility.
    Hauler,
}

impl HaulRole {
    pub fn produces(self) -> bool {
        matches!(self, HaulRole::Both | HaulRole::Producer)
    }

    pub fn hauls(self) -> bool {
        matches!(self, HaulRole::Both | HaulRole::Hauler)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct WorkDefinition {
    pub facility: TileKind,
    pub output: ResourceKind,
}

impl WorkType {
    pub fn definition(self) -> Option<WorkDefinition> {
        match self {
            WorkType::None => None,
            WorkType::Logging => Some(WorkDefinition {
                facility: TileKind::Forest,
                output: ResourceKind::Wood,
            }),
            WorkType::Mining => Some(WorkDefinition {
                facility: TileKind::Mine,
                output: ResourceKind::Stone,
            }),
            WorkType::Hunting => Some(WorkDefinition {
                facility: TileKind::Forest,
                output: ResourceKind::Meat,
            }),
            WorkType::Farming => Some(WorkDefinition {
                facility: TileKind::Farm,
                output: ResourceKind::Food,
            }),
        }
    }
}

/// What a colonist is currently trying to achieve. `Activity` is the observable
/// surface (used by the UI); `Goal` is the intent that survives travelling.
#[derive(SpacetimeType, Clone, Copy, PartialEq, Eq, Debug)]
pub enum Goal {
    Nothing,
    Eat,
    Sleep,
    Recreate,
    Work,
    /// Move produced goods to storage. The destination flips between the
    /// production site and the storage zone depending on whether the colonist is
    /// already carrying something.
    Haul,
}

impl Goal {
    /// The kind of tile this goal needs to be standing on.
    ///
    /// `carrying` only matters for [`Goal::Haul`], which walks to a production
    /// site with empty hands and to storage with full ones.
    pub fn tile_kind(self, work: WorkType, carrying: bool) -> Option<TileKind> {
        match self {
            Goal::Nothing => None,
            Goal::Eat => Some(TileKind::Dining),
            Goal::Sleep => Some(TileKind::Sleep),
            Goal::Recreate => Some(TileKind::Recreation),
            Goal::Work => work.definition().map(|definition| definition.facility),
            Goal::Haul => {
                if carrying {
                    Some(TileKind::Storage)
                } else {
                    work.definition().map(|definition| definition.facility)
                }
            }
        }
    }

    pub fn activity(self) -> Activity {
        match self {
            Goal::Nothing => Activity::Idle,
            Goal::Eat => Activity::Eating,
            Goal::Sleep => Activity::Sleeping,
            Goal::Recreate => Activity::Recreating,
            Goal::Work => Activity::Working,
            Goal::Haul => Activity::Hauling,
        }
    }

    /// Whether this goal counts as being on the job. Used so a colonist who
    /// fell back to labour because a need could not be met is not reported as
    /// denied over and over.
    pub fn is_labour(self) -> bool {
        matches!(self, Goal::Work | Goal::Haul)
    }
}
