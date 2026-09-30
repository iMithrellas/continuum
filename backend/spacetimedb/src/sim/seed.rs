use super::{
    default_work_orders, Colonist, HaulPolicy, MealPolicy, Resources, Tile, TileKind, WorkType,
    World, GRID_H, GRID_W,
};

/// Fixed layout with central storage and forest shared by logging and hunting.
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
                z: 0,
                width: 1,
                depth: 1,
                clearance_height: 4,
            });
            id += 1;
        }
    }
    tiles
}

fn in_rect(x: i32, y: i32, x0: i32, y0: i32, x1: i32, y1: i32) -> bool {
    x >= x0 && x <= x1 && y >= y0 && y <= y1
}

/// Two colonists per producing work type, with staggered starting needs.
pub fn default_colonists() -> Vec<Colonist> {
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
                colonist.assignment.work = work;
                colonist.needs.hunger = hunger;
                colonist.needs.fatigue = fatigue;
                colonist.needs.recreation = recreation;
                colonist
            },
        )
        .collect()
}

/// Historical flat simulation fixture/layout. Persistence explicitly installs
/// real geometry on fresh seed and on every live load (including migrations).
pub fn new_world() -> World {
    let tiles = default_tiles();
    World {
        navigation: Default::default(),
        geometry: None,
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
        game_seconds: 8.0 * 3600.0,
        mood_ema: 80.0,
        productivity_ema: 90.0,
    }
}
