use super::{
    Colonist, Goal, HaulPolicy, MealPolicy, ResourceKind, TileKind, Tuning, WorkOrder, WorkType,
    SECONDS_PER_DAY,
};

#[derive(Clone, Debug, PartialEq)]
pub struct Tile {
    pub id: u32,
    pub x: i32,
    pub y: i32,
    pub kind: TileKind,
    pub enabled: bool,
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
    // This is a persisted encoding, not the current resource-list length.
    // An added resource needs an explicit collision-free extension/migration.
    tile_id as u64 * 4 + kind.index()
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

    pub(super) fn add(&mut self, kind: ResourceKind, amount: f32) {
        match kind {
            ResourceKind::Food => self.food += amount,
            ResourceKind::Wood => self.wood += amount,
            ResourceKind::Stone => self.stone += amount,
            ResourceKind::Meat => self.meat += amount,
        }
    }

    pub(super) fn take(&mut self, kind: ResourceKind, amount: f32) -> f32 {
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
    pub(super) fn colonist_order(&self) -> Vec<usize> {
        let mut order: Vec<_> = (0..self.colonists.len()).collect();
        order.sort_unstable_by_key(|&index| self.colonists[index].id);
        assert!(
            order
                .windows(2)
                .all(|pair| self.colonists[pair[0]].id != self.colonists[pair[1]].id),
            "colonist IDs must be unique"
        );
        order
    }

    fn average_colonists(&self, value: impl Fn(&Colonist) -> f32) -> f32 {
        // Float accumulation order must not depend on component storage order.
        average(
            self.colonist_order()
                .into_iter()
                .map(|index| value(&self.colonists[index])),
        )
    }

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
    pub(super) fn nearest_enabled_tile(&self, kind: TileKind, x: i32, y: i32) -> Option<&Tile> {
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
    pub(super) fn supply_ready(&self, tile: &Tile, work: WorkType, tuning: &Tuning) -> bool {
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
                    colonist.assignment.haul_role.produces()
                        && colonist
                            .assignment
                            .work
                            .definition()
                            .is_some_and(|work| work.output == kind)
                        && colonist.task.goal == Goal::Work
                        && colonist.wellbeing.productivity > 0.0
                        && colonist.movement.target.x == tile.x
                        && colonist.movement.target.y == tile.y
                }))
    }

    /// Rank eligible piles by order priority, distance, then id. Disabling
    /// production does not prevent collecting goods already made.
    pub(super) fn best_supply_tile(
        &self,
        work: WorkType,
        tuning: &Tuning,
        x: i32,
        y: i32,
    ) -> Option<&Tile> {
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
    pub(super) fn add_to_stack(&mut self, tile: &Tile, kind: ResourceKind, amount: f32) {
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
    pub(super) fn take_from_stack(&mut self, tile_id: u32, kind: ResourceKind, amount: f32) -> f32 {
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
        self.average_colonists(|colonist| colonist.wellbeing.mood)
    }

    pub fn avg_productivity(&self) -> f32 {
        self.average_colonists(|colonist| colonist.wellbeing.productivity)
    }

    pub fn avg_fatigue(&self) -> f32 {
        self.average_colonists(|colonist| colonist.needs.fatigue)
    }

    pub fn avg_recreation(&self) -> f32 {
        self.average_colonists(|colonist| colonist.needs.recreation)
    }
}

pub(super) fn average(values: impl Iterator<Item = f32>) -> f32 {
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
