//! Loading and saving simulation state. Only explicit seed/reset installs defaults.

use crate::schema::*;
use crate::sim::{self, HaulPolicy, MealPolicy, Resources, World};
use spacetimedb::{ReducerContext, Table};

const DEFAULT_WORLD_SEED: u64 = 0x6c6f_6e67_7365_6564;

/// Wipe colony state and recreate it from the default layout.
pub(crate) fn seed_colony(ctx: &ReducerContext, time_scale: f64) {
    let generation = ctx
        .db
        .config()
        .id()
        .find(0)
        .map(|config| config.generation + 1)
        .unwrap_or(1);
    let seed = DEFAULT_WORLD_SEED.wrapping_add(generation as u64);
    for order in ctx.db.work_order().iter() {
        ctx.db.work_order().id().delete(order.id);
    }
    for stack in ctx.db.item_stack().iter() {
        ctx.db.item_stack().id().delete(stack.id);
    }
    for tile in ctx.db.tile().iter() {
        ctx.db.tile().id().delete(tile.id);
    }
    for terrain in ctx.db.terrain().iter() {
        ctx.db.terrain().tile_id().delete(terrain.tile_id);
    }
    for colonist in ctx.db.colonist().iter() {
        ctx.db.colonist().id().delete(colonist.id);
    }
    for alert in ctx.db.alert().iter() {
        ctx.db.alert().id().delete(alert.id);
    }
    for event in ctx.db.event_log().iter() {
        ctx.db.event_log().id().delete(event.id);
    }

    let world = sim::new_world();
    for tile in &world.tiles {
        ctx.db.tile().insert(Tile {
            id: tile.id,
            x: tile.x,
            y: tile.y,
            kind: tile.kind,
            enabled: tile.enabled,
        });
    }
    for order in &world.work_orders {
        ctx.db.work_order().insert(WorkOrder {
            id: order.id,
            tile_id: order.tile_id,
            work: order.work,
            priority: order.priority,
            enabled: order.enabled,
        });
    }
    for colonist in &world.colonists {
        ctx.db.colonist().insert(colonist_row(colonist));
    }

    upsert_world_seed(ctx, seed);
    for tile in &world.tiles {
        let fields = sim::terrain::sample(seed, tile.x, tile.y);
        ctx.db.terrain().insert(Terrain {
            tile_id: tile.id,
            soil_fertility: fields.soil_fertility,
            forest_density: fields.forest_density,
            moisture: fields.moisture,
        });
    }
    upsert_config(
        ctx,
        Config {
            id: 0,
            time_scale,
            game_seconds: world.game_seconds,
            generation,
            haul_policy: world.haul_policy,
            meal_policy: MealPolicy::Normal,
        },
    );
    upsert_colony(ctx, colony_row(&world));
    // Reset explicitly owns policy state: a reset starts with cooldown disabled.
    let control = SpeedControl {
        id: 0,
        cooldown_seconds: 0,
        last_changed_at: None,
    };
    if ctx.db.speed_control().id().find(0).is_some() {
        ctx.db.speed_control().id().update(control);
    } else {
        ctx.db.speed_control().insert(control);
    }
}

pub(crate) fn upsert_config(ctx: &ReducerContext, row: Config) {
    if ctx.db.config().id().find(0).is_some() {
        ctx.db.config().id().update(row);
    } else {
        ctx.db.config().insert(row);
    }
}

fn upsert_colony(ctx: &ReducerContext, row: Colony) {
    if ctx.db.colony().id().find(0).is_some() {
        ctx.db.colony().id().update(row);
    } else {
        ctx.db.colony().insert(row);
    }
}

fn upsert_world_seed(ctx: &ReducerContext, seed: u64) {
    let row = WorldSeed { id: 0, seed };
    if ctx.db.world_seed().id().find(0).is_some() {
        ctx.db.world_seed().id().update(row);
    } else {
        ctx.db.world_seed().insert(row);
    }
}

pub(crate) fn load_world(ctx: &ReducerContext) -> World {
    ensure_terrain(ctx);
    let mut tiles: Vec<sim::Tile> = ctx
        .db
        .tile()
        .iter()
        .map(|tile| sim::Tile {
            id: tile.id,
            x: tile.x,
            y: tile.y,
            kind: tile.kind,
            enabled: tile.enabled,
        })
        .collect();
    tiles.sort_by_key(|tile| tile.id);

    // An additive update may leave this table empty. Never backfill on load:
    // emptiness also represents the operator intentionally deleting all orders.
    let mut work_orders: Vec<sim::WorkOrder> = ctx
        .db
        .work_order()
        .iter()
        .map(|order| sim::WorkOrder {
            id: order.id,
            tile_id: order.tile_id,
            work: order.work,
            priority: order.priority,
            enabled: order.enabled,
        })
        .collect();
    work_orders.sort_by_key(|order| order.id);

    let mut colonists: Vec<sim::Colonist> = ctx.db.colonist().iter().map(colonist_state).collect();
    colonists.sort_by_key(|colonist| colonist.id);

    let mut stacks: Vec<sim::ItemStack> = ctx
        .db
        .item_stack()
        .iter()
        .map(|stack| sim::ItemStack {
            id: stack.id,
            tile_id: stack.tile_id,
            x: stack.x,
            y: stack.y,
            kind: stack.kind,
            amount: stack.amount,
        })
        .collect();
    stacks.sort_by_key(|stack| stack.id);

    let colony = ctx.db.colony().id().find(0);
    let config = ctx.db.config().id().find(0);

    World {
        tiles,
        work_orders,
        colonists,
        stacks,
        haul_policy: config
            .as_ref()
            .map(|config| config.haul_policy)
            .unwrap_or(HaulPolicy::SelfHaul),
        meal_policy: config
            .as_ref()
            .map(|config| config.meal_policy)
            .unwrap_or(MealPolicy::Normal),
        resources: Resources {
            food: colony.as_ref().map(|colony| colony.food).unwrap_or(0.0),
            wood: colony.as_ref().map(|colony| colony.wood).unwrap_or(0.0),
            stone: colony.as_ref().map(|colony| colony.stone).unwrap_or(0.0),
            meat: colony.as_ref().map(|colony| colony.meat).unwrap_or(0.0),
        },
        game_seconds: config
            .as_ref()
            .map(|config| config.game_seconds)
            .unwrap_or(0.0),
        mood_ema: colony
            .as_ref()
            .map(|colony| colony.smoothed_mood)
            .unwrap_or(80.0),
        productivity_ema: colony
            .as_ref()
            .map(|colony| colony.smoothed_productivity)
            .unwrap_or(90.0),
    }
}

