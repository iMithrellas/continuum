//! Pure simulation core for Continuum.
//!
//! This module deliberately contains **no** SpacetimeDB glue: no `ReducerContext`,
//! no table handles, no scheduling. It owns a plain-old-data `World` and advances
//! it by a number of in-game seconds. `lib.rs` is responsible for loading rows into
//! a `World`, calling [`step`], and writing the result back.
//!
//! The only SpacetimeDB-flavoured thing here is `#[derive(SpacetimeType)]` on the
//! small enums, so that the same enum values can be stored in tables and shown to
//! clients without a translation layer. That derive is inert at runtime and the
//! whole module is testable with a plain `cargo test`.

use spacetimedb::SpacetimeType;

pub const GRID_W: i32 = 16;
pub const GRID_H: i32 = 16;

/// In-game seconds in one in-game day.
pub const SECONDS_PER_DAY: f64 = 86_400.0;

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

#[derive(SpacetimeType, Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Activity {
    Idle,
    Travelling,
    Working,
    Eating,
    Sleeping,
    Recreating,
}

#[derive(SpacetimeType, Clone, Copy, PartialEq, Eq, Debug)]
pub enum WorkType {
    None,
    Logging,
    Mining,
    Hunting,
    Hauling,
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
}

impl Goal {
    pub fn tile_kind(self) -> Option<TileKind> {
        match self {
            Goal::Nothing => None,
            Goal::Eat => Some(TileKind::Dining),
            Goal::Sleep => Some(TileKind::Sleep),
            Goal::Recreate => Some(TileKind::Recreation),
            Goal::Work => Some(TileKind::Farm),
        }
    }

    pub fn activity(self) -> Activity {
        match self {
            Goal::Nothing => Activity::Idle,
            Goal::Eat => Activity::Eating,
            Goal::Sleep => Activity::Sleeping,
            Goal::Recreate => Activity::Recreating,
            Goal::Work => Activity::Working,
        }
    }
}

/// All simulation constants in one place. Rates are expressed per **in-game hour**.
#[derive(Clone, Copy, Debug)]
pub struct Tuning {
    pub hunger_per_hour: f32,
    pub fatigue_per_hour: f32,
    /// Extra fatigue accrued on top of `fatigue_per_hour` while working.
    pub work_fatigue_per_hour: f32,
    pub recreation_per_hour: f32,

    pub crit_hunger: f32,
    pub crit_fatigue: f32,
    pub crit_recreation: f32,

    pub eat_rate_per_hour: f32,
    pub eat_stop: f32,
    /// Food units consumed per point of hunger removed.
    pub food_per_hunger: f32,

    pub sleep_recovery_per_hour: f32,
    /// Sleep quality at mood 0. Quality scales linearly to 1.0 at mood 100.
    pub sleep_quality_floor: f32,
    pub sleep_stop_fatigue: f32,
    /// Hard cap on one sleep. This is what turns "bad sleep quality" into
    /// "permanently accumulating fatigue".
    pub max_sleep_hours: f32,
    /// Waking with more fatigue than this counts as "poorly rested".
    pub poorly_rested_fatigue: f32,
    /// Going to sleep with less mood than this is worth reporting.
    pub low_mood_sleep_threshold: f32,

    pub recreate_rate_per_hour: f32,
    pub recreate_stop: f32,

    /// Food produced per in-game hour by a colonist at 100% productivity.
    pub work_food_per_hour: f32,

    pub mood_base: f32,
    pub mood_w_hunger: f32,
    pub mood_w_fatigue: f32,
    pub mood_w_recreation: f32,
    /// How fast mood chases its target, in mood points per in-game hour.
    pub mood_rate_per_hour: f32,

    pub prod_base: f32,
    pub prod_w_fatigue: f32,
    pub prod_w_mood_deficit: f32,

    pub move_tiles_per_hour: f32,

    /// Time constant, in in-game seconds, for the smoothed colony-level mood and
    /// productivity figures. Instantaneous averages swing wildly (everyone is
    /// asleep at the same time), so alerts are driven by the smoothed values.
    pub stat_ema_tau_seconds: f32,
}

impl Default for Tuning {
    fn default() -> Self {
        Self {
            hunger_per_hour: 5.0,
            fatigue_per_hour: 4.0,
            work_fatigue_per_hour: 1.5,
            recreation_per_hour: 3.0,

            crit_hunger: 60.0,
            crit_fatigue: 60.0,
            crit_recreation: 60.0,

            eat_rate_per_hour: 200.0,
            eat_stop: 5.0,
            food_per_hunger: 0.16,

            sleep_recovery_per_hour: 16.0,
            sleep_quality_floor: 0.10,
            sleep_stop_fatigue: 10.0,
            max_sleep_hours: 6.0,
            poorly_rested_fatigue: 20.0,
            low_mood_sleep_threshold: 35.0,

            recreate_rate_per_hour: 60.0,
            recreate_stop: 5.0,

            work_food_per_hour: 2.2,

            mood_base: 110.0,
            mood_w_hunger: 0.20,
            mood_w_fatigue: 0.15,
            mood_w_recreation: 0.70,
            mood_rate_per_hour: 15.0,

            prod_base: 114.0,
            prod_w_fatigue: 0.35,
            prod_w_mood_deficit: 0.45,

            move_tiles_per_hour: 40.0,

            stat_ema_tau_seconds: SECONDS_PER_DAY as f32,
        }
    }
}

