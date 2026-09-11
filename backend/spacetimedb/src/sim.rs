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

pub const GRID_W: i32 = 24;
pub const GRID_H: i32 = 24;

/// In-game seconds in one in-game day.
pub const SECONDS_PER_DAY: f64 = 86_400.0;

/// Maximum decision/activity interval processed by the simulation core.
const MAX_STEP_SECONDS: f64 = 60.0;

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

    /// Resource units produced per in-game hour by a colonist at 100%
    /// productivity. Food is much higher than the rest because food demand
    /// scales with the whole population while the other resources have no
    /// consumer yet.
    pub output_food_per_hour: f32,
    pub output_wood_per_hour: f32,
    pub output_stone_per_hour: f32,
    pub output_meat_per_hour: f32,

    /// How much of one resource fits in a single carried stack. A production
    /// site accumulates a ground pile; trips carry up to one stack. Partial piles
    /// are collected when nobody is working or heading to work on that tile.
    pub stack_food: f32,
    pub stack_wood: f32,
    pub stack_stone: f32,
    pub stack_meat: f32,

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

            output_food_per_hour: 14.0,
            output_wood_per_hour: 6.0,
            output_stone_per_hour: 5.0,
            output_meat_per_hour: 4.0,

            stack_food: 30.0,
            stack_wood: 25.0,
            stack_stone: 20.0,
            stack_meat: 15.0,

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

impl Tuning {
    pub fn output_per_hour(&self, kind: ResourceKind) -> f32 {
        match kind {
            ResourceKind::Food => self.output_food_per_hour,
            ResourceKind::Wood => self.output_wood_per_hour,
            ResourceKind::Stone => self.output_stone_per_hour,
            ResourceKind::Meat => self.output_meat_per_hour,
        }
    }

