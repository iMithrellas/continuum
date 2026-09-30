//! Compact derived clearance snapshot, discarded after building a body graph.
//! Missing chunks stay unknown (neither clear nor supporting), never implicit air.
use crate::sim::geometry::{Body, Cell, Geometry, AIR, EDGE};

const UNKNOWN: u8 = 0;
const EMPTY: u8 = 1;
const SOLID: u8 = 2;

pub(super) struct Terrain {
    width: i32,
    height: i32,
    min_z: i32,
    max_z: i32,
    cells: Vec<u8>,
}

impl Terrain {
    pub fn build(g: &Geometry) -> Self {
        let mut t = Self {
            width: g.width,
            height: g.height,
            min_z: g.min_z,
            max_z: g.max_z,
            cells: vec![UNKNOWN; (g.width * g.height * (g.max_z - g.min_z + 1)) as usize],
        };
        for (&key, chunk) in &g.chunks {
            for z in 0..EDGE {
                let wz = key.2 * EDGE + z;
                if wz < t.min_z || wz > t.max_z {
                    continue;
                }
                for y in 0..EDGE {
                    let wy = key.1 * EDGE + y;
                    if wy < 0 || wy >= t.height {
                        continue;
                    }
                    for x in 0..EDGE {
                        let wx = key.0 * EDGE + x;
                        if wx < 0 || wx >= t.width {
                            continue;
                        }
                        if let Some(&m) = chunk.materials.get((x + EDGE * (y + EDGE * z)) as usize)
                        {
                            let offset = t.offset(Cell(wx, wy, wz)).unwrap();
                            t.cells[offset] = if m == AIR { EMPTY } else { SOLID };
                        }
                    }
                }
            }
        }
        t
    }

    fn offset(&self, p: Cell) -> Option<usize> {
        if p.0 < 0
            || p.0 >= self.width
            || p.1 < 0
            || p.1 >= self.height
            || p.2 < self.min_z
            || p.2 > self.max_z
        {
            return None;
        }
        Some((p.0 + self.width * (p.1 + self.height * (p.2 - self.min_z))) as usize)
    }

    fn clear(&self, p: Cell, body: Body) -> bool {
        if body.width == 0 || body.depth == 0 || body.height == 0 {
            return false;
        }
        let (Some(x), Some(y), Some(z)) = (
            p.0.checked_add(i32::from(body.width) - 1),
            p.1.checked_add(i32::from(body.depth) - 1),
            p.2.checked_add(i32::from(body.height) - 1),
        ) else {
            return false;
        };
        let (Some(base), Some(_)) = (self.offset(p), self.offset(Cell(x, y, z))) else {
            return false;
        };
        (0..usize::from(body.height)).all(|dz| {
            (0..usize::from(body.depth)).all(|dy| {
                let offset = base + self.width as usize * (dy + self.height as usize * dz);
                self.cells[offset..offset + usize::from(body.width)]
                    .iter()
                    .all(|&m| m == EMPTY)
            })
        })
    }

    /// Enumerate only solid-to-air transitions before full footprint clearance.
    /// A supported body must stand immediately above solid at its base corner.
    pub fn positions(&self, body: Body) -> Vec<Cell> {
        let mut positions = Vec::new();
        let plane = (self.width * self.height) as usize;
        for z in self.min_z + 1..=self.max_z {
            let base = plane * (z - self.min_z) as usize;
            for y in 0..self.height {
                for x in 0..self.width {
                    let offset = base + (x + self.width * y) as usize;
                    let p = Cell(x, y, z);
                    if self.cells[offset] != EMPTY
                        || self.cells[offset - plane] != SOLID
                        || !self.clear(p, body)
                    {
                        continue;
                    }
                    let floor = offset - plane;
                    if (0..usize::from(body.depth)).all(|dy| {
                        let at = floor + self.width as usize * dy;
                        self.cells[at..at + usize::from(body.width)]
                            .iter()
                            .all(|&m| m == SOLID)
                    }) {
                        positions.push(p);
                    }
                }
            }
        }
        positions
    }

    /// Both endpoints already have full support/clearance as graph nodes. At
    /// equal height that proves the complete cardinal sweep without re-querying.
    pub fn step_clear(&self, a: Cell, b: Cell, body: Body) -> bool {
        if a.2 == b.2 {
            return true;
        }
        let high = a.2.max(b.2);
        let sweep = if b.2 >= a.2 { a } else { b };
        (a.2.min(b.2)..=high).all(|z| self.clear(Cell(sweep.0, sweep.1, z), body))
            && self.clear(Cell(a.0, a.1, high), body)
            && self.clear(Cell(b.0, b.1, high), body)
    }
}
