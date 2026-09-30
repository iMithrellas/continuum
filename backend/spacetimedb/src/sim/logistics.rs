use super::{Goal, HaulPolicy, HaulRole, TileKind, Tuning, WorkType, World};

/// Derives roles from the current policy, pairing dedicated haulers by durable
/// colonist ID within each work type.
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

/// Eligible labour before needs take precedence; `None` means no available job.
pub(super) fn labour_goal(world: &World, index: usize, tuning: &Tuning) -> Option<Goal> {
    let colonist = &world.colonists[index];
    if world.geometry.is_some() {
        if colonist.is_carrying() {
            return world
                .live_destination(index, tuning, Goal::Haul)
                .map(|_| Goal::Haul);
        }
        if colonist.assignment.haul_role.hauls()
            && world.live_destination(index, tuning, Goal::Haul).is_some()
        {
            let storage = world
                .geometry
                .as_ref()
                .unwrap()
                .reachable(world.actor_cell(index), colonist.spatial.body);
            if world.tiles.iter().any(|t| {
                t.kind == TileKind::Storage && t.enabled && storage.contains_key(&t.base())
            }) {
                return Some(Goal::Haul);
            }
        }
        return (colonist.assignment.haul_role.produces()
            && world.live_destination(index, tuning, Goal::Work).is_some())
        .then_some(Goal::Work);
    }
    let storage_open = world.has_enabled(TileKind::Storage);

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

/// Produces ground goods at the current facility; hauling makes them usable.
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
    if world.geometry.is_some()
        && world.colonists[colonist_index].assignment.work == WorkType::Mining
    {
        world.step_mining(colonist_index, tuning, dt_hours);
        return;
    }
    let (x, y) = (
        world.colonists[colonist_index].position.x,
        world.colonists[colonist_index].position.y,
    );
    let Some(tile) = world
        .tile_at_elevation(x, y, world.colonists[colonist_index].spatial.z)
        .cloned()
    else {
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
    let Some(tile) = world
        .tile_at_elevation(x, y, world.colonists[colonist_index].spatial.z)
        .cloned()
    else {
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
    if world.geometry.is_some()
        && world.colonists[colonist_index].assignment.work == WorkType::Mining
    {
        if !world.colonists[colonist_index].assignment.haul_role.hauls() {
            return;
        }
        let taken = world.take_from_stack(
            tile.id,
            definition.output,
            tuning.stack_size(definition.output),
        );
        if taken > 0.0 {
            let actor = &mut world.colonists[colonist_index];
            actor.cargo.kind = definition.output;
            actor.cargo.amount = taken;
        }
        return;
    }
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
