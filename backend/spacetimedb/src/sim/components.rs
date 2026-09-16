//! Internal simulation state, independent of database rows and ECS storage.

use super::{Activity, Goal, HaulRole, ResourceKind, WorkType};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Position {
    pub x: i32,
    pub y: i32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Movement {
    pub target: Position,
    /// Fractional progress towards the next tile step, in [0, 1).
    pub progress: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Needs {
    pub hunger: f32,
    pub fatigue: f32,
    pub recreation: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Wellbeing {
    pub mood: f32,
    pub productivity: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Rest {
    /// In-game hours spent in the current sleep.
    pub hours: f32,
    pub last_quality: f32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WorkAssignment {
    pub work: WorkType,
    /// Derived from the colony hauling policy; not an independent player intent.
    pub haul_role: HaulRole,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ActivityState {
    pub goal: Goal,
    pub activity: Activity,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Cargo {
    /// Retained when empty, so loading/saving preserves the existing wire state.
    pub kind: ResourceKind,
    pub amount: f32,
}

impl Cargo {
    pub fn has_goods(&self) -> bool {
        self.amount > 0.0
    }
}

/// An aggregate of components, not a base class for every future actor.
#[derive(Clone, Debug, PartialEq)]
pub struct Colonist {
    /// Durable identity. Collection indices are only transient storage addresses.
    pub id: u64,
    pub name: String,
    pub position: Position,
    pub movement: Movement,
    pub needs: Needs,
    pub wellbeing: Wellbeing,
    pub rest: Rest,
    pub assignment: WorkAssignment,
    pub task: ActivityState,
    pub cargo: Cargo,
}

impl Colonist {
    pub fn is_carrying(&self) -> bool {
        self.cargo.has_goods()
    }

    pub fn new(id: u64, name: &str, x: i32, y: i32) -> Self {
        let position = Position { x, y };
        Self {
            id,
            name: name.to_string(),
            position,
            movement: Movement {
                target: position,
                progress: 0.0,
            },
            needs: Needs {
                hunger: 10.0,
                fatigue: 10.0,
                recreation: 10.0,
            },
            wellbeing: Wellbeing {
                mood: 80.0,
                productivity: 80.0,
            },
            rest: Rest {
                hours: 0.0,
                last_quality: 1.0,
            },
            assignment: WorkAssignment {
                work: WorkType::None,
                haul_role: HaulRole::Both,
            },
            task: ActivityState {
                goal: Goal::Nothing,
                activity: Activity::Idle,
            },
            cargo: Cargo {
                kind: ResourceKind::Food,
                amount: 0.0,
            },
        }
    }
}
