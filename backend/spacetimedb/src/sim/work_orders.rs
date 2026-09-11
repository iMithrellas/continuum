use super::{stack_id, Tile, WorkType, World};

/// Standing production permission for one job on one tile. Lower priorities win.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WorkOrder {
    pub id: u64,
    pub tile_id: u32,
    pub work: WorkType,
    pub priority: u8,
    pub enabled: bool,
}

impl WorkOrder {
    pub fn new(tile: &Tile, work: WorkType, priority: u8, enabled: bool) -> Result<Self, String> {
        let definition = work
            .definition()
            .ok_or("Work orders require a producing job")?;
        if tile.kind != definition.facility {
            return Err("Work order does not match the tile's facility".into());
        }
        if !(1..=3).contains(&priority) {
            return Err("Work order priority must be between 1 and 3".into());
        }
        Ok(Self {
            id: stack_id(tile.id, definition.output),
            tile_id: tile.id,
            work,
            priority,
            enabled,
        })
    }
}

pub fn default_work_orders(tiles: &[Tile]) -> Vec<WorkOrder> {
    let mut orders = Vec::new();
    for tile in tiles {
        for work in [
            WorkType::Farming,
            WorkType::Logging,
            WorkType::Mining,
            WorkType::Hunting,
        ] {
            if let Ok(order) = WorkOrder::new(tile, work, 2, true) {
                orders.push(order);
            }
        }
    }
    orders.sort_by_key(|order| order.id);
    orders
}

impl World {
    pub(super) fn active_work_order(&self, tile: &Tile, work: WorkType) -> Option<&WorkOrder> {
        let definition = work.definition()?;
        if !tile.enabled || tile.kind != definition.facility {
            return None;
        }
        self.work_orders
            .iter()
            .filter(|order| {
                order.enabled
                    && order.tile_id == tile.id
                    && order.work == work
                    && order.id == stack_id(tile.id, definition.output)
                    && (1..=3).contains(&order.priority)
            })
            .min_by_key(|order| (order.priority, order.id))
    }

    pub(super) fn best_work_tile(&self, work: WorkType, x: i32, y: i32) -> Option<&Tile> {
        self.tiles
            .iter()
            .filter_map(|tile| {
                self.active_work_order(tile, work)
                    .map(|order| (tile, order))
            })
            .min_by_key(|(tile, order)| {
                (
                    order.priority,
                    (tile.x - x).abs() + (tile.y - y).abs(),
                    order.id,
                )
            })
            .map(|(tile, _)| tile)
    }
}