    pub fn stack_size(&self, kind: ResourceKind) -> f32 {
        match kind {
            ResourceKind::Food => self.stack_food,
            ResourceKind::Wood => self.stack_wood,
            ResourceKind::Stone => self.stack_stone,
            ResourceKind::Meat => self.stack_meat,
        }
    }
}

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
    pub colonists: Vec<Colonist>,
    /// Goods produced but not yet delivered, sorted by id.
    pub stacks: Vec<ItemStack>,
    /// Goods that made it into storage. This is what the colony can actually
    /// eat: production alone does not feed anyone until it has been hauled.
    pub resources: Resources,
    pub haul_policy: HaulPolicy,
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
    fn supply_ready(&self, tile: &Tile, kind: ResourceKind, tuning: &Tuning) -> bool {
        let amount = self.stack_amount(tile.id, kind);
        amount > STACK_EPSILON
            && (amount >= tuning.stack_size(kind)
                || !tile.enabled
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

    /// Disabling production does not prevent collecting goods already made.
    fn nearest_supply_tile(
        &self,
        facility: TileKind,
        kind: ResourceKind,
        tuning: &Tuning,
        x: i32,
        y: i32,
    ) -> Option<&Tile> {
        self.tiles
            .iter()
            .filter(|tile| tile.kind == facility && self.supply_ready(tile, kind, tuning))
            .min_by_key(|tile| ((tile.x - x).abs() + (tile.y - y).abs(), tile.id))
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
    World {
        tiles: default_tiles(),
        colonists: default_colonists(),
        stacks: Vec::new(),
        resources: Resources {
            food: 400.0,
            wood: 0.0,
            stone: 0.0,
            meat: 0.0,
        },
        haul_policy: HaulPolicy::SelfHaul,
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
    let definition = colonist.work.definition()?;

    let pile_ready = storage_open
        && world
            .nearest_supply_tile(
                definition.facility,
                definition.output,
                tuning,
                colonist.x,
                colonist.y,
            )
            .is_some();

    if colonist.haul_role.hauls() && pile_ready {
        return Some(Goal::Haul);
    }
    if colonist.haul_role.produces() && world.has_enabled(definition.facility) {
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
    if goal == Goal::Haul && !colonist.is_carrying() {
        // Not just any production site: one that actually has a stack waiting.
        let definition = colonist.work.definition()?;
        return world.nearest_supply_tile(
            definition.facility,
            definition.output,
            tuning,
            colonist.x,
            colonist.y,
        );
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
    let Some(kind) = goal.tile_kind(colonist.work, colonist.is_carrying()) else {
        return true;
    };
    let Some(tile) = world.tile_at(colonist.target_x, colonist.target_y) else {
        return false;
    };
    if tile.kind != kind {
        return false;
    }
    if goal == Goal::Haul && !colonist.is_carrying() {
        let Some(definition) = colonist.work.definition() else {
            return false;
        };
        return world.supply_ready(tile, definition.output, tuning);
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
    let want = (tuning.eat_rate_per_hour * dt_hours).min(world.colonists[colonist_index].hunger);
    if want <= 0.0 {
        return;
    }
    let needed = want * tuning.food_per_hunger;
    let taken = world.resources.take(ResourceKind::Food, needed);
    let removed = if tuning.food_per_hunger > 0.0 {
        taken / tuning.food_per_hunger
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
    if tile.kind != definition.facility || !tile.enabled {
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
        || !world.supply_ready(&tile, definition.output, tuning)
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
mod tests {
    use super::*;

    fn hauling_world(work: WorkType, policy: HaulPolicy) -> (World, Tuning) {
        let mut world = new_world();
        world.haul_policy = policy;
        world.tiles = [work.definition().unwrap().facility, TileKind::Storage]
            .into_iter()
            .enumerate()
            .map(|(index, kind)| Tile {
                id: index as u32 + 1,
                x: index as i32 * 3,
                y: 0,
                kind,
                enabled: true,
            })
            .collect();
        world.colonists = (1..=2)
            .map(|id| {
                let mut colonist = Colonist::new(id, "Worker", 0, 0);
                colonist.work = work;
                colonist.productivity = 100.0;
                colonist
            })
            .collect();
        let tuning = Tuning {
            hunger_per_hour: 0.0,
            fatigue_per_hour: 0.0,
            work_fatigue_per_hour: 0.0,
            recreation_per_hour: 0.0,
            prod_base: 100.0,
            prod_w_fatigue: 0.0,
            prod_w_mood_deficit: 0.0,
            move_tiles_per_hour: 60.0,
            ..Tuning::default()
        };
        (world, tuning)
    }

    #[test]
    fn each_job_produces_and_delivers_under_both_policies() {
        for work in [
            WorkType::Farming,
            WorkType::Logging,
            WorkType::Mining,
            WorkType::Hunting,
        ] {
            for policy in [HaulPolicy::SelfHaul, HaulPolicy::DedicatedHaulers] {
                let (mut world, tuning) = hauling_world(work, policy);
                let before = world.resources.clone();
                let kind = work.definition().unwrap().output;
                for _ in 0..360 {
                    step(&mut world, &tuning, 60.0);
                    for colonist in &world.colonists {
                        assert!(colonist.carried_amount <= tuning.stack_size(kind));
                        if policy == HaulPolicy::DedicatedHaulers {
                            if colonist.id == 1 {
                                assert!(!colonist.is_carrying());
                            } else {
                                assert_ne!(colonist.activity, Activity::Working);
                            }
                        }
                    }
                }
                assert!(
                    world.resources.amount(kind) > before.amount(kind),
                    "{work:?} / {policy:?}"
                );
                for other in RESOURCE_KINDS {
                    if other != kind {
                        assert_eq!(world.resources.amount(other), before.amount(other));
                    }
                }
            }
        }
    }

    #[test]
    fn dedicated_roles_follow_ids_not_row_order() {
        let mut world = new_world();
        world.haul_policy = HaulPolicy::DedicatedHaulers;
        world.colonists.reverse();
        assign_haul_roles(&mut world);
        for colonist in &world.colonists {
            assert_eq!(
                colonist.haul_role,
                if colonist.id % 2 == 1 {
                    HaulRole::Producer
                } else {
                    HaulRole::Hauler
                }
            );
        }
    }

    #[test]
    fn policy_changes_cancel_incompatible_work_and_empty_pickups() {
        let (mut world, tuning) = hauling_world(WorkType::Farming, HaulPolicy::SelfHaul);
        step(&mut world, &tuning, 60.0);
        assert!(world.colonists.iter().all(|c| c.goal == Goal::Work));
        world.haul_policy = HaulPolicy::DedicatedHaulers;
        step(&mut world, &tuning, 60.0);
        assert_eq!(world.colonists[1].goal, Goal::Nothing);
        world.haul_policy = HaulPolicy::SelfHaul;
        step(&mut world, &tuning, 60.0);
        assert_eq!(world.colonists[1].goal, Goal::Work);

        world.add_to_stack(
            &world.tiles[0].clone(),
            ResourceKind::Food,
            tuning.stack_food,
        );
        world.colonists[0].goal = Goal::Haul;
        world.colonists[0].activity = Activity::Travelling;
        world.colonists[0].x = 1;
        world.haul_policy = HaulPolicy::DedicatedHaulers;
        step(&mut world, &tuning, 60.0);
        assert_eq!(world.colonists[0].goal, Goal::Work);
        assert!(!world.colonists[0].is_carrying());
        assert_eq!(world.colonists[1].carried_amount, tuning.stack_food);
    }

    #[test]
    fn carried_goods_survive_policy_changes_and_unassignment() {
        for policy in [HaulPolicy::SelfHaul, HaulPolicy::DedicatedHaulers] {
            for work in [WorkType::Farming, WorkType::None] {
                let (mut world, tuning) = hauling_world(WorkType::Farming, policy);
                world.colonists.truncate(1);
                world.colonists[0].carried_kind = ResourceKind::Wood;
                world.colonists[0].carried_amount = tuning.stack_wood;
                world.colonists[0].goal = Goal::Work;
                step(&mut world, &tuning, 60.0);
                assert_eq!(world.colonists[0].goal, Goal::Haul);
                world.haul_policy = match policy {
                    HaulPolicy::SelfHaul => HaulPolicy::DedicatedHaulers,
                    HaulPolicy::DedicatedHaulers => HaulPolicy::SelfHaul,
                };
                world.colonists[0].work = work;
                step(&mut world, &tuning, 3.0 * 60.0);
                assert_eq!(world.resources.wood, tuning.stack_wood);
                assert!(!world.colonists[0].is_carrying());
            }
        }
    }

    #[test]
    fn disabled_storage_blocks_pickup_but_not_production() {
        let (mut world, tuning) = hauling_world(WorkType::Farming, HaulPolicy::DedicatedHaulers);
        world.tiles[1].enabled = false;
        world.add_to_stack(
            &world.tiles[0].clone(),
            ResourceKind::Food,
            tuning.stack_food,
        );
        let before = world.resources.food;
        step(&mut world, &tuning, 60.0);
        assert!(world.stack_amount(1, ResourceKind::Food) > tuning.stack_food);
        assert!(world.colonists.iter().all(|c| !c.is_carrying()));
        assert_eq!(world.colonists[1].goal, Goal::Nothing);
        assert_eq!(world.resources.food, before);
        world.tiles[1].enabled = true;
        step(&mut world, &tuning, 5.0 * 60.0);
        assert_eq!(world.resources.food, before + tuning.stack_food);
    }

    #[test]
    fn carriers_wait_with_goods_and_retarget_enabled_storage() {
        let (mut world, tuning) = hauling_world(WorkType::Farming, HaulPolicy::SelfHaul);
        world.colonists.truncate(1);
        world.colonists[0].carried_amount = 12.0;
        let before = world.resources.food;
        step(&mut world, &tuning, 60.0);
        assert_eq!(world.colonists[0].target_x, 3);
        world.tiles[1].enabled = false;
        step(&mut world, &tuning, 60.0);
        assert_eq!(world.colonists[0].goal, Goal::Nothing);
        assert_eq!(world.colonists[0].carried_amount, 12.0);
        assert!(world.stacks.is_empty());
        world.tiles.push(Tile {
            id: 3,
            x: 2,
            y: 0,
            kind: TileKind::Storage,
            enabled: true,
        });
        step(&mut world, &tuning, 2.0 * 60.0);
        assert_eq!(world.colonists[0].target_x, 2);
        assert_eq!(world.resources.food, before + 12.0);
        assert!(!world.colonists[0].is_carrying());
    }

    #[test]
    fn disabled_work_tiles_stop_production_but_allow_partial_pickups() {
        for policy in [HaulPolicy::SelfHaul, HaulPolicy::DedicatedHaulers] {
            let (mut world, tuning) = hauling_world(WorkType::Farming, policy);
            step(&mut world, &tuning, 60.0);
            let amount = world.stack_amount(1, ResourceKind::Food);
            let before = world.resources.food;
            world.tiles[0].enabled = false;
            step(&mut world, &tuning, 5.0 * 60.0);
            assert!(world.stacks.is_empty());
            assert!((world.resources.food - before - amount).abs() < 1.0e-4);
            assert!(world
                .colonists
                .iter()
                .all(|c| c.activity != Activity::Working));
        }
    }

    #[test]
    fn dedicated_haulers_batch_active_output_and_collect_when_producer_rests() {
        let (mut world, tuning) = hauling_world(WorkType::Farming, HaulPolicy::DedicatedHaulers);
        step(&mut world, &tuning, 10.0 * 60.0);
        assert_eq!(world.colonists[1].goal, Goal::Nothing);
        assert!(world.stack_amount(1, ResourceKind::Food) > 0.0);
        world.tiles.push(Tile {
            id: 3,
            x: 0,
            y: 1,
            kind: TileKind::Sleep,
            enabled: true,
        });
        world.colonists[0].fatigue = 80.0;
        let amount = world.stack_amount(1, ResourceKind::Food);
        step(&mut world, &tuning, 60.0);
        assert_eq!(world.colonists[0].goal, Goal::Sleep);
        assert_eq!(world.colonists[1].carried_amount, amount);
        assert!(world.stacks.is_empty());
    }

    #[test]
    fn competing_pickups_conserve_goods_and_retarget_depleted_piles() {
        for amount in [30.0, 35.0] {
            let (mut world, mut tuning) = hauling_world(WorkType::Farming, HaulPolicy::SelfHaul);
            tuning.output_food_per_hour = 0.0;
            let before = world.resources.food;
            world.add_to_stack(&world.tiles[0].clone(), ResourceKind::Food, amount);
            for colonist in &mut world.colonists {
                colonist.goal = Goal::Haul;
                colonist.activity = Activity::Hauling;
            }
            step(&mut world, &tuning, 60.0);
            assert_eq!(world.colonists[0].carried_amount, 30.0);
            assert_eq!(world.colonists[1].carried_amount, amount - 30.0);
            assert!(world.stacks.is_empty());
            if amount == 30.0 {
                assert_eq!(world.colonists[1].goal, Goal::Work);
            }
            step(&mut world, &tuning, 4.0 * 60.0);
            assert_eq!(world.resources.food, before + amount);
        }
    }

    #[test]
    fn work_and_pickup_targets_follow_remaining_facilities_and_piles() {
        let (mut world, tuning) = hauling_world(WorkType::Farming, HaulPolicy::SelfHaul);
        world.colonists.truncate(1);
        world.tiles.push(Tile {
            id: 3,
            x: 6,
            y: 0,
            kind: TileKind::Farm,
            enabled: true,
        });
        step(&mut world, &tuning, 60.0);
        world.tiles[0].enabled = false;
        world.stacks.clear();
        step(&mut world, &tuning, 60.0);
        assert_eq!(world.colonists[0].goal, Goal::Work);
        assert_eq!(world.colonists[0].target_x, 6);

        world.add_to_stack(
            &world.tiles[0].clone(),
            ResourceKind::Food,
            tuning.stack_food,
        );
        world.add_to_stack(
            &world.tiles[2].clone(),
            ResourceKind::Food,
            tuning.stack_food,
        );
        step(&mut world, &tuning, 60.0);
        assert_eq!(world.colonists[0].goal, Goal::Haul);
        assert_eq!(world.colonists[0].target_x, 0);
        world.take_from_stack(1, ResourceKind::Food, tuning.stack_food);
        step(&mut world, &tuning, 60.0);
        assert_eq!(world.colonists[0].goal, Goal::Haul);
        assert_eq!(world.colonists[0].target_x, 6);
        assert!(!world.colonists[0].is_carrying());
    }

    #[test]
    fn shared_forest_piles_are_sorted_and_picked_up_by_resource() {
        let (mut world, tuning) = hauling_world(WorkType::Logging, HaulPolicy::SelfHaul);
        world.colonists[1].work = WorkType::Hunting;
        let tile = world.tiles[0].clone();
        world.add_to_stack(&tile, ResourceKind::Meat, tuning.stack_meat);
        world.add_to_stack(&tile, ResourceKind::Wood, tuning.stack_wood);
        assert!(world.stacks[0].id < world.stacks[1].id);
        step(&mut world, &tuning, 60.0);
        assert_eq!(world.colonists[0].carried_kind, ResourceKind::Wood);
        assert_eq!(world.colonists[0].carried_amount, tuning.stack_wood);
        assert_eq!(world.colonists[1].carried_kind, ResourceKind::Meat);
        assert_eq!(world.colonists[1].carried_amount, tuning.stack_meat);
        assert!(world.stacks.is_empty());
        world.add_to_stack(&tile, ResourceKind::Wood, 1.0);
        assert_eq!(world.stacks[0].id, stack_id(tile.id, ResourceKind::Wood));
    }

    #[test]
    fn needs_interrupt_hauling_without_losing_the_carried_stack() {
        let (mut world, tuning) = hauling_world(WorkType::Farming, HaulPolicy::SelfHaul);
        world.colonists.truncate(1);
        world.tiles.push(Tile {
            id: 3,
            x: 0,
            y: 1,
            kind: TileKind::Dining,
            enabled: true,
        });
        world.colonists[0].carried_kind = ResourceKind::Wood;
        world.colonists[0].carried_amount = tuning.stack_wood;
        world.colonists[0].hunger = 80.0;
        step(&mut world, &tuning, 2.0 * 60.0);
        assert_eq!(world.colonists[0].activity, Activity::Eating);
        assert_eq!(world.colonists[0].carried_amount, tuning.stack_wood);
        step(&mut world, &tuning, 30.0 * 60.0);
        assert_eq!(world.resources.wood, tuning.stack_wood);
        assert!(!world.colonists[0].is_carrying());
    }

    #[test]
    fn idle_haulers_do_not_repeat_need_denials() {
        let (mut world, tuning) = hauling_world(WorkType::Farming, HaulPolicy::DedicatedHaulers);
        world.tiles[0].enabled = false;
        world.colonists[1].recreation = 80.0;
        world.colonists[1].goal = Goal::Recreate;
        let events = step(&mut world, &tuning, 60.0);
        assert!(events
            .iter()
            .any(|event| matches!(event, SimEvent::RecreationDenied { colonist: 2, .. })));
        assert!(step(&mut world, &tuning, 10.0 * 60.0).is_empty());
    }

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

        // Keep food available to isolate the recreation failure chain.
        w.resources.food = 5_000.0;
        let start_food = w.resources.food;

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
            food_produced: w.resources.food - start_food,
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
            TileKind::Forest,
            TileKind::Mine,
            TileKind::Storage,
            TileKind::Recreation,
        ] {
            assert!(w.has_enabled(kind), "missing tile kind {kind:?}");
        }
        assert_eq!(w.colonists.len(), 8);
        for work in [
            WorkType::Farming,
            WorkType::Logging,
            WorkType::Mining,
            WorkType::Hunting,
        ] {
            assert_eq!(w.colonists.iter().filter(|c| c.work == work).count(), 2);
        }
    }

    #[test]
    fn work_definitions_are_the_source_of_facilities_and_outputs() {
        assert_eq!(WorkType::None.definition(), None);
        assert_eq!(Goal::Work.tile_kind(WorkType::None, false), None);

        for (work, facility, output) in [
            (WorkType::Farming, TileKind::Farm, ResourceKind::Food),
            (WorkType::Logging, TileKind::Forest, ResourceKind::Wood),
            (WorkType::Mining, TileKind::Mine, ResourceKind::Stone),
            (WorkType::Hunting, TileKind::Forest, ResourceKind::Meat),
        ] {
            let definition = work.definition().unwrap();
            assert_eq!(definition.facility, facility);
            assert_eq!(definition.output, output);
            assert_eq!(Goal::Work.tile_kind(work, false), Some(facility));
            assert_eq!(Goal::Haul.tile_kind(work, false), Some(facility));
            assert_eq!(Goal::Haul.tile_kind(work, true), Some(TileKind::Storage));
        }
    }

    #[test]
    fn producing_work_creates_only_its_declared_pile_not_stored_resources() {
        let tuning = Tuning::default();

        for (work, output) in [
            (WorkType::Farming, ResourceKind::Food),
            (WorkType::Logging, ResourceKind::Wood),
            (WorkType::Mining, ResourceKind::Stone),
            (WorkType::Hunting, ResourceKind::Meat),
        ] {
            let mut world = new_world();
            let tile = world
                .tiles
                .iter()
                .find(|tile| tile.kind == work.definition().unwrap().facility)
                .unwrap()
                .clone();
            world.colonists[0].work = work;
            world.colonists[0].x = tile.x;
            world.colonists[0].y = tile.y;
            let before = world.resources.clone();

            step_work(&mut world, 0, &tuning, 1.0);

            assert_eq!(world.resources, before);
            assert_eq!(world.stacks.len(), 1);
            assert_eq!(world.stacks[0].id, stack_id(tile.id, output));
            assert_eq!(world.stacks[0].kind, output);
            assert_eq!(world.stacks[0].amount, tuning.output_per_hour(output) * 0.8);
        }
    }

    #[test]
    fn non_producing_work_does_not_manufacture_resources() {
        let tuning = Tuning::default();
        let mut world = new_world();
        world.colonists[0].work = WorkType::None;
        let before = world.resources.clone();

        step_work(&mut world, 0, &tuning, 1.0);

        assert_eq!(world.resources, before);
        assert!(world.stacks.is_empty());
    }

    #[test]
    fn unassigned_colonists_do_not_work_or_produce() {
        let t = Tuning::default();
        let mut w = new_world();
        for colonist in &mut w.colonists {
            colonist.work = WorkType::None;
        }
        let food = w.resources.food;

        step(&mut w, &t, 60.0);

        assert_eq!(w.resources.food, food);
        assert!(w.colonists.iter().all(|colonist| {
            colonist.goal == Goal::Nothing && colonist.activity == Activity::Idle
        }));
    }

    #[test]
    fn sleep_cap_wakes_a_still_critically_fatigued_colonist() {
        let t = Tuning {
            move_tiles_per_hour: 0.0,
            ..Tuning::default()
        };
        let mut w = new_world();
        w.colonists.truncate(1);
        let colonist = &mut w.colonists[0];
        colonist.x = 19;
        colonist.y = 2;
        colonist.target_x = 19;
        colonist.target_y = 2;
        colonist.activity = Activity::Sleeping;
        colonist.goal = Goal::Sleep;
        colonist.fatigue = 100.0;
        colonist.mood = 100.0;
        colonist.sleep_hours = t.max_sleep_hours - 60.0 / 3600.0;

        step(&mut w, &t, 60.0);
        let colonist = &w.colonists[0];
        assert_eq!(colonist.sleep_hours, t.max_sleep_hours);
        assert!(colonist.fatigue < 100.0);

        step(&mut w, &t, 60.0);
        let colonist = &w.colonists[0];
        assert_ne!(colonist.goal, Goal::Sleep);
        assert_ne!(colonist.activity, Activity::Sleeping);
    }

    #[test]
    fn disabled_target_retargets_an_enabled_facility_of_the_same_kind() {
        let t = Tuning {
            move_tiles_per_hour: 0.0,
            ..Tuning::default()
        };
        let mut w = new_world();
        w.colonists.truncate(1);
        for tile in &mut w.tiles {
            if tile.kind == TileKind::Dining {
                tile.enabled = tile.x == 3 && tile.y == 2;
            }
        }
        let colonist = &mut w.colonists[0];
        colonist.x = 0;
        colonist.y = 0;
        colonist.target_x = 2;
        colonist.target_y = 2;
        colonist.activity = Activity::Travelling;
        colonist.goal = Goal::Eat;
        colonist.hunger = 80.0;
        let food = w.resources.food;

        step(&mut w, &t, 60.0);

        let colonist = &w.colonists[0];
        assert_eq!((colonist.target_x, colonist.target_y), (3, 2));
        assert_eq!(colonist.activity, Activity::Travelling);
        assert_eq!(w.resources.food, food);
    }

    #[test]
    fn disabled_only_facility_falls_back_without_performing_the_activity() {
        let t = Tuning {
            move_tiles_per_hour: 0.0,
            ..Tuning::default()
        };
        let mut w = new_world();
        w.colonists.truncate(1);
        for tile in &mut w.tiles {
            if tile.kind == TileKind::Dining {
                tile.enabled = false;
            }
        }
        let colonist = &mut w.colonists[0];
        colonist.x = 2;
        colonist.y = 2;
        colonist.target_x = 2;
        colonist.target_y = 2;
        colonist.activity = Activity::Eating;
        colonist.goal = Goal::Eat;
        colonist.hunger = 80.0;
        let food = w.resources.food;

        step(&mut w, &t, 60.0);

        let colonist = &w.colonists[0];
        assert_eq!(colonist.goal, Goal::Work);
        assert_ne!(colonist.activity, Activity::Eating);
        assert_eq!(w.resources.food, food);
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
            Activity::Hauling,
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
        w.resources.food = 50.0;
        let mut min_food = w.resources.food;
        let mut max_food = w.resources.food;
        for _ in 0..(2.0 * SECONDS_PER_DAY / 60.0) as usize {
            step(&mut w, &t, 60.0);
            min_food = min_food.min(w.resources.food);
            max_food = max_food.max(w.resources.food);
        }
        assert!(max_food > 50.0, "food never increased ({max_food})");
        assert!(min_food < max_food, "food never decreased");
    }

    #[test]
    fn deliveries_have_no_storage_limit() {
        let t = Tuning::default();
        let mut w = new_world();
        w.colonists[0].x = 10;
        w.colonists[0].y = 10;
        for kind in RESOURCE_KINDS {
            let before = w.resources.amount(kind);
            for _ in 0..100 {
                w.colonists[0].carried_kind = kind;
                w.colonists[0].carried_amount = t.stack_size(kind);
                step_haul(&mut w, 0, &t);
                assert_eq!(w.colonists[0].carried_amount, 0.0);
            }
            assert_eq!(
                w.resources.amount(kind),
                before + 100.0 * t.stack_size(kind)
            );
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
            assert!(w.resources.food >= 0.0);
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
            total < ticks * w.colonists.len() / 10,
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
        w.resources.food = 0.0;
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
            w.resources.food = 5_000.0;
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
            let mut low = w.resources.food;
            for _ in 0..(days * SECONDS_PER_DAY / 60.0) as usize {
                step(&mut w, &t, 60.0);
                low = low.min(w.resources.food);
            }
            (w.resources.food, low)
        }

        let (healthy_food, healthy_low) = food_after(true, 30.0);
        let (broken_food, _) = food_after(false, 30.0);

        assert!(
            healthy_low > 0.0 && healthy_food > new_world().resources.food,
            "a working colony should keep its larder stocked, got {healthy_food}"
        );
        assert!(
            broken_food < 0.25 * new_world().resources.food,
            "a colony without recreation should drain its larder, got {broken_food}"
        );
    }

    #[test]
    fn dedicated_pairs_keep_a_healthy_colony_supplied() {
        let tuning = Tuning::default();
        let mut world = new_world();
        world.haul_policy = HaulPolicy::DedicatedHaulers;
        for _ in 0..(30.0 * SECONDS_PER_DAY / 60.0) as usize {
            step(&mut world, &tuning, 60.0);
            assert!(
                world.resources.food > 0.0,
                "dedicated farmers ran out of food"
            );
        }
        for kind in [ResourceKind::Wood, ResourceKind::Stone, ResourceKind::Meat] {
            assert!(world.resources.amount(kind) > 0.0);
        }
    }

    /// Colonists must not share one schedule, or the colony eats and sleeps as a
    /// single organism and the map shows eight markers moving as one.
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
        for policy in [HaulPolicy::SelfHaul, HaulPolicy::DedicatedHaulers] {
            let mut a = new_world();
            a.haul_policy = policy;
            let mut b = a.clone();
            for _ in 0..5000 {
                let ea = step(&mut a, &t, 60.0);
                let eb = step(&mut b, &t, 60.0);
                assert_eq!(ea, eb);
            }
            assert_eq!(a, b);
        }
    }

    #[test]
    fn large_step_matches_repeated_bounded_steps() {
        let t = Tuning::default();
        let mut actual = new_world();
        let mut expected = actual.clone();
        let full_steps = 360;
        let remainder = 17.25;

        let actual_events = step(
            &mut actual,
            &t,
            full_steps as f64 * MAX_STEP_SECONDS + remainder,
        );
        let mut expected_events = Vec::new();
        for _ in 0..full_steps {
            expected_events.extend(step(&mut expected, &t, MAX_STEP_SECONDS));
        }
        expected_events.extend(step(&mut expected, &t, remainder));

        assert!(!actual_events.is_empty());
        assert_eq!(actual_events, expected_events);
        assert_eq!(actual, expected);
    }

    #[test]
    fn large_step_advances_time_through_remainder() {
        let t = Tuning::default();
        let mut w = new_world();
        let start = w.game_seconds;

        step(&mut w, &t, 2.0 * MAX_STEP_SECONDS + 12.5);

        assert_eq!(w.game_seconds, start + 132.5);
    }

    #[test]
    fn invalid_step_durations_are_ignored() {
        let t = Tuning::default();
        let initial = new_world();

        for dt in [0.0, -1.0, f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            let mut w = initial.clone();
            assert!(step(&mut w, &t, dt).is_empty());
            assert_eq!(w, initial);
        }
    }
}
