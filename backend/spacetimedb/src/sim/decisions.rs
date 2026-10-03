use super::{Activity, ActivityState, Goal, Needs, Rest, Tile, Tuning, World};

/// Interval-start facility/food availability, optionally filtered by live reachability.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct Availability {
    /// There is an enabled food tile *and* food in store.
    pub(super) food: bool,
    /// There is an enabled food tile (but maybe nothing to eat).
    pub(super) kitchen: bool,
    pub(super) sleep: bool,
    pub(super) recreation: bool,
}

pub(super) fn destination_for<'a>(
    world: &'a World,
    index: usize,
    tuning: &Tuning,
    goal: Goal,
) -> Option<Tile> {
    if world.geometry.is_some() {
        return world.live_destination(index, tuning, goal);
    }
    let colonist = &world.colonists[index];
    if goal == Goal::Work {
        return world
            .best_work_tile(
                colonist.assignment.work,
                colonist.position.x,
                colonist.position.y,
            )
            .cloned();
    }
    if goal == Goal::Haul && !colonist.is_carrying() {
        return world
            .best_supply_tile(
                colonist.assignment.work,
                tuning,
                colonist.position.x,
                colonist.position.y,
            )
            .cloned();
    }
    let kind = goal.tile_kind(colonist.assignment.work, colonist.is_carrying())?;
    world
        .nearest_enabled_tile(kind, colonist.position.x, colonist.position.y)
        .cloned()
}

/// Re-ranks work and pickups without resetting travel to an unchanged target.
pub(super) fn destination_still_serves(
    world: &World,
    index: usize,
    tuning: &Tuning,
    goal: Goal,
) -> bool {
    let colonist = &world.colonists[index];
    if world.geometry.is_some() {
        return destination_for(world, index, tuning, goal).is_some_and(|t| {
            t.x == colonist.movement.target.x
                && t.y == colonist.movement.target.y
                && t.z == colonist.spatial.target_z
        });
    }
    if goal == Goal::Work || (goal == Goal::Haul && !colonist.is_carrying()) {
        return destination_for(world, index, tuning, goal).is_some_and(|tile| {
            tile.x == colonist.movement.target.x && tile.y == colonist.movement.target.y
        });
    }
    let Some(kind) = goal.tile_kind(colonist.assignment.work, colonist.is_carrying()) else {
        return true;
    };
    let Some(tile) = world.tile_at(colonist.movement.target.x, colonist.movement.target.y) else {
        return false;
    };
    if tile.kind != kind {
        return false;
    }
    tile.enabled
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct Decision {
    pub(super) goal: Goal,
    /// Recreation denial on a goal transition, not on every waiting interval.
    pub(super) denied_recreation: bool,
    /// Food denial on a goal transition while a kitchen is available.
    pub(super) denied_food: bool,
}

impl Decision {
    fn for_goal(goal: Goal) -> Self {
        Self {
            goal,
            denied_recreation: false,
            denied_food: false,
        }
    }
}

pub(super) fn decide(
    task: &ActivityState,
    needs: &Needs,
    rest: &Rest,
    tuning: &Tuning,
    availability: &Availability,
    labour: Option<Goal>,
) -> Decision {
    match task.activity {
        Activity::Eating if needs.hunger > tuning.eat_stop && availability.food => {
            return Decision::for_goal(Goal::Eat)
        }
        Activity::Sleeping
            if needs.fatigue > tuning.sleep_stop_fatigue
                && rest.hours < tuning.max_sleep_hours
                && availability.sleep =>
        {
            return Decision::for_goal(Goal::Sleep)
        }
        Activity::Recreating
            if needs.recreation > tuning.recreate_stop && availability.recreation =>
        {
            return Decision::for_goal(Goal::Recreate)
        }
        _ => {}
    }

    let mut denied_recreation = false;
    let mut denied_food = false;

    if needs.hunger >= tuning.crit_hunger {
        if availability.food {
            return Decision::for_goal(Goal::Eat);
        }
        denied_food = !task.goal.is_labour() && availability.kitchen;
    }
    let sleep_cap_reached =
        task.activity == Activity::Sleeping && rest.hours >= tuning.max_sleep_hours;
    if needs.fatigue >= tuning.crit_fatigue && availability.sleep && !sleep_cap_reached {
        return Decision {
            goal: Goal::Sleep,
            denied_recreation,
            denied_food,
        };
    }
    if needs.recreation >= tuning.crit_recreation {
        if availability.recreation {
            return Decision {
                goal: Goal::Recreate,
                denied_recreation,
                denied_food,
            };
        }
        denied_recreation = !task.goal.is_labour();
    }
    let goal = labour.unwrap_or(Goal::Nothing);
    Decision {
        goal,
        denied_recreation: denied_recreation && task.goal != goal,
        denied_food: denied_food && task.goal != goal,
    }
}
