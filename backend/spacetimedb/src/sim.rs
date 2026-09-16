//! Pure simulation core for Continuum.
//!
//! This module deliberately contains **no** SpacetimeDB glue: no `ReducerContext`,
//! no table handles, no scheduling. It owns a plain-old-data `World` and advances
//! it by a number of in-game seconds. `lib.rs` is responsible for loading rows into
//! a `World`, calling [`step`], and writing the result back.
//!
//! Definitions and tuning live in sibling modules, while the whole module remains
//! testable with a plain `cargo test`.

mod definitions;
mod tuning;
mod work_orders;
pub use definitions::{
    validate_facility_build, Activity, Goal, HaulPolicy, HaulRole, MealPolicy, ResourceKind,
    TileKind, WorkDefinition, WorkType, FACILITY_BUILD_WOOD_COST, RESOURCE_KINDS,
};
pub use tuning::Tuning;
pub use work_orders::{default_work_orders, WorkOrder};
pub mod terrain;

pub const GRID_W: i32 = 24;
pub const GRID_H: i32 = 24;

/// In-game seconds in one in-game day.
pub const SECONDS_PER_DAY: f64 = 86_400.0;

/// Maximum decision/activity interval processed by the simulation core.
const MAX_STEP_SECONDS: f64 = 60.0;

#[derive(Clone, Debug, PartialEq)]
pub struct Tile {
    pub id: u32,
    pub x: i32,
    pub y: i32,
    pub kind: TileKind,
    pub enabled: bool,
}

#[derive(Clone, Debug, PartialEq)]
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
    /// Recomputed from the colony's [`HaulPolicy`] every tick.
    pub haul_role: HaulRole,

    /// What is in the colonist's hands. `carried_amount == 0` means empty hands;
    /// `carried_kind` is then just the last thing they delivered. Modelling it
    /// this way instead of an `Option` keeps the row (and the generated client
    /// binding) a pair of flat columns.
    pub carried_kind: ResourceKind,
    pub carried_amount: f32,

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
    pub fn is_carrying(&self) -> bool {
        self.carried_amount > 0.0
    }

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
            haul_role: HaulRole::Both,
            carried_kind: ResourceKind::Food,
            carried_amount: 0.0,
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

/// A pile of one resource sitting on one tile, waiting to be hauled.
///
/// Ids are *derived* from `(tile_id, kind)` rather than allocated, so the same
/// pile always has the same id no matter how often it empties and refills. That
/// keeps the simulation deterministic and lets `lib.rs` reconcile rows by
/// primary key without an id counter.
#[derive(Clone, Debug, PartialEq)]
pub struct ItemStack {
    pub id: u64,
    pub tile_id: u32,
    pub x: i32,
    pub y: i32,
    pub kind: ResourceKind,
    pub amount: f32,
}

pub fn stack_id(tile_id: u32, kind: ResourceKind) -> u64 {
    tile_id as u64 * RESOURCE_KINDS.len() as u64 + kind.index()
}

/// Piles below this are treated as gone, so f32 dust does not keep empty rows
/// (and empty hauling trips) alive forever.
const STACK_EPSILON: f32 = 1.0e-3;

#[derive(Clone, Debug, PartialEq)]
pub struct Resources {
    pub food: f32,
    pub wood: f32,
    pub stone: f32,
    pub meat: f32,
}

impl Resources {
    pub fn amount(&self, kind: ResourceKind) -> f32 {
        match kind {
            ResourceKind::Food => self.food,
            ResourceKind::Wood => self.wood,
            ResourceKind::Stone => self.stone,
            ResourceKind::Meat => self.meat,
        }
    }

    fn add(&mut self, kind: ResourceKind, amount: f32) {
        match kind {
            ResourceKind::Food => self.food += amount,
            ResourceKind::Wood => self.wood += amount,
            ResourceKind::Stone => self.stone += amount,
            ResourceKind::Meat => self.meat += amount,
        }
    }