#[derive(Clone, Debug)]
pub struct Tile {
    pub id: u32,
    pub x: i32,
    pub y: i32,
    pub kind: TileKind,
    pub enabled: bool,
}

#[derive(Clone, Debug)]
pub struct Colonist {
    pub id: u64,
    pub name: String,
    pub x: i32,
    pub y: i32,
    /// Fractional progress towards the next tile step, in [0, 1).
    pub move_progress: f32,
    pub target_x: i32,
    pub target_y: i32,
    pub activity: Activity,
    pub work: WorkType,
    pub goal: Goal,

    pub hunger: f32,
    pub fatigue: f32,
    pub recreation: f32,
    pub mood: f32,
    pub productivity: f32,

    /// In-game hours spent in the current sleep.
    pub sleep_hours: f32,
    pub last_sleep_quality: f32,
}

impl Colonist {
    pub fn new(id: u64, name: &str, x: i32, y: i32) -> Self {
        Self {
            id,
            name: name.to_string(),
            x,
            y,
            move_progress: 0.0,
            target_x: x,
            target_y: y,
            activity: Activity::Idle,
            work: WorkType::None,
            goal: Goal::Nothing,
            hunger: 10.0,
            fatigue: 10.0,
            recreation: 10.0,
            mood: 80.0,
            productivity: 80.0,
            sleep_hours: 0.0,
            last_sleep_quality: 1.0,
        }
    }
}

#[derive(Clone, Debug)]
pub struct World {
    pub tiles: Vec<Tile>,
    pub colonists: Vec<Colonist>,
    pub food: f32,
    pub food_capacity: f32,
    /// Total elapsed in-game seconds since the colony was founded.
    pub game_seconds: f64,
    /// Day-scale smoothed colony mood. This, not the instantaneous average, is
    /// what alerts are compared against.
    pub mood_ema: f32,
    /// Day-scale smoothed colony productivity.
    pub productivity_ema: f32,
}

impl World {
    pub fn day(&self) -> u32 {
        (self.game_seconds / SECONDS_PER_DAY) as u32 + 1
    }

    /// `(hour, minute)` of the in-game day.
    pub fn clock(&self) -> (u32, u32) {
        let sec_of_day = self.game_seconds.rem_euclid(SECONDS_PER_DAY);
        let hour = (sec_of_day / 3600.0) as u32;
        let minute = ((sec_of_day % 3600.0) / 60.0) as u32;
        (hour, minute)
    }

    pub fn has_enabled(&self, kind: TileKind) -> bool {
        self.tiles
            .iter()
            .any(|tile| tile.kind == kind && tile.enabled)
    }

    /// Nearest enabled tile of `kind` by Manhattan distance, ties broken by tile id
    /// so the simulation stays deterministic.
    fn nearest_enabled_tile(&self, kind: TileKind, x: i32, y: i32) -> Option<&Tile> {
        self.tiles
            .iter()
            .filter(|tile| tile.kind == kind && tile.enabled)
            .min_by_key(|tile| ((tile.x - x).abs() + (tile.y - y).abs(), tile.id))
    }

    pub fn avg_mood(&self) -> f32 {
        average(self.colonists.iter().map(|colonist| colonist.mood))
    }

    pub fn avg_productivity(&self) -> f32 {
        average(self.colonists.iter().map(|colonist| colonist.productivity))
    }

    pub fn avg_fatigue(&self) -> f32 {
        average(self.colonists.iter().map(|colonist| colonist.fatigue))
    }

    pub fn avg_recreation(&self) -> f32 {
        average(self.colonists.iter().map(|colonist| colonist.recreation))
    }
}

fn average(values: impl Iterator<Item = f32>) -> f32 {
    let mut n = 0u32;
    let mut sum = 0.0;
    for value in values {
        sum += value;
        n += 1;
    }
    if n == 0 {
        0.0
    } else {
        sum / n as f32
    }
}

fn clamp_percentage(v: f32) -> f32 {
    v.clamp(0.0, 100.0)
}

/// The fixed 16x16 colony layout used by the first vertical slice.
pub fn default_tiles() -> Vec<Tile> {
    let mut tiles = Vec::with_capacity((GRID_W * GRID_H) as usize);
    let mut id = 1u32;
    for y in 0..GRID_H {
        for x in 0..GRID_W {
            let kind = if in_rect(x, y, 2, 2, 3, 3) {
                TileKind::Dining
            } else if in_rect(x, y, 12, 2, 13, 3) {
                TileKind::Sleep
            } else if in_rect(x, y, 6, 10, 8, 12) {
                TileKind::Farm
            } else if in_rect(x, y, 2, 12, 3, 13) {
                TileKind::Recreation
            } else {
                TileKind::Empty
            };
            tiles.push(Tile {
                id,
                x,
                y,
                kind,
                enabled: true,
            });
            id += 1;
        }
    }
    tiles
}

