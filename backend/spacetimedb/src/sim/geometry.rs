//! Authoritative half-metre material cells; navigation is a derived query.
use std::collections::{BTreeMap, BTreeSet, VecDeque};

pub const EDGE: i32 = 16;
pub const CELL_EDGE_METERS: f32 = 0.5;
pub const CELL_VOLUME_M3: f32 = 0.125;
pub const DEFAULT_EXCAVATION_HEIGHT: u16 = 6;
pub const AIR: u16 = 0;
pub const SOIL: u16 = 1;
pub const STONE: u16 = 2;
pub const DEFAULT_WORLD_WIDTH: i32 = 128;
pub const DEFAULT_WORLD_HEIGHT: i32 = 128;
pub const MAX_WORLD_EDGE: i32 = 256;

mod expansion;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Cell(pub i32, pub i32, pub i32);

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Body {
    pub width: u16,
    pub depth: u16,
    pub height: u16,
    pub step: u16,
}
impl Default for Body {
    fn default() -> Self {
        Self {
            width: 1,
            depth: 1,
            height: 4,
            step: 1,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Spatial {
    pub z: i32,
    pub target_z: i32,
    pub next: Cell,
    pub body: Body,
}
impl Default for Spatial {
    fn default() -> Self {
        Self {
            z: 0,
            target_z: 0,
            next: Cell(0, 0, 0),
            body: Body::default(),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Chunk {
    pub id: u64,
    pub materials: Vec<u16>,
    pub revision: u32,
}

#[derive(spacetimedb::SpacetimeType, Clone, Debug, PartialEq)]
pub struct MiningCell {
    pub x: i32,
    pub y: i32,
    pub z: i32,
    /// Original material; zero marks a completed job.
    pub material: u16,
    pub progress: f32,
}
impl MiningCell {
    pub fn cell(&self) -> Cell {
        Cell(self.x, self.y, self.z)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Designation {
    pub id: u64,
    pub x0: i32,
    pub y0: i32,
    pub x1: i32,
    pub y1: i32,
    pub bottom_z: i32,
    pub height: u16,
    pub priority: u8,
    pub enabled: bool,
    pub cells: Vec<MiningCell>,
}
impl Designation {
    pub fn completed(&self) -> u32 {
        self.cells.iter().filter(|c| c.material == AIR).count() as u32
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Geometry {
    pub width: i32,
    pub height: i32,
    pub min_z: i32,
    pub max_z: i32,
    pub chunks: BTreeMap<Cell, Chunk>,
    pub changed: BTreeSet<Cell>,
    pub designations: Vec<Designation>,
    /// Transaction-local invalidation, NOT the once-per-chunk public revision.
    pub(crate) nav_epoch: u64,
    pub dirty_jobs: BTreeSet<u64>,
    pub dirty_designations: BTreeSet<u64>,
}

pub fn chunk_address(c: Cell) -> (Cell, usize) {
    let Cell(x, y, z) = c;
    (
        Cell(x.div_euclid(EDGE), y.div_euclid(EDGE), z.div_euclid(EDGE)),
        (x.rem_euclid(EDGE) + EDGE * (y.rem_euclid(EDGE) + EDGE * z.rem_euclid(EDGE))) as usize,
    )
}

impl Geometry {
    /// Historical 24x24 additive migration, deliberately NOT the fresh default.
    /// Every old z=0 position retains solid support; upgrades never enlarge land.
    pub fn flat() -> Self {
        Self::flat_with_dimensions(super::GRID_W, super::GRID_H).unwrap()
    }

    /// Bounded physical geometry without operational/environment rows per cell.
    pub fn flat_with_dimensions(width: i32, height: i32) -> Result<Self, String> {
        expansion::validate_dimensions(width, height)?;
        let mut g = Self {
            width,
            height,
            min_z: -16,
            max_z: 15,
            chunks: BTreeMap::new(),
            changed: BTreeSet::new(),
            designations: Vec::new(),
            nav_epoch: 0,
            dirty_jobs: BTreeSet::new(),
            dirty_designations: BTreeSet::new(),
        };
        let mut id = 1;
        for cz in -1..=0 {
            for cy in 0..(height + EDGE - 1) / EDGE {
                for cx in 0..(width + EDGE - 1) / EDGE {
                    let key = Cell(cx, cy, cz);
                    g.chunks.insert(
                        key,
                        Chunk {
                            id,
                            materials: expansion::flat_chunk(key, width, height, g.min_z, g.max_z),
                            revision: u32::from(cz < 0),
                        },
                    );
                    id += 1;
                }
            }
        }
        Ok(g)
    }

    /// Fresh worlds get a finite six-cell hillside, away from seeded facilities.
    pub fn seeded() -> Self {
        let mut g = Self::flat_with_dimensions(DEFAULT_WORLD_WIDTH, DEFAULT_WORLD_HEIGHT).unwrap();
        for z in 0..6 {
            for y in 8..12 {
                for x in 22..24 {
                    g.set(Cell(x, y, z), STONE);
                }
            }
        }
        let d = g
            .designate(1, 22, 8, 23, 11, 0, DEFAULT_EXCAVATION_HEIGHT, 2)
            .unwrap();
        g.designations.push(d);
        g
    }

    pub fn contains(&self, c: Cell) -> bool {
        c.0 >= 0
            && c.0 < self.width
            && c.1 >= 0
            && c.1 < self.height
            && c.2 >= self.min_z
            && c.2 <= self.max_z
    }
    pub fn material(&self, c: Cell) -> Option<u16> {
        if !self.contains(c) {
            return None;
        }
        let (key, i) = chunk_address(c);
        self.chunks
            .get(&key)
            .and_then(|chunk| chunk.materials.get(i))
            .copied()
    }
    pub fn solid(&self, c: Cell) -> bool {
        self.material(c).is_some_and(|m| m != AIR)
    }
    pub fn set(&mut self, c: Cell, material: u16) -> bool {
        if !self.contains(c) {
            return false;
        }
        let (key, i) = chunk_address(c);
        let Some(chunk) = self.chunks.get_mut(&key) else {
            return false;
        };
        if chunk.materials[i] == material {
            return false;
        }
        chunk.materials[i] = material;
        self.nav_epoch = self
            .nav_epoch
            .checked_add(1)
            .expect("terrain mutation epoch exhausted");
        if self.changed.insert(key) {
            chunk.revision = chunk.revision.wrapping_add(1);
        }
        true
    }

    pub fn clear(&self, p: Cell, b: Body) -> bool {
        if b.width == 0 || b.depth == 0 || b.height == 0 {
            return false;
        }
        let Some(x1) = p.0.checked_add(i32::from(b.width) - 1) else {
            return false;
        };
        let Some(y1) = p.1.checked_add(i32::from(b.depth) - 1) else {
            return false;
        };
        let Some(z1) = p.2.checked_add(i32::from(b.height) - 1) else {
            return false;
        };
        if !self.contains(p) || !self.contains(Cell(x1, y1, z1)) {
            return false;
        }
        (0..i32::from(b.width)).all(|x| {
            (0..i32::from(b.depth)).all(|y| {
                (0..i32::from(b.height))
                    .all(|z| self.material(Cell(p.0 + x, p.1 + y, p.2 + z)) == Some(AIR))
            })
        })
    }
    pub fn supported(&self, p: Cell, b: Body) -> bool {
        self.clear(p, b)
            && (0..i32::from(b.width)).all(|x| {
                (0..i32::from(b.depth)).all(|y| self.solid(Cell(p.0 + x, p.1 + y, p.2 - 1)))
            })
    }

    /// Derived floor/wall/ceiling adjacency, never stored as operational tiles.
    pub fn surfaces(&self, p: Cell) -> [bool; 6] {
        [
            Cell(p.0, p.1, p.2 - 1),
            Cell(p.0, p.1, p.2 + 1),
            Cell(p.0 - 1, p.1, p.2),
            Cell(p.0 + 1, p.1, p.2),
            Cell(p.0, p.1 - 1, p.2),
            Cell(p.0, p.1 + 1, p.2),
        ]
        .map(|c| self.solid(c))
    }

    /// Lift before advancing up a step, advance before lowering down a step.
    /// Both endpoints of that horizontal sweep need clearance at the high base.
    pub fn can_step(&self, a: Cell, b: Cell, body: Body) -> bool {
        if !self.contains(a) || !self.contains(b) {
            return false;
        }
        if (a.0 - b.0).abs() + (a.1 - b.1).abs() != 1
            || (a.2 - b.2).abs() > i32::from(body.step)
            || !self.supported(a, body)
            || !self.supported(b, body)
        {
            return false;
        }
        let high = a.2.max(b.2);
        let sweep = if b.2 >= a.2 { a } else { b };
        (a.2.min(b.2)..=high).all(|z| self.clear(Cell(sweep.0, sweep.1, z), body))
            && self.clear(Cell(a.0, a.1, high), body)
            && self.clear(Cell(b.0, b.1, high), body)
    }

    /// Deterministic BFS. Values are (distance, first actual hop); no x-first guess.
    pub fn reachable(&self, start: Cell, body: Body) -> BTreeMap<Cell, (u32, Cell)> {
        let mut seen = BTreeMap::new();
        if !self.supported(start, body) {
            return seen;
        }
        seen.insert(start, (0, start));
        let mut queue = VecDeque::from([start]);
        while let Some(p) = queue.pop_front() {
            let (distance, first) = seen[&p];
            for (dx, dy) in [(1, 0), (0, 1), (-1, 0), (0, -1)] {
                for dz in -(i32::from(body.step).min(self.max_z - self.min_z))
                    ..=i32::from(body.step).min(self.max_z - self.min_z)
                {
                    let q = Cell(p.0 + dx, p.1 + dy, p.2 + dz);
                    if !seen.contains_key(&q) && self.contains(q) && self.can_step(p, q, body) {
                        seen.insert(q, (distance + 1, if distance == 0 { q } else { first }));
                        queue.push_back(q);
                    }
                }
            }
        }
        seen
    }

    #[allow(clippy::too_many_arguments)]
    pub fn designate(
        &self,
        id: u64,
        x0: i32,
        y0: i32,
        x1: i32,
        y1: i32,
        bottom_z: i32,
        height: u16,
        priority: u8,
    ) -> Result<Designation, String> {
        if height == 0 || !(1..=3).contains(&priority) {
            return Err("height must be positive and priority 1..=3".into());
        }
        let (x0, x1, y0, y1) = (x0.min(x1), x0.max(x1), y0.min(y1), y0.max(y1));
        let top = bottom_z
            .checked_add(i32::from(height) - 1)
            .ok_or("height overflow")?;
        if !self.contains(Cell(x0, y0, bottom_z)) || !self.contains(Cell(x1, y1, top)) {
            return Err("excavation outside world bounds".into());
        }
        let occupied: BTreeSet<_> = self
            .designations
            .iter()
            .flat_map(|d| d.cells.iter())
            .filter(|job| job.material != AIR)
            .map(MiningCell::cell)
            .collect();
        let mut cells = Vec::new();
        for z in (bottom_z..=top).rev() {
            for y in y0..=y1 {
                for x in x0..=x1 {
                    let c = Cell(x, y, z);
                    let material = self.material(c).unwrap();
                    if material != AIR {
                        if occupied.contains(&c) {
                            return Err("solid cell already designated".into());
                        }
                        cells.push(MiningCell {
                            x,
                            y,
                            z,
                            material,
                            progress: 0.0,
                        });
                    }
                }
            }
        }
        if cells.is_empty() {
            return Err("excavation contains no solid cells".into());
        }
        Ok(Designation {
            id,
            x0,
            y0,
            x1,
            y1,
            bottom_z,
            height,
            priority,
            enabled: true,
            cells,
        })
    }

    /// Work from an exposed cardinal face, within six cells above the feet,
    /// or open an adjacent floor one cell down to form a supported descent.
    /// Never mine through an intervening wall or from an unsupported air position.
    pub fn mine_reachable(&self, p: Cell, body: Body, c: Cell) -> bool {
        if !self.supported(p, body) || !self.solid(c) || c.2 < p.2 - 1 || c.2 >= p.2 + 6 {
            return false;
        }
        let near_x = c.0.clamp(p.0, p.0 + i32::from(body.width) - 1);
        let near_y = c.1.clamp(p.1, p.1 + i32::from(body.depth) - 1);
        if near_x == c.0 && near_y == c.1 && c.2 >= p.2 + i32::from(body.height) {
            return (p.2..c.2).all(|z| self.material(Cell(c.0, c.1, z)) == Some(AIR));
        }
        if (near_x - c.0).abs() + (near_y - c.1).abs() != 1 {
            return false;
        }
        if c.2 == p.2 - 1 {
            return self.material(Cell(c.0, c.1, p.2)) == Some(AIR);
        }
        (p.2..=c.2).all(|z| self.material(Cell(near_x, near_y, z)) == Some(AIR))
    }
}

#[cfg(test)]
mod tests;
