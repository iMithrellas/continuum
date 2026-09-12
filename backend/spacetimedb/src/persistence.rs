//! Loading and saving simulation state. Only explicit seed/reset installs defaults.

use crate::schema::*;
use crate::sim::{self, HaulPolicy, MealPolicy, Resources, World};
use spacetimedb::{ReducerContext, Table};

/// Wipe colony state and recreate it from the default layout.
pub(crate) fn seed_colony(ctx: &ReducerContext, time_scale: f64) {
    for order in ctx.db.work_order().iter() {
        ctx.db.work_order().id().delete(order.id);
    }
    for stack in ctx.db.item_stack().iter() {
        ctx.db.item_stack().id().delete(stack.id);
    }
    for tile in ctx.db.tile().iter() {
        ctx.db.tile().id().delete(tile.id);
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

    let generation = ctx
        .db
        .config()
        .id()
        .find(0)
        .map(|config| config.generation + 1)
        .unwrap_or(1);
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

pub(crate) fn load_world(ctx: &ReducerContext) -> World {
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

    let mut colonists: Vec<sim::Colonist> = ctx
        .db
        .colonist()
        .iter()
        .map(|colonist| sim::Colonist {
            id: colonist.id,
            name: colonist.name,
            x: colonist.x,
            y: colonist.y,
            move_progress: colonist.move_progress,
            target_x: colonist.target_x,
            target_y: colonist.target_y,
            activity: colonist.activity,
            work: colonist.work,
            haul_role: colonist.haul_role,
            carried_kind: colonist.carried_kind,
            carried_amount: colonist.carried_amount,
            goal: colonist.goal,
            hunger: colonist.hunger,
            fatigue: colonist.fatigue,
            recreation: colonist.recreation,
            mood: colonist.mood,
            productivity: colonist.productivity,
            sleep_hours: colonist.sleep_hours,
            last_sleep_quality: colonist.last_sleep_quality,
        })
        .collect();
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

fn colonist_row(colonist: &sim::Colonist) -> Colonist {
    Colonist {
        id: colonist.id,
        name: colonist.name.clone(),
        x: colonist.x,
        y: colonist.y,
        move_progress: colonist.move_progress,
        target_x: colonist.target_x,
        target_y: colonist.target_y,
        activity: colonist.activity,
        work: colonist.work,
        haul_role: colonist.haul_role,
        carried_kind: colonist.carried_kind,
        carried_amount: colonist.carried_amount,
        goal: colonist.goal,
        hunger: colonist.hunger,
        fatigue: colonist.fatigue,
        recreation: colonist.recreation,
        mood: colonist.mood,
        productivity: colonist.productivity,
        sleep_hours: colonist.sleep_hours,
        last_sleep_quality: colonist.last_sleep_quality,
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