fn in_rect(x: i32, y: i32, x0: i32, y0: i32, x1: i32, y1: i32) -> bool {
    x >= x0 && x <= x1 && y >= y0 && y <= y1
}

/// The three founding colonists.
///
/// Their starting needs are deliberately staggered. With identical starts they
/// stay in lockstep forever — the simulation is deterministic and they share one
/// schedule — so the whole colony would eat, sleep and slack off in unison, which
/// both looks wrong and hides the staffing consequences of the failure chain.
pub fn default_colonists() -> Vec<Colonist> {
    let mut colonists = vec![
        Colonist::new(1, "Ada", 7, 7),
        Colonist::new(2, "Bram", 8, 7),
        Colonist::new(3, "Cyra", 7, 8),
        // Colonist::new(4, "Mithrel", 8, 8),
    ];
    let offsets = [(6.0, 30.0, 12.0), (26.0, 8.0, 34.0), (44.0, 20.0, 2.0)];
    for (colonist, (hunger, fatigue, recreation)) in colonists.iter_mut().zip(offsets) {
        colonist.hunger = hunger;
        colonist.fatigue = fatigue;
        colonist.recreation = recreation;
    }
    colonists
}

pub fn new_world() -> World {
    World {
        tiles: default_tiles(),
        colonists: default_colonists(),
        food: 90.0,
        food_capacity: 100.0,
        game_seconds: 8.0 * 3600.0, // colony wakes up at 08:00 on day 1
        mood_ema: 80.0,
        productivity_ema: 90.0,
    }
}

/// Notable things that happened during a step. Emitted only on *changes*, never
/// once per tick.
#[derive(Clone, Debug, PartialEq)]
pub enum SimEvent {
    ActivityChanged {
        colonist: u64,
        name: String,
        from: Activity,
        to: Activity,
    },
    SleptWithLowMood {
        colonist: u64,
        name: String,
        mood: f32,
    },
    WokePoorlyRested {
        colonist: u64,
        name: String,
        fatigue: f32,
        quality: f32,
    },
    /// Wanted to eat but the colony had no food left.
    MealMissed { colonist: u64, name: String },
    /// Wanted recreation but no recreation tile is enabled.
    RecreationDenied { colonist: u64, name: String },
}