    fn take(&mut self, kind: ResourceKind, amount: f32) -> f32 {
        let available = self.amount(kind).max(0.0);
        let taken = amount.min(available);
        match kind {
            ResourceKind::Food => self.food = (self.food - taken).max(0.0),
            ResourceKind::Wood => self.wood = (self.wood - taken).max(0.0),
            ResourceKind::Stone => self.stone = (self.stone - taken).max(0.0),
            ResourceKind::Meat => self.meat = (self.meat - taken).max(0.0),
        }
        taken
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct World {
    pub tiles: Vec<Tile>,
    /// Standing production permissions; an empty list disables all production.
    pub work_orders: Vec<WorkOrder>,
    pub colonists: Vec<Colonist>,
    /// Goods produced but not yet delivered, sorted by id.
    pub stacks: Vec<ItemStack>,
    /// Goods that made it into storage. This is what the colony can actually
    /// eat: production alone does not feed anyone until it has been hauled.
    pub resources: Resources,
    pub haul_policy: HaulPolicy,
    pub meal_policy: MealPolicy,
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

    pub fn tile_at(&self, x: i32, y: i32) -> Option<&Tile> {
        self.tiles.iter().find(|tile| tile.x == x && tile.y == y)
    }

    /// How much of `kind` is piled up on `tile_id`.
    pub fn stack_amount(&self, tile_id: u32, kind: ResourceKind) -> f32 {
        let id = stack_id(tile_id, kind);
        match self.stacks.binary_search_by_key(&id, |stack| stack.id) {
            Ok(index) => self.stacks[index].amount,
            Err(_) => 0.0,
        }
    }

    /// Batch active production, but do not strand leftovers when work stops.
    fn supply_ready(&self, tile: &Tile, work: WorkType, tuning: &Tuning) -> bool {
        let Some(definition) = work.definition() else {
            return false;
        };
        let kind = definition.output;
        let amount = self.stack_amount(tile.id, kind);
        amount > STACK_EPSILON
            && (amount >= tuning.stack_size(kind)
                || self.active_work_order(tile, work).is_none()
                || tuning.output_per_hour(kind) <= 0.0
                || !self.colonists.iter().any(|colonist| {
                    colonist.haul_role.produces()
                        && colonist
                            .work
                            .definition()
                            .is_some_and(|work| work.output == kind)
                        && colonist.goal == Goal::Work
                        && colonist.productivity > 0.0
                        && colonist.target_x == tile.x
                        && colonist.target_y == tile.y
                }))
    }

    /// Rank eligible piles by order priority, distance, then id. Disabling
    /// production does not prevent collecting goods already made.
    fn best_supply_tile(&self, work: WorkType, tuning: &Tuning, x: i32, y: i32) -> Option<&Tile> {
        let definition = work.definition()?;
        self.tiles
            .iter()
            .filter(|tile| {
                tile.kind == definition.facility && self.supply_ready(tile, work, tuning)
            })
            .min_by_key(|tile| {
                let priority = self
                    .active_work_order(tile, work)
                    .map_or(3, |order| order.priority);
                (priority, (tile.x - x).abs() + (tile.y - y).abs(), tile.id)
            })
    }

    /// Add to the pile of `kind` on `tile_id`, creating it if needed.
    fn add_to_stack(&mut self, tile: &Tile, kind: ResourceKind, amount: f32) {
        if amount <= 0.0 {
            return;
        }
        let id = stack_id(tile.id, kind);
        match self.stacks.binary_search_by_key(&id, |stack| stack.id) {
            Ok(index) => self.stacks[index].amount += amount,
            Err(index) => self.stacks.insert(
                index,
                ItemStack {
                    id,
                    tile_id: tile.id,
                    x: tile.x,
                    y: tile.y,
                    kind,
                    amount,
                },
            ),
        }
    }

    /// Remove up to `amount` of `kind` from the pile on `tile_id` and return how
    /// much was actually picked up. Emptied piles are dropped entirely.
    fn take_from_stack(&mut self, tile_id: u32, kind: ResourceKind, amount: f32) -> f32 {
        if amount <= 0.0 {
            return 0.0;
        }
        let id = stack_id(tile_id, kind);
        let Ok(index) = self.stacks.binary_search_by_key(&id, |stack| stack.id) else {
            return 0.0;
        };
        let taken = amount.min(self.stacks[index].amount);
        self.stacks[index].amount -= taken;
        if self.stacks[index].amount <= STACK_EPSILON {
            self.stacks.remove(index);
        }
        taken
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

/// The fixed colony layout.
///
/// Storage sits in the middle so every production site is a comparable haul
/// away, which is what makes the two hauling policies measurably different.
/// Forest is shared by logging and hunting, so one tile can hold two piles.
pub fn default_tiles() -> Vec<Tile> {
    let mut tiles = Vec::with_capacity((GRID_W * GRID_H) as usize);
    let mut id = 1u32;
    for y in 0..GRID_H {
        for x in 0..GRID_W {
            let kind = if in_rect(x, y, 2, 2, 4, 4) {
                TileKind::Dining
            } else if in_rect(x, y, 19, 2, 21, 4) {
                TileKind::Sleep
            } else if in_rect(x, y, 2, 9, 4, 11) {
                TileKind::Recreation
            } else if in_rect(x, y, 10, 10, 13, 13) {
                TileKind::Storage
            } else if in_rect(x, y, 19, 8, 21, 11) {
                TileKind::Mine
            } else if in_rect(x, y, 3, 17, 6, 20) {
                TileKind::Farm
            } else if in_rect(x, y, 16, 16, 20, 20) {
                TileKind::Forest
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

/// The founding colonists: two per producing work type.
///
/// Two of each is the smallest staffing that makes both hauling policies
/// meaningful — under `DedicatedHaulers` the first of each pair produces and the
/// second delivers.
///
/// Their starting needs are deliberately staggered. With identical starts they
/// stay in lockstep forever — the simulation is deterministic and they share one
/// schedule — so the whole colony would eat, sleep and slack off in unison, which
/// both looks wrong and hides the staffing consequences of the failure chain.
pub fn default_colonists() -> Vec<Colonist> {
    // (name, work, spawn, hunger, fatigue, recreation). Kept as one table so the
    // needs cannot silently desync from the roster.
    let roster = [
        ("Ada", WorkType::Farming, (10, 7), 6.0, 30.0, 12.0),
        ("Bram", WorkType::Farming, (11, 7), 26.0, 8.0, 34.0),
        ("Cyra", WorkType::Logging, (12, 7), 44.0, 20.0, 2.0),
        ("Dain", WorkType::Logging, (13, 7), 14.0, 42.0, 24.0),
        ("Enid", WorkType::Mining, (10, 8), 34.0, 12.0, 44.0),
        ("Finn", WorkType::Mining, (11, 8), 20.0, 26.0, 8.0),
        ("Gale", WorkType::Hunting, (12, 8), 48.0, 34.0, 30.0),
        ("Mithrel", WorkType::Hunting, (13, 8), 10.0, 16.0, 40.0),
    ];

    roster
        .iter()
        .enumerate()
        .map(
            |(index, &(name, work, (x, y), hunger, fatigue, recreation))| {
                let mut colonist = Colonist::new(index as u64 + 1, name, x, y);
                colonist.work = work;
                colonist.hunger = hunger;
                colonist.fatigue = fatigue;
                colonist.recreation = recreation;
                colonist
            },
        )
        .collect()
}

pub fn new_world() -> World {
    let tiles = default_tiles();
    World {
        work_orders: default_work_orders(&tiles),
        tiles,
        colonists: default_colonists(),
        stacks: Vec::new(),
        resources: Resources {
            food: 400.0,
            wood: 0.0,
            stone: 0.0,
            meat: 0.0,
        },
        haul_policy: HaulPolicy::SelfHaul,
        meal_policy: MealPolicy::Normal,
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
/// and dt, this always produces the same result. Large durations are processed
/// as ordered, bounded intervals so decisions and activities can change during
/// accelerated time. Non-positive and non-finite durations are ignored.
pub fn step(world: &mut World, tuning: &Tuning, dt_game_seconds: f64) -> Vec<SimEvent> {
    let mut events = Vec::new();
    if !dt_game_seconds.is_finite() || dt_game_seconds <= 0.0 {
        return events;
    }

    let mut remaining = dt_game_seconds;
    while remaining > MAX_STEP_SECONDS {
        events.extend(step_bounded(world, tuning, MAX_STEP_SECONDS));
        remaining -= MAX_STEP_SECONDS;
    }
    events.extend(step_bounded(world, tuning, remaining));
    events
}

fn step_bounded(world: &mut World, tuning: &Tuning, dt_game_seconds: f64) -> Vec<SimEvent> {
    let mut events = Vec::new();
    let dt_hours = (dt_game_seconds / 3600.0) as f32;
    world.game_seconds += dt_game_seconds;

    assign_haul_roles(world);

    // Snapshot of what the world offers this tick. Colonists all see the same
    // availability, independent of iteration order.
    let availability = Availability {
        // A colonist can only eat if there is both a working kitchen *and*
        // something in the larder.
        food: world.has_enabled(TileKind::Dining)
            && world.resources.amount(ResourceKind::Food) > 0.0,
        kitchen: world.has_enabled(TileKind::Dining),
        sleep: world.has_enabled(TileKind::Sleep),
        recreation: world.has_enabled(TileKind::Recreation),
    };

    let colonist_count = world.colonists.len();
    for colonist_index in 0..colonist_count {
        let labour = labour_goal(world, colonist_index, tuning);
        let decision = decide(
            &world.colonists[colonist_index],
            tuning,
            &availability,
            labour,
        );
        let mut desired = decision.goal;

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

        let work = world.colonists[colonist_index].work;
        let carrying = world.colonists[colonist_index].is_carrying();
        let destination_invalid = !destination_still_serves(world, colonist_index, tuning, desired);
        if world.colonists[colonist_index].goal != desired || destination_invalid {
            let dest = destination_for(world, colonist_index, tuning, desired)
                .map(|tile| (tile.x, tile.y));

            if desired.tile_kind(work, carrying).is_some() && dest.is_none() {
                desired = Goal::Nothing;
            }

            let colonist = &mut world.colonists[colonist_index];
            colonist.goal = desired;
            colonist.sleep_hours = 0.0;
            match dest {
                Some((tx, ty)) => {
                    if (colonist.target_x, colonist.target_y) != (tx, ty) {
                        colonist.move_progress = 0.0;
                    }
                    colonist.target_x = tx;
                    colonist.target_y = ty;
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
            Activity::Hauling => step_haul(world, colonist_index, tuning),
            Activity::Idle => {}
        }

        {
            let colonist = &mut world.colonists[colonist_index];
            let activity = colonist.activity;
            colonist.hunger = clamp_percentage(colonist.hunger + tuning.hunger_per_hour * dt_hours);
            if activity != Activity::Sleeping {
                // Hauling is labour too, so dedicated haulers are not free.
                let extra_fatigue = if matches!(activity, Activity::Working | Activity::Hauling) {
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
}

/// Stamp every colonist with the role implied by the colony's hauling policy.
///
/// Derived every tick rather than stored as an independent field, so the policy
/// is the single source of truth and toggling it can never leave a stale role
/// behind. Under `DedicatedHaulers` the pairing is by id within a work type,
/// independent of the order rows were loaded in.
fn assign_haul_roles(world: &mut World) {
    match world.haul_policy {
        HaulPolicy::SelfHaul => {
            for colonist in &mut world.colonists {
                colonist.haul_role = HaulRole::Both;
            }
        }
        HaulPolicy::DedicatedHaulers => {
            for index in 0..world.colonists.len() {
                let work = world.colonists[index].work;
                let id = world.colonists[index].id;
                let rank = world
                    .colonists
                    .iter()
                    .filter(|other| other.work == work && other.id < id)
                    .count();
                world.colonists[index].haul_role = if work == WorkType::None {
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
fn labour_goal(world: &World, index: usize, tuning: &Tuning) -> Option<Goal> {
    let colonist = &world.colonists[index];
    let storage_open = world.has_enabled(TileKind::Storage);

    // Hands full: finish the delivery before anything else on the job.
    if colonist.is_carrying() {
        return storage_open.then_some(Goal::Haul);
    }
    colonist.work.definition()?;

    let pile_ready = storage_open
        && world
            .best_supply_tile(colonist.work, tuning, colonist.x, colonist.y)
            .is_some();

    if colonist.haul_role.hauls() && pile_ready {
        return Some(Goal::Haul);
    }
    if colonist.haul_role.produces()
        && world
            .best_work_tile(colonist.work, colonist.x, colonist.y)
            .is_some()
    {
        return Some(Goal::Work);
    }
    None
}

/// Where `goal` wants this colonist to walk.
fn destination_for<'a>(
    world: &'a World,
    index: usize,
    tuning: &Tuning,
    goal: Goal,
) -> Option<&'a Tile> {
    let colonist = &world.colonists[index];
    if goal == Goal::Work {
        return world.best_work_tile(colonist.work, colonist.x, colonist.y);
    }
    if goal == Goal::Haul && !colonist.is_carrying() {
        // Not just any production site: one that actually has a stack waiting.
        return world.best_supply_tile(colonist.work, tuning, colonist.x, colonist.y);
    }
    let kind = goal.tile_kind(colonist.work, colonist.is_carrying())?;
    world.nearest_enabled_tile(kind, colonist.x, colonist.y)
}

/// Whether the colonist's current target is still the right place for `goal`.
///
/// This is what makes colonists react to the world changing under them: a zone
/// switched off, or — new with hauling — a pile that somebody else got to first.
fn destination_still_serves(world: &World, index: usize, tuning: &Tuning, goal: Goal) -> bool {
    let colonist = &world.colonists[index];
    // Re-rank production and empty pickups every bounded interval, without
    // resetting fractional travel when the winning destination is unchanged.
    if goal == Goal::Work || (goal == Goal::Haul && !colonist.is_carrying()) {
        return destination_for(world, index, tuning, goal)
            .is_some_and(|tile| tile.x == colonist.target_x && tile.y == colonist.target_y);
    }
    let Some(kind) = goal.tile_kind(colonist.work, colonist.is_carrying()) else {
        return true;
    };
    let Some(tile) = world.tile_at(colonist.target_x, colonist.target_y) else {
        return false;
    };
    if tile.kind != kind {
        return false;
    }
    tile.enabled
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

fn decide(
    colonist: &Colonist,
    tuning: &Tuning,
    availability: &Availability,
    labour: Option<Goal>,
) -> Decision {
    // Some activities are "locked in" until they finish, so colonists do not
    // thrash between goals every tick.
    match colonist.activity {
        Activity::Eating if colonist.hunger > tuning.eat_stop && availability.food => {
            return Decision::for_goal(Goal::Eat)
        }
        Activity::Sleeping
            if colonist.fatigue > tuning.sleep_stop_fatigue
                && colonist.sleep_hours < tuning.max_sleep_hours
                && availability.sleep =>
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
        denied_food = !colonist.goal.is_labour() && availability.kitchen;
    }
    let sleep_cap_reached =
        colonist.activity == Activity::Sleeping && colonist.sleep_hours >= tuning.max_sleep_hours;
    if colonist.fatigue >= tuning.crit_fatigue && availability.sleep && !sleep_cap_reached {
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
        denied_recreation = !colonist.goal.is_labour();
    }
    let goal = labour.unwrap_or(Goal::Nothing);
    Decision {
        goal,
        // Waiting haulers can remain idle for hours. Report the fallback once,
        // not a fresh denial on every interval with nothing available to haul.
        denied_recreation: denied_recreation && colonist.goal != goal,
        denied_food: denied_food && colonist.goal != goal,
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
    let recovery_multiplier = world.meal_policy.hunger_recovery_multiplier();
    let cost_per_hunger =
        tuning.food_per_hunger * world.meal_policy.food_cost_per_hunger_multiplier();
    let want = (tuning.eat_rate_per_hour * dt_hours * recovery_multiplier)
        .min(world.colonists[colonist_index].hunger);
    if want <= 0.0 {
        return;
    }
    let needed = want * cost_per_hunger;
    let taken = world.resources.take(ResourceKind::Food, needed);
    let removed = if cost_per_hunger > 0.0 {
        taken / cost_per_hunger
    } else {
        want
    };
    world.colonists[colonist_index].hunger =
        clamp_percentage(world.colonists[colonist_index].hunger - removed);
}

fn step_sleep(colonist: &mut Colonist, tuning: &Tuning, dt_hours: f32) {
    let sleep_hours = dt_hours.min((tuning.max_sleep_hours - colonist.sleep_hours).max(0.0));
    let quality = sleep_quality(colonist.mood, tuning);
    colonist.last_sleep_quality = quality;
    colonist.fatigue =
        clamp_percentage(colonist.fatigue - tuning.sleep_recovery_per_hour * quality * sleep_hours);
    colonist.sleep_hours = (colonist.sleep_hours + sleep_hours).min(tuning.max_sleep_hours);
}

fn step_recreate(colonist: &mut Colonist, tuning: &Tuning, dt_hours: f32) {
    colonist.recreation =
        clamp_percentage(colonist.recreation - tuning.recreate_rate_per_hour * dt_hours);
}

/// Work the facility the colonist is standing on.
///
/// Output lands as a pile *on that tile*, not in the colony's stores. Nothing is
/// usable until somebody hauls it, which is the whole point of the logistics
/// layer.
fn step_work(world: &mut World, colonist_index: usize, tuning: &Tuning, dt_hours: f32) {
    if !world.colonists[colonist_index].haul_role.produces()
        || world.colonists[colonist_index].is_carrying()
    {
        return;
    }
    let Some(definition) = world.colonists[colonist_index].work.definition() else {
        return;
    };
    let (x, y) = (
        world.colonists[colonist_index].x,
        world.colonists[colonist_index].y,
    );
    let Some(tile) = world.tile_at(x, y).cloned() else {
        return;
    };
    if world
        .active_work_order(&tile, world.colonists[colonist_index].work)
        .is_none()
    {
        return;
    }
    let productivity = world.colonists[colonist_index].productivity / 100.0;
    let produced = tuning.output_per_hour(definition.output) * productivity * dt_hours;
    world.add_to_stack(&tile, definition.output, produced);
}

/// Pick up or deposit up to one stack per decision interval.
fn step_haul(world: &mut World, colonist_index: usize, tuning: &Tuning) {
    let (x, y) = (
        world.colonists[colonist_index].x,
        world.colonists[colonist_index].y,
    );
    let Some(tile) = world.tile_at(x, y).cloned() else {
        return;
    };
    if world.colonists[colonist_index].is_carrying() {
        if tile.kind != TileKind::Storage || !tile.enabled {
            return;
        }
        let colonist = &mut world.colonists[colonist_index];
        let (kind, amount) = (colonist.carried_kind, colonist.carried_amount);
        colonist.carried_amount = 0.0;
        world.resources.add(kind, amount);
        return;
    }

    let Some(definition) = world.colonists[colonist_index].work.definition() else {
        return;
    };
    if tile.kind != definition.facility
        || !world.colonists[colonist_index].haul_role.hauls()
        || !world.has_enabled(TileKind::Storage)
        || !world.supply_ready(&tile, world.colonists[colonist_index].work, tuning)
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
        colonist.carried_kind = definition.output;
        colonist.carried_amount = taken;
    }
}

#[cfg(test)]
mod tests;
