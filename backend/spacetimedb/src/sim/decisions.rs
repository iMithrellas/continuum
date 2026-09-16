use super::{Activity, ActivityState, Goal, Needs, Rest, Tile, Tuning, World};

/// What the colony can currently offer. Computed once per tick so that every
/// colonist sees the same world, independent of iteration order.
pub(super) struct Availability {
    /// There is an enabled food tile *and* food in store.
    pub(super) food: bool,
    /// There is an enabled food tile (but maybe nothing to eat).
    pub(super) kitchen: bool,
    pub(super) sleep: bool,
    pub(super) recreation: bool,
}

/// Where `goal` wants this colonist to walk.
pub(super) fn destination_for<'a>(
    world: &'a World,
    index: usize,
    tuning: &Tuning,
    goal: Goal,
) -> Option<&'a Tile> {
    let colonist = &world.colonists[index];
    if goal == Goal::Work {
        return world.best_work_tile(
            colonist.assignment.work,
            colonist.position.x,
            colonist.position.y,
        );
    }
    if goal == Goal::Haul && !colonist.is_carrying() {
        // Not just any production site: one that actually has a stack waiting.
        return world.best_supply_tile(
            colonist.assignment.work,
            tuning,
            colonist.position.x,
            colonist.position.y,
        );
    }
    let kind = goal.tile_kind(colonist.assignment.work, colonist.is_carrying())?;
    world.nearest_enabled_tile(kind, colonist.position.x, colonist.position.y)
}

/// Whether the colonist's current target is still the right place for `goal`.
///
/// This is what makes colonists react to the world changing under them: a zone
/// switched off, or — new with hauling — a pile that somebody else got to first.
pub(super) fn destination_still_serves(
    world: &World,
    index: usize,
    tuning: &Tuning,
    goal: Goal,
) -> bool {
    let colonist = &world.colonists[index];
    // Re-rank production and empty pickups every bounded interval, without
    // resetting fractional travel when the winning destination is unchanged.
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

pub(super) struct Decision {
    pub(super) goal: Goal,
    /// The colonist needed recreation and the colony could not provide it.
    pub(super) denied_recreation: bool,
    /// The colonist needed food and the colony could not provide it.
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
    // Some activities are "locked in" until they finish, so colonists do not
    // thrash between goals every tick.
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
        // Wanted food, could not get it. Reported once per goal transition (not
        // once per tick) by only firing while the colonist is not already
        // falling back to work.
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
        // Waiting haulers can remain idle for hours. Report the fallback once,
        // not a fresh denial on every interval with nothing available to haul.
        denied_recreation: denied_recreation && task.goal != goal,
        denied_food: denied_food && task.goal != goal,
    }
}