/// Advance the world by `dt_game_seconds` in-game seconds.
///
/// Returns the notable events that occurred. Pure: given the same world, tuning
/// and dt, this always produces the same result.
pub fn step(world: &mut World, tuning: &Tuning, dt_game_seconds: f64) -> Vec<SimEvent> {
    let mut events = Vec::new();
    if dt_game_seconds <= 0.0 {
        return events;
    }
    let dt_hours = (dt_game_seconds / 3600.0) as f32;
    world.game_seconds += dt_game_seconds;

    // Snapshot of what the world offers this tick. Colonists all see the same
    // availability, independent of iteration order.
    let availability = Availability {
        // A colonist can only eat if there is both a working kitchen *and*
        // something in the larder.
        food: world.has_enabled(TileKind::Dining) && world.food > 0.0,
        kitchen: world.has_enabled(TileKind::Dining),
        sleep: world.has_enabled(TileKind::Sleep),
        recreation: world.has_enabled(TileKind::Recreation),
        work: world.has_enabled(TileKind::Farm),
    };

    let colonist_count = world.colonists.len();
    for colonist_index in 0..colonist_count {
        let decision = decide(&world.colonists[colonist_index], tuning, &availability);
        let desired = decision.goal;

        if decision.denied_recreation {
            let colonist = &world.colonists[colonist_index];
            events.push(SimEvent::RecreationDenied {
                colonist: colonist.id,
                name: colonist.name.clone(),
            });
        }
        if decision.denied_food {
            let colonist = &world.colonists[colonist_index];
            events.push(SimEvent::MealMissed {
                colonist: colonist.id,
                name: colonist.name.clone(),
            });
        }

        if world.colonists[colonist_index].goal != desired {
            let (x, y) = (
                world.colonists[colonist_index].x,
                world.colonists[colonist_index].y,
            );
            let dest = desired
                .tile_kind()
                .and_then(|kind| world.nearest_enabled_tile(kind, x, y))
                .map(|tile| (tile.x, tile.y));

            let colonist = &mut world.colonists[colonist_index];
            colonist.goal = desired;
            colonist.sleep_hours = 0.0;
            match dest {
                Some((tx, ty)) => {
                    colonist.target_x = tx;
                    colonist.target_y = ty;
                    colonist.move_progress = 0.0;
                }
                None => {
                    colonist.target_x = colonist.x;
                    colonist.target_y = colonist.y;
                }
            }
        }

        let arrived = {
            let colonist = &world.colonists[colonist_index];
            colonist.x == colonist.target_x && colonist.y == colonist.target_y
        };

        let next_activity = if world.colonists[colonist_index].goal == Goal::Nothing {
            Activity::Idle
        } else if arrived {
            world.colonists[colonist_index].goal.activity()
        } else {
            Activity::Travelling
        };

        let prev_activity = world.colonists[colonist_index].activity;
        if prev_activity != next_activity {
            // Report going to bed in a bad mood before the sleep is simulated.
            if next_activity == Activity::Sleeping {
                let colonist = &world.colonists[colonist_index];
                if colonist.mood < tuning.low_mood_sleep_threshold {
                    events.push(SimEvent::SleptWithLowMood {
                        colonist: colonist.id,
                        name: colonist.name.clone(),
                        mood: colonist.mood,
                    });
                }
            }
            // Report a sleep that ended without actually clearing the fatigue.
            if prev_activity == Activity::Sleeping {
                let colonist = &world.colonists[colonist_index];
                if colonist.fatigue > tuning.poorly_rested_fatigue {
                    events.push(SimEvent::WokePoorlyRested {
                        colonist: colonist.id,
                        name: colonist.name.clone(),
                        fatigue: colonist.fatigue,
                        quality: colonist.last_sleep_quality,
                    });
                }
            }
            let colonist = &mut world.colonists[colonist_index];
            colonist.activity = next_activity;
            if next_activity == Activity::Sleeping {
                colonist.sleep_hours = 0.0;
            }
            events.push(SimEvent::ActivityChanged {
                colonist: colonist.id,
                name: colonist.name.clone(),
                from: prev_activity,
                to: next_activity,
            });
        }

        match next_activity {
            Activity::Travelling => {
                step_travel(&mut world.colonists[colonist_index], tuning, dt_hours)
            }
            Activity::Eating => step_eat(world, colonist_index, tuning, dt_hours),
            Activity::Sleeping => {
                step_sleep(&mut world.colonists[colonist_index], tuning, dt_hours)
            }
            Activity::Recreating => {
                step_recreate(&mut world.colonists[colonist_index], tuning, dt_hours)
            }
            Activity::Working => step_work(world, colonist_index, tuning, dt_hours),
            Activity::Idle => {}
        }

        {
            let colonist = &mut world.colonists[colonist_index];
            let activity = colonist.activity;
            colonist.hunger = clamp_percentage(colonist.hunger + tuning.hunger_per_hour * dt_hours);
            if activity != Activity::Sleeping {
                let extra_fatigue = if activity == Activity::Working {
                    tuning.work_fatigue_per_hour
                } else {
                    0.0
                };
                colonist.fatigue = clamp_percentage(
                    colonist.fatigue + (tuning.fatigue_per_hour + extra_fatigue) * dt_hours,
                );
            }
            if activity != Activity::Recreating {
                colonist.recreation =
                    clamp_percentage(colonist.recreation + tuning.recreation_per_hour * dt_hours);
            }
        }

        {
            let colonist = &mut world.colonists[colonist_index];
            let target = clamp_percentage(
                tuning.mood_base
                    - tuning.mood_w_hunger * colonist.hunger
                    - tuning.mood_w_fatigue * colonist.fatigue
                    - tuning.mood_w_recreation * colonist.recreation,
            );
            let max_step = tuning.mood_rate_per_hour * dt_hours;
            let delta = (target - colonist.mood).clamp(-max_step, max_step);
            colonist.mood = clamp_percentage(colonist.mood + delta);

            colonist.productivity = clamp_percentage(
                tuning.prod_base
                    - tuning.prod_w_fatigue * colonist.fatigue
                    - tuning.prod_w_mood_deficit * (100.0 - colonist.mood),
            );
        }
    }

    let dt = dt_game_seconds as f32;
    let alpha = dt / (tuning.stat_ema_tau_seconds.max(dt) + dt);
    world.mood_ema += (world.avg_mood() - world.mood_ema) * alpha;
    world.productivity_ema += (world.avg_productivity() - world.productivity_ema) * alpha;

    events
}

/// Sleep quality in `[floor, 1.0]`, driven entirely by mood.
///
/// This is the hinge of the failure chain: unmet recreation lowers mood, low mood
/// lowers sleep quality, and low sleep quality means the `max_sleep_hours` cap is
/// hit before the fatigue is actually cleared.
pub fn sleep_quality(mood: f32, tuning: &Tuning) -> f32 {
    tuning.sleep_quality_floor
        + (1.0 - tuning.sleep_quality_floor) * (mood.clamp(0.0, 100.0) / 100.0)
}

/// What the colony can currently offer. Computed once per tick so that every
/// colonist sees the same world, independent of iteration order.
struct Availability {
    /// There is an enabled food tile *and* food in store.
    food: bool,
    /// There is an enabled food tile (but maybe nothing to eat).
    kitchen: bool,
    sleep: bool,
    recreation: bool,
    work: bool,
}

