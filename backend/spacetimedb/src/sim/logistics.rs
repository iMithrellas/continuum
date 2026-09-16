use super::{Goal, HaulPolicy, HaulRole, TileKind, Tuning, WorkType, World};

/// Stamp every colonist with the role implied by the colony's hauling policy.
///
/// Derived every tick rather than stored as an independent field, so the policy
/// is the single source of truth and toggling it can never leave a stale role
/// behind. Under `DedicatedHaulers` the pairing is by id within a work type,
/// independent of the order rows were loaded in.
pub(super) fn assign_haul_roles(world: &mut World) {
    match world.haul_policy {
        HaulPolicy::SelfHaul => {
            for colonist in &mut world.colonists {
                colonist.assignment.haul_role = HaulRole::Both;
            }
        }
        HaulPolicy::DedicatedHaulers => {
            for index in 0..world.colonists.len() {
                let work = world.colonists[index].assignment.work;
                let id = world.colonists[index].id;
                let rank = world
                    .colonists
                    .iter()
                    .filter(|other| other.assignment.work == work && other.id < id)
                    .count();
                world.colonists[index].assignment.haul_role = if work == WorkType::None {
                    HaulRole::Both
                } else if rank % 2 == 0 {
                    HaulRole::Producer
                } else {
                    HaulRole::Hauler
                };
            }
        }
    }
}

/// What this colonist would do on the job right now, if no need outranks it.
///
/// `None` means "there is no job to do": either the colonist is untrained, the
/// facility is switched off, or they are a dedicated hauler with nothing to
/// carry.
pub(super) fn labour_goal(world: &World, index: usize, tuning: &Tuning) -> Option<Goal> {
    let colonist = &world.colonists[index];
    let storage_open = world.has_enabled(TileKind::Storage);

    // Hands full: finish the delivery before anything else on the job.
    if colonist.is_carrying() {
        return storage_open.then_some(Goal::Haul);
    }
    colonist.assignment.work.definition()?;

    let pile_ready = storage_open
        && world
            .best_supply_tile(
                colonist.assignment.work,
                tuning,
                colonist.position.x,
                colonist.position.y,
            )
            .is_some();

    if colonist.assignment.haul_role.hauls() && pile_ready {
        return Some(Goal::Haul);
    }
    if colonist.assignment.haul_role.produces()
        && world
            .best_work_tile(
                colonist.assignment.work,
                colonist.position.x,
                colonist.position.y,
            )
            .is_some()
    {
        return Some(Goal::Work);
    }
    None
}

/// Work the facility the colonist is standing on.
///
/// Output lands as a pile *on that tile*, not in the colony's stores. Nothing is
/// usable until somebody hauls it, which is the whole point of the logistics
/// layer.
pub(super) fn step_work(world: &mut World, colonist_index: usize, tuning: &Tuning, dt_hours: f32) {
    if !world.colonists[colonist_index]
        .assignment
        .haul_role
        .produces()
        || world.colonists[colonist_index].is_carrying()
    {
        return;
    }
    let Some(definition) = world.colonists[colonist_index].assignment.work.definition() else {
        return;
    };
    let (x, y) = (
        world.colonists[colonist_index].position.x,
        world.colonists[colonist_index].position.y,
    );
    let Some(tile) = world.tile_at(x, y).cloned() else {
        return;
    };
    if world
        .active_work_order(&tile, world.colonists[colonist_index].assignment.work)
        .is_none()
    {
        return;
    }
    let productivity = world.colonists[colonist_index].wellbeing.productivity / 100.0;
    let produced = tuning.output_per_hour(definition.output) * productivity * dt_hours;
    world.add_to_stack(&tile, definition.output, produced);
}

/// Pick up or deposit up to one stack per decision interval.
pub(super) fn step_haul(world: &mut World, colonist_index: usize, tuning: &Tuning) {
    let (x, y) = (
        world.colonists[colonist_index].position.x,
        world.colonists[colonist_index].position.y,
    );
    let Some(tile) = world.tile_at(x, y).cloned() else {
        return;
    };
    if world.colonists[colonist_index].is_carrying() {
        if tile.kind != TileKind::Storage || !tile.enabled {
            return;
        }
        let colonist = &mut world.colonists[colonist_index];
        let (kind, amount) = (colonist.cargo.kind, colonist.cargo.amount);
        colonist.cargo.amount = 0.0;
        world.resources.add(kind, amount);
        return;
    }

    let Some(definition) = world.colonists[colonist_index].assignment.work.definition() else {
        return;
    };
    if tile.kind != definition.facility
        || !world.colonists[colonist_index].assignment.haul_role.hauls()
        || !world.has_enabled(TileKind::Storage)
        || !world.supply_ready(
            &tile,
            world.colonists[colonist_index].assignment.work,
            tuning,
        )
    {
        return;
    }
    let taken = world.take_from_stack(
        tile.id,
        definition.output,
        tuning.stack_size(definition.output),
    );
    if taken > 0.0 {
        let colonist = &mut world.colonists[colonist_index];
        colonist.cargo.kind = definition.output;
        colonist.cargo.amount = taken;
    }
}