/// Additive migrations do not rewrite existing terrain or any other colony rows.
/// A missing seed is derived from the persisted generation once, then retained.
fn ensure_terrain(ctx: &ReducerContext) -> u64 {
    let seed = ctx
        .db
        .world_seed()
        .id()
        .find(0)
        .map(|row| row.seed)
        .unwrap_or_else(|| {
            let generation = ctx
                .db
                .config()
                .id()
                .find(0)
                .map(|row| row.generation)
                .unwrap_or(0);
            let seed = DEFAULT_WORLD_SEED.wrapping_add(generation as u64);
            upsert_world_seed(ctx, seed);
            seed
        });
    for tile in ctx.db.tile().iter() {
        if ctx.db.terrain().tile_id().find(tile.id).is_none() {
            let fields = sim::terrain::sample(seed, tile.x, tile.y);
            ctx.db.terrain().insert(Terrain {
                tile_id: tile.id,
                soil_fertility: fields.soil_fertility,
                forest_density: fields.forest_density,
                moisture: fields.moisture,
            });
        }
    }
    seed
}

fn colonist_state(row: Colonist) -> sim::Colonist {
    sim::Colonist {
        id: row.id,
        name: row.name,
        position: sim::Position { x: row.x, y: row.y },
        movement: sim::Movement {
            target: sim::Position {
                x: row.target_x,
                y: row.target_y,
            },
            progress: row.move_progress,
        },
        task: sim::ActivityState {
            activity: row.activity,
            goal: row.goal,
        },
        assignment: sim::WorkAssignment {
            work: row.work,
            haul_role: row.haul_role,
        },
        cargo: sim::Cargo {
            kind: row.carried_kind,
            amount: row.carried_amount,
        },
        needs: sim::Needs {
            hunger: row.hunger,
            fatigue: row.fatigue,
            recreation: row.recreation,
        },
        wellbeing: sim::Wellbeing {
            mood: row.mood,
            productivity: row.productivity,
        },
        rest: sim::Rest {
            hours: row.sleep_hours,
            last_quality: row.last_sleep_quality,
        },
    }
}

fn colonist_row(colonist: &sim::Colonist) -> Colonist {
    Colonist {
        id: colonist.id,
        name: colonist.name.clone(),
        x: colonist.position.x,
        y: colonist.position.y,
        move_progress: colonist.movement.progress,
        target_x: colonist.movement.target.x,
        target_y: colonist.movement.target.y,
        activity: colonist.task.activity,
        work: colonist.assignment.work,
        haul_role: colonist.assignment.haul_role,
        carried_kind: colonist.cargo.kind,
        carried_amount: colonist.cargo.amount,
        goal: colonist.task.goal,
        hunger: colonist.needs.hunger,
        fatigue: colonist.needs.fatigue,
        recreation: colonist.needs.recreation,
        mood: colonist.wellbeing.mood,
        productivity: colonist.wellbeing.productivity,
        sleep_hours: colonist.rest.hours,
        last_sleep_quality: colonist.rest.last_quality,
    }
}

fn colony_row(world: &World) -> Colony {
    Colony {
        id: 0,
        food: world.resources.food,
        wood: world.resources.wood,
        stone: world.resources.stone,
        meat: world.resources.meat,
        avg_mood: world.avg_mood(),
        avg_productivity: world.avg_productivity(),
        smoothed_mood: world.mood_ema,
        smoothed_productivity: world.productivity_ema,
        population: world.colonists.len() as u32,
    }
}

/// Save tick output, leaving tile settings and work-order intents unchanged.
pub(crate) fn save_world(ctx: &ReducerContext, world: &World, config: Config) {
    for colonist in &world.colonists {
        ctx.db.colonist().id().update(colonist_row(colonist));
    }
    for stack in ctx.db.item_stack().iter() {
        if world
            .stacks
            .binary_search_by_key(&stack.id, |stack| stack.id)
            .is_err()
        {
            ctx.db.item_stack().id().delete(stack.id);
        }
    }
    for stack in &world.stacks {
        let row = ItemStack {
            id: stack.id,
            tile_id: stack.tile_id,
            x: stack.x,
            y: stack.y,
            kind: stack.kind,
            amount: stack.amount,
        };
        if ctx.db.item_stack().id().find(stack.id).is_some() {
            ctx.db.item_stack().id().update(row);
        } else {
            ctx.db.item_stack().insert(row);
        }
    }
    upsert_colony(ctx, colony_row(world));
    upsert_config(
        ctx,
        Config {
            id: 0,
            game_seconds: world.game_seconds,
            ..config
        },
    );
}

#[cfg(test)]
mod tests;