struct Decision {
    goal: Goal,
    /// The colonist needed recreation and the colony could not provide it.
    denied_recreation: bool,
    /// The colonist needed food and the colony could not provide it.
    denied_food: bool,
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

fn decide(colonist: &Colonist, tuning: &Tuning, availability: &Availability) -> Decision {
    // Some activities are "locked in" until they finish, so colonists do not
    // thrash between goals every tick.
    match colonist.activity {
        Activity::Eating if colonist.hunger > tuning.eat_stop && availability.food => {
            return Decision::for_goal(Goal::Eat)
        }
        Activity::Sleeping
            if colonist.fatigue > tuning.sleep_stop_fatigue
                && colonist.sleep_hours < tuning.max_sleep_hours =>
        {
            return Decision::for_goal(Goal::Sleep)
        }
        Activity::Recreating
            if colonist.recreation > tuning.recreate_stop && availability.recreation =>
        {
            return Decision::for_goal(Goal::Recreate)
        }
        _ => {}
    }

    let mut denied_recreation = false;
    let mut denied_food = false;

    if colonist.hunger >= tuning.crit_hunger {
        if availability.food {
            return Decision::for_goal(Goal::Eat);
        }
        // Wanted food, could not get it. Reported once per goal transition (not
        // once per tick) by only firing while the colonist is not already
        // falling back to work.
        denied_food = colonist.goal != Goal::Work && availability.kitchen;
    }
    if colonist.fatigue >= tuning.crit_fatigue && availability.sleep {
        return Decision {
            goal: Goal::Sleep,
            denied_recreation,
            denied_food,
        };
    }
    if colonist.recreation >= tuning.crit_recreation {
        if availability.recreation {
            return Decision {
                goal: Goal::Recreate,
                denied_recreation,
                denied_food,
            };
        }
        denied_recreation = colonist.goal != Goal::Work;
    }
    Decision {
        goal: if availability.work {
            Goal::Work
        } else {
            Goal::Nothing
        },
        denied_recreation,
        denied_food,
    }
}

fn step_travel(colonist: &mut Colonist, tuning: &Tuning, dt_hours: f32) {
    let mut steps = colonist.move_progress + tuning.move_tiles_per_hour * dt_hours;
    while steps >= 1.0 && (colonist.x != colonist.target_x || colonist.y != colonist.target_y) {
        steps -= 1.0;
        if colonist.x != colonist.target_x {
            colonist.x += (colonist.target_x - colonist.x).signum();
        } else if colonist.y != colonist.target_y {
            colonist.y += (colonist.target_y - colonist.y).signum();
        }
    }
    colonist.move_progress = if colonist.x == colonist.target_x && colonist.y == colonist.target_y {
        0.0
    } else {
        steps
    };
}

fn step_eat(world: &mut World, colonist_index: usize, tuning: &Tuning, dt_hours: f32) {
    let want = (tuning.eat_rate_per_hour * dt_hours).min(world.colonists[colonist_index].hunger);
    if want <= 0.0 {
        return;
    }
    let needed = want * tuning.food_per_hunger;
    let taken = needed.min(world.food.max(0.0));
    let removed = if tuning.food_per_hunger > 0.0 {
        taken / tuning.food_per_hunger
    } else {
        want
    };
    world.food = (world.food - taken).max(0.0);
    world.colonists[colonist_index].hunger =
        clamp_percentage(world.colonists[colonist_index].hunger - removed);
}

fn step_sleep(colonist: &mut Colonist, tuning: &Tuning, dt_hours: f32) {
    let quality = sleep_quality(colonist.mood, tuning);
    colonist.last_sleep_quality = quality;
    colonist.fatigue =
        clamp_percentage(colonist.fatigue - tuning.sleep_recovery_per_hour * quality * dt_hours);
    colonist.sleep_hours += dt_hours;
}

fn step_recreate(colonist: &mut Colonist, tuning: &Tuning, dt_hours: f32) {
    colonist.recreation =
        clamp_percentage(colonist.recreation - tuning.recreate_rate_per_hour * dt_hours);
}

fn step_work(world: &mut World, colonist_index: usize, tuning: &Tuning, dt_hours: f32) {
    let productivity = world.colonists[colonist_index].productivity / 100.0;
    let produced = tuning.work_food_per_hour * productivity * dt_hours;
    world.food = (world.food + produced).min(world.food_capacity);
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Aggregated statistics gathered while running the simulation for a while.
    struct Run {
        avg_mood: f32,
        avg_fatigue: f32,
        avg_productivity: f32,
        avg_sleep_quality: f32,
        food_produced: f32,
        recreation_end: f32,
    }

    fn run(recreation_enabled: bool, days: f64) -> Run {
        let t = Tuning::default();
        let mut w = new_world();
        if !recreation_enabled {
            for tile in w.tiles.iter_mut() {
                if tile.kind == TileKind::Recreation {
                    tile.enabled = false;
                }
            }
        }

        let dt = 60.0;
        let ticks = (days * SECONDS_PER_DAY / dt) as usize;

        // Give the colony a larder that never runs out and never fills up, so the
        // measurement isolates production from storage limits. (Kept small enough
        // that f32 still resolves the per-tick increments.)
        w.food = 5_000.0;
        w.food_capacity = 1.0e9;
        let start_food = w.food;

        let mut mood = 0.0f64;
        let mut fatigue = 0.0f64;
        let mut prod = 0.0f64;
        let mut quality = 0.0f64;

        for _ in 0..ticks {
            step(&mut w, &t, dt);
            mood += w.avg_mood() as f64;
            fatigue += w.avg_fatigue() as f64;
            prod += w.avg_productivity() as f64;
            quality += average(
                w.colonists
                    .iter()
                    .map(|colonist| sleep_quality(colonist.mood, &t)),
            ) as f64;
        }

        let n = ticks as f64;
        Run {
            avg_mood: (mood / n) as f32,
            avg_fatigue: (fatigue / n) as f32,
            avg_productivity: (prod / n) as f32,
            avg_sleep_quality: (quality / n) as f32,
            // Food net change; eating is subtracted out, so this is production
            // minus consumption. Both runs eat the same amount per hunger point,
            // so comparing the two is a fair comparison of production.
            food_produced: w.food - start_food,
            recreation_end: w.avg_recreation(),
        }
    }

    #[test]
    fn colony_layout_has_all_zone_types() {
        let w = new_world();
        assert_eq!(w.tiles.len(), (GRID_W * GRID_H) as usize);
        for kind in [
            TileKind::Dining,
            TileKind::Sleep,
            TileKind::Farm,
            TileKind::Recreation,
        ] {
            assert!(w.has_enabled(kind), "missing tile kind {kind:?}");
        }
        assert_eq!(w.colonists.len(), 3);
    }

    #[test]
    fn colonists_cycle_through_all_activities() {
        let t = Tuning::default();
        let mut w = new_world();
        let mut seen = std::collections::HashSet::new();
        for _ in 0..(3.0 * SECONDS_PER_DAY / 60.0) as usize {
            step(&mut w, &t, 60.0);
            for c in &w.colonists {
                seen.insert(c.activity);
            }
        }
        for a in [
            Activity::Travelling,
            Activity::Working,
            Activity::Eating,
            Activity::Sleeping,
            Activity::Recreating,
        ] {
            assert!(seen.contains(&a), "colonists never did {a:?}");
        }
    }

    #[test]
    fn working_produces_food_and_eating_consumes_it() {
        let t = Tuning::default();
        let mut w = new_world();
        w.food = 50.0;
        let mut min_food = w.food;
        let mut max_food = w.food;
        for _ in 0..(2.0 * SECONDS_PER_DAY / 60.0) as usize {
            step(&mut w, &t, 60.0);
            min_food = min_food.min(w.food);
            max_food = max_food.max(w.food);
        }
        assert!(max_food > 50.0, "food never increased ({max_food})");
        assert!(min_food < max_food, "food never decreased");
        assert!(w.food <= w.food_capacity);
    }

    #[test]
    fn food_is_capped_at_capacity() {
        let t = Tuning::default();
        let mut w = new_world();
        w.food = w.food_capacity;
        for _ in 0..2000 {
            step(&mut w, &t, 60.0);
            assert!(w.food <= w.food_capacity + 1e-3);
        }
    }

    #[test]
    fn all_stats_stay_in_range() {
        let t = Tuning::default();
        let mut w = new_world();
        for tile in w.tiles.iter_mut() {
            if tile.kind == TileKind::Recreation {
                tile.enabled = false;
            }
        }
        for _ in 0..(10.0 * SECONDS_PER_DAY / 60.0) as usize {
            step(&mut w, &t, 60.0);
            for c in &w.colonists {
                for (label, v) in [
                    ("hunger", c.hunger),
                    ("fatigue", c.fatigue),
                    ("recreation", c.recreation),
                    ("mood", c.mood),
                    ("productivity", c.productivity),
                ] {
                    assert!((0.0..=100.0).contains(&v), "{label} out of range: {v}");
                }
                assert!(c.x >= 0 && c.x < GRID_W);
                assert!(c.y >= 0 && c.y < GRID_H);
            }
            assert!(w.food >= 0.0);
        }
    }

    /// recreation disabled -> unmet recreation need
    #[test]
    fn chain_1_disabling_recreation_leaves_the_need_unmet() {
        let healthy = run(true, 6.0);
        let broken = run(false, 6.0);
        assert!(
            broken.recreation_end > 90.0,
            "recreation need should saturate when unavailable, got {}",
            broken.recreation_end
        );
        assert!(
            healthy.recreation_end < 80.0,
            "recreation need should be manageable when available, got {}",
            healthy.recreation_end
        );
    }

    /// unmet recreation -> mood falls
    #[test]
    fn chain_2_unmet_recreation_lowers_mood() {
        let healthy = run(true, 6.0);
        let broken = run(false, 6.0);
        assert!(
            broken.avg_mood < healthy.avg_mood - 15.0,
            "mood should fall clearly: healthy {} vs broken {}",
            healthy.avg_mood,
            broken.avg_mood
        );
    }

    /// mood falls -> sleep quality falls
    #[test]
    fn chain_3_low_mood_lowers_sleep_quality() {
        let t = Tuning::default();
        assert!(sleep_quality(20.0, &t) < sleep_quality(90.0, &t));

        let healthy = run(true, 6.0);
        let broken = run(false, 6.0);
        assert!(
            broken.avg_sleep_quality < healthy.avg_sleep_quality - 0.1,
            "sleep quality should fall: healthy {} vs broken {}",
            healthy.avg_sleep_quality,
            broken.avg_sleep_quality
        );
    }

    /// sleep quality falls -> fatigue gets worse
    #[test]
    fn chain_4_bad_sleep_raises_fatigue() {
        let healthy = run(true, 6.0);
        let broken = run(false, 6.0);
        assert!(
            broken.avg_fatigue > healthy.avg_fatigue + 5.0,
            "fatigue should rise: healthy {} vs broken {}",
            healthy.avg_fatigue,
            broken.avg_fatigue
        );
    }

    /// fatigue gets worse -> productivity falls
    #[test]
    fn chain_5_fatigue_and_mood_lower_productivity() {
        let healthy = run(true, 6.0);
        let broken = run(false, 6.0);
        assert!(
            broken.avg_productivity < healthy.avg_productivity - 15.0,
            "productivity should fall: healthy {} vs broken {}",
            healthy.avg_productivity,
            broken.avg_productivity
        );
    }

    /// productivity falls -> food production falls
    #[test]
    fn chain_6_lower_productivity_lowers_food_production() {
        let healthy = run(true, 6.0);
        let broken = run(false, 6.0);
        assert!(
            broken.food_produced < healthy.food_produced,
            "food production should fall: healthy {} vs broken {}",
            healthy.food_produced,
            broken.food_produced
        );
    }

    /// Re-enabling recreation must actually let the colony recover.
    #[test]
    fn chain_7_recovery_after_re_enabling_recreation() {
        let t = Tuning::default();
        let mut w = new_world();
        for tile in w.tiles.iter_mut() {
            if tile.kind == TileKind::Recreation {
                tile.enabled = false;
            }
        }
        for _ in 0..(6.0 * SECONDS_PER_DAY / 60.0) as usize {
            step(&mut w, &t, 60.0);
        }
        let degraded_mood = w.avg_mood();
        let degraded_prod = w.avg_productivity();

        for tile in w.tiles.iter_mut() {
            if tile.kind == TileKind::Recreation {
                tile.enabled = true;
            }
        }
        for _ in 0..(4.0 * SECONDS_PER_DAY / 60.0) as usize {
            step(&mut w, &t, 60.0);
        }

        assert!(
            w.avg_mood() > degraded_mood + 15.0,
            "mood should recover: {} -> {}",
            degraded_mood,
            w.avg_mood()
        );
        assert!(
            w.avg_productivity() > degraded_prod + 10.0,
            "productivity should recover: {} -> {}",
            degraded_prod,
            w.avg_productivity()
        );
    }

    #[test]
    fn events_are_not_emitted_every_tick() {
        let t = Tuning::default();
        let mut w = new_world();
        let ticks = (2.0 * SECONDS_PER_DAY / 60.0) as usize;
        let mut total = 0usize;
        for _ in 0..ticks {
            total += step(&mut w, &t, 60.0).len();
        }
        assert!(
            total < ticks / 10,
            "too chatty: {total} events over {ticks} ticks"
        );
        assert!(total > 0, "no events at all");
    }

    #[test]
    fn poorly_rested_events_appear_only_in_the_broken_colony() {
        fn count_poorly_rested(recreation: bool) -> usize {
            let t = Tuning::default();
            let mut w = new_world();
            if !recreation {
                for tile in w.tiles.iter_mut() {
                    if tile.kind == TileKind::Recreation {
                        tile.enabled = false;
                    }
                }
            }
            let mut n = 0;
            for _ in 0..(8.0 * SECONDS_PER_DAY / 60.0) as usize {
                for e in step(&mut w, &t, 60.0) {
                    if matches!(e, SimEvent::WokePoorlyRested { .. }) {
                        n += 1;
                    }
                }
            }
            n
        }
        assert_eq!(count_poorly_rested(true), 0);
        assert!(count_poorly_rested(false) > 0);
    }

    #[test]
    fn missing_food_is_reported() {
        let t = Tuning::default();
        let mut w = new_world();
        w.food = 0.0;
        for tile in w.tiles.iter_mut() {
            if tile.kind == TileKind::Farm {
                tile.enabled = false;
            }
        }
        let mut missed = false;
        for _ in 0..(3.0 * SECONDS_PER_DAY / 60.0) as usize {
            for e in step(&mut w, &t, 60.0) {
                if matches!(e, SimEvent::MealMissed { .. }) {
                    missed = true;
                }
            }
        }
        assert!(missed, "starving colony never reported a missed meal");
    }

    /// The tuning is only useful if a *working* colony actually looks healthy.
    ///
    /// These are the exact levels the alert thresholds in `lib.rs` are set
    /// against, measured on the smoothed values the alerts actually read, so a
    /// healthy colony never flaps an alert on and off.
    #[test]
    fn alert_thresholds_separate_a_healthy_colony_from_a_broken_one() {
        /// `(min_smoothed_productivity, max_smoothed_productivity,
        ///   min_smoothed_mood, max_smoothed_mood)` after a two-day warmup.
        fn envelope(recreation: bool) -> (f32, f32, f32, f32) {
            let t = Tuning::default();
            let mut w = new_world();
            if !recreation {
                for tile in w.tiles.iter_mut() {
                    if tile.kind == TileKind::Recreation {
                        tile.enabled = false;
                    }
                }
            }
            w.food = 5_000.0;
            w.food_capacity = 1.0e9;
            let (mut lo_p, mut hi_p, mut lo_m, mut hi_m) = (100.0f32, 0.0f32, 100.0f32, 0.0f32);
            let warmup = (2.0 * SECONDS_PER_DAY / 60.0) as usize;
            for i in 0..(10.0 * SECONDS_PER_DAY / 60.0) as usize {
                step(&mut w, &t, 60.0);
                if i > warmup {
                    lo_p = lo_p.min(w.productivity_ema);
                    hi_p = hi_p.max(w.productivity_ema);
                    lo_m = lo_m.min(w.mood_ema);
                    hi_m = hi_m.max(w.mood_ema);
                }
            }
            (lo_p, hi_p, lo_m, hi_m)
        }

        let (h_lo_p, _, h_lo_m, _) = envelope(true);
        let (_, b_hi_p, _, b_hi_m) = envelope(false);

        // `low_productivity` raises below 80 and clears above 83.
        assert!(
            h_lo_p > 83.0,
            "healthy colony would flap the productivity alert (min {h_lo_p})"
        );
        assert!(
            b_hi_p < 80.0,
            "broken colony would not trip the productivity alert (max {b_hi_p})"
        );

        // `low_mood` raises below 45 and clears above 55.
        assert!(
            h_lo_m > 55.0,
            "healthy colony would flap the mood alert (min {h_lo_m})"
        );
        assert!(
            b_hi_m < 45.0,
            "broken colony would not trip the mood alert (max {b_hi_m})"
        );
    }

    /// The last link of the chain, measured the way a player sees it: the larder.
    #[test]
    fn chain_8_broken_colony_runs_out_of_food_and_a_healthy_one_does_not() {
        fn food_after(recreation: bool, days: f64) -> (f32, f32) {
            let t = Tuning::default();
            let mut w = new_world();
            if !recreation {
                for tile in w.tiles.iter_mut() {
                    if tile.kind == TileKind::Recreation {
                        tile.enabled = false;
                    }
                }
            }
            let mut low = w.food;
            for _ in 0..(days * SECONDS_PER_DAY / 60.0) as usize {
                step(&mut w, &t, 60.0);
                low = low.min(w.food);
            }
            (w.food, low)
        }

        let (healthy_food, _) = food_after(true, 10.0);
        let (broken_food, _) = food_after(false, 10.0);

        assert!(
            healthy_food > 0.5 * new_world().food_capacity,
            "a working colony should keep its larder stocked, got {healthy_food}"
        );
        assert!(
            broken_food < 0.25 * new_world().food_capacity,
            "a colony without recreation should drain its larder, got {broken_food}"
        );
    }

    /// Colonists must not share one schedule, or the colony eats and sleeps as a
    /// single organism and the map shows three markers moving as one.
    #[test]
    fn colonists_do_not_move_in_lockstep() {
        let t = Tuning::default();
        let mut w = new_world();
        let mut ticks_all_identical = 0usize;
        let total = (4.0 * SECONDS_PER_DAY / 60.0) as usize;
        for _ in 0..total {
            step(&mut w, &t, 60.0);
            let first = w.colonists[0].activity;
            if w.colonists.iter().all(|c| c.activity == first) {
                ticks_all_identical += 1;
            }
        }
        assert!(
            ticks_all_identical < total / 2,
            "colonists shared an activity for {ticks_all_identical}/{total} ticks"
        );
    }

    #[test]
    fn simulation_is_deterministic() {
        let t = Tuning::default();
        let mut a = new_world();
        let mut b = new_world();
        for _ in 0..5000 {
            let ea = step(&mut a, &t, 60.0);
            let eb = step(&mut b, &t, 60.0);
            assert_eq!(ea, eb);
        }
        for (ca, cb) in a.colonists.iter().zip(b.colonists.iter()) {
            assert_eq!(ca.x, cb.x);
            assert_eq!(ca.y, cb.y);
            assert_eq!(ca.mood, cb.mood);
        }
    }
}
