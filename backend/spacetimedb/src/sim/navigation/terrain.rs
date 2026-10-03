//! Immutable authoritative-query snapshot shared by every body and actor search.
//! No chunk decoding or volume-sized clearance array: missing material stays blocked.
use crate::sim::geometry::{Body, Cell, Geometry};
use std::rc::Rc;

#[derive(Clone, Debug)]
pub(super) struct Terrain(pub Rc<Geometry>, #[cfg(test)] pub Option<PlaneFixture>);

/// Authored-column fixture without a dense voxel allocation.
#[cfg(test)]
#[derive(Clone, Debug, Default)]
pub(super) struct PlaneFixture {
    pub gaps: Vec<(i32, i32, i32, i32)>,
    pub use_material_geometry: bool,
    pub forbidden_edges: Vec<(Cell, Cell)>,
    pub terrace_every: Option<i32>,
}

impl Terrain {
    pub fn new(g: Rc<Geometry>) -> Self {
        #[cfg(test)]
        {
            Self(g, None)
        }
        #[cfg(not(test))]
        {
            Self(g)
        }
    }
    pub fn supported(&self, p: Cell, body: Body) -> bool {
        #[cfg(test)]
        if let Some(plane) = &self.1 {
            if plane.use_material_geometry {
                return self.0.supported(p, body);
            }
            let floor = |x: i32, y: i32| plane.terrace_every.map_or(0, |n| ((x + y) / n).min(12));
            return p.2 == floor(p.0, p.1)
                && body.width > 0
                && body.depth > 0
                && body.height > 0
                && self.0.contains(p)
                && self.0.contains(Cell(
                    p.0 + i32::from(body.width) - 1,
                    p.1 + i32::from(body.depth) - 1,
                    p.2 + i32::from(body.height) - 1,
                ))
                && (0..i32::from(body.width)).all(|dx| {
                    (0..i32::from(body.depth)).all(|dy| {
                        floor(p.0 + dx, p.1 + dy) == p.2
                            && !plane.gaps.iter().any(|&(x0, y0, x1, y1)| {
                                (x0..=x1).contains(&(p.0 + dx)) && (y0..=y1).contains(&(p.1 + dy))
                            })
                    })
                });
        }
        self.0.supported(p, body)
    }

    pub fn adjacent(&self, a: Cell, b: Cell, body: Body) -> bool {
        #[cfg(test)]
        if let Some(plane) = &self.1 {
            if plane.forbidden_edges.contains(&(a, b)) {
                return false;
            }
            if plane.use_material_geometry {
                return self.0.can_step(a, b, body);
            }
            return self.supported(a, body)
                && self.supported(b, body)
                && (a.0 - b.0).abs() + (a.1 - b.1).abs() == 1
                && (a.2 - b.2).abs() <= i32::from(body.step);
        }
        self.0.can_step(a, b, body)
    }

    pub fn neighbors(&self, p: Cell, body: Body) -> Vec<Cell> {
        let mut neighbors = Vec::new();
        let step = i32::from(body.step).min(self.0.max_z - self.0.min_z);
        // Cardinal order is the canonical BFS tie-breaker.
        for (dx, dy) in [(1, 0), (0, 1), (-1, 0), (0, -1)] {
            for dz in -step..=step {
                let q = Cell(p.0 + dx, p.1 + dy, p.2 + dz);
                if self.adjacent(p, q, body) {
                    neighbors.push(q);
                }
            }
        }
        neighbors
    }
}
