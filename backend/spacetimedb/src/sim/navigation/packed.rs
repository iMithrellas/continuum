//! Exact oversized-query fallback. Parent bytes are allocated only for visited
//! 32x32 XY/z-plane pages; the wave-ordered frontier contains packed u32 addresses.
//! No adjacency or per-cell tree records are retained after this query.
use super::ida;
use super::terrain::Terrain;
use crate::sim::geometry::{Body, Cell, Geometry};
use std::collections::{BTreeMap, BTreeSet, VecDeque};

const EDGE: i32 = 32;
const AREA: usize = 1024;
const REVERSE_LIMIT: usize = 1024;
const DIRECTIONS: [(i32, i32); 4] = [(1, 0), (0, 1), (-1, 0), (0, -1)];

pub(super) fn fits(g: &Geometry) -> bool {
    let volume = i64::from(g.width)
        .checked_mul(i64::from(g.height))
        .and_then(|plane| plane.checked_mul(i64::from(g.max_z) - i64::from(g.min_z) + 1));
    g.width > 0 && g.height > 0 && volume.is_some_and(|v| v > 0 && v <= i64::from(u32::MAX))
}

#[derive(Default, Debug)]
pub(super) struct Work {
    pub expanded: usize,
    pub discovered: usize,
    pub pages: usize,
    pub page_bytes: usize,
    pub frontier_capacity: usize,
    pub reverse_visits: usize,
    pub ida: ida::Work,
}

enum ResultPath {
    Accelerated(VecDeque<Cell>),
    Packed(Parents),
}
impl ResultPath {
    fn path(self, target: Cell) -> VecDeque<Cell> {
        match self {
            Self::Accelerated(path) => path,
            Self::Packed(p) => p.path(target),
        }
    }
    fn distance_first(self, target: Cell) -> (u32, Cell) {
        match self {
            Self::Accelerated(path) => ((path.len() - 1) as u32, *path.get(1).unwrap_or(&target)),
            Self::Packed(p) => p.distance_first(target),
        }
    }
}

enum Page {
    Byte(Box<[u8; AREA]>),
    Wide(Box<[u32; AREA]>),
}
impl Page {
    fn get(&self, at: usize) -> u32 {
        match self {
            Self::Byte(p) => u32::from(p[at]),
            Self::Wide(p) => p[at],
        }
    }
    fn set(&mut self, at: usize, value: u32) {
        match self {
            Self::Byte(p) => p[at] = value as u8,
            Self::Wide(p) => p[at] = value,
        }
    }
}

struct Parents {
    pages: BTreeMap<Cell, Page>,
    step: i32,
}

/// FIFO blocks are freed as consumed. Unlike two reusable Vec waves, a wide
/// wave cannot leave two power-of-two high-water allocations resident forever.
#[derive(Default)]
struct Frontier {
    blocks: VecDeque<Box<[u32; AREA]>>,
    head: usize,
    tail: usize,
    len: usize,
}
impl Frontier {
    fn push(&mut self, at: u32) {
        if self.blocks.is_empty() || self.tail == AREA {
            self.blocks.push_back(Box::new([0; AREA]));
            self.tail = 0;
        }
        self.blocks.back_mut().unwrap()[self.tail] = at;
        self.tail += 1;
        self.len += 1;
    }
    fn pop(&mut self) -> Option<u32> {
        if self.len == 0 {
            return None;
        }
        let at = self.blocks.front()?[self.head];
        self.head += 1;
        self.len -= 1;
        if self.len == 0 {
            // Reuse the last block to avoid a 4 KiB allocation per corridor hop.
            self.head = 0;
            self.tail = 0;
        } else if self.head == AREA {
            self.blocks.pop_front();
            self.head = 0;
        }
        Some(at)
    }
    fn capacity(&self) -> usize {
        self.blocks.len() * AREA
    }
}
impl Parents {
    fn address(p: Cell) -> (Cell, usize) {
        (
            Cell(p.0 / EDGE, p.1 / EDGE, p.2),
            (p.0 % EDGE + EDGE * (p.1 % EDGE)) as usize,
        )
    }
    fn get(&self, p: Cell) -> u32 {
        let (key, at) = Self::address(p);
        self.pages.get(&key).map_or(0, |page| page.get(at))
    }
    fn set(&mut self, p: Cell, code: u32) {
        let (key, at) = Self::address(p);
        let byte = self.step <= 31;
        self.pages
            .entry(key)
            .or_insert_with(|| {
                if byte {
                    Page::Byte(Box::new([0; AREA]))
                } else {
                    Page::Wide(Box::new([0; AREA]))
                }
            })
            .set(at, code);
    }
    fn parent(&self, p: Cell) -> Cell {
        let code = self.get(p) - 2;
        let span = (self.step * 2 + 1) as u32;
        let (dx, dy) = DIRECTIONS[(code / span) as usize];
        let dz = (code % span) as i32 - self.step;
        Cell(p.0 - dx, p.1 - dy, p.2 - dz)
    }
    fn path(&self, mut p: Cell) -> VecDeque<Cell> {
        let mut path = VecDeque::new();
        loop {
            path.push_front(p);
            if self.get(p) == 1 {
                break;
            }
            p = self.parent(p);
        }
        path
    }
    fn distance_first(&self, mut p: Cell) -> (u32, Cell) {
        let mut distance = 0;
        let mut first = p;
        while self.get(p) != 1 {
            first = p;
            p = self.parent(p);
            distance += 1;
        }
        (distance, first)
    }
}

fn address(g: &Geometry, p: Cell) -> u32 {
    (i64::from(p.0)
        + i64::from(g.width) * (i64::from(p.1) + i64::from(g.height) * i64::from(p.2 - g.min_z)))
        as u32
}
fn cell(g: &Geometry, at: u32) -> Cell {
    let x = at % g.width as u32;
    let yz = at / g.width as u32;
    Cell(
        x as i32,
        (yz % g.height as u32) as i32,
        (yz / g.height as u32) as i32 + g.min_z,
    )
}

/// A bounded reverse flood can PROVE unreachable only when exhausted without
/// finding start. Hitting its work limit is inconclusive, never a rejection.
/// Test q -> p, not p -> q, so the proof is valid even for directional geometry.
fn reverse_reject(t: &Terrain, body: Body, start: Cell, target: Cell, work: &mut Work) -> bool {
    let mut seen = BTreeSet::from([target]);
    let mut queue = VecDeque::from([target]);
    let step = i32::from(body.step).min(t.0.max_z - t.0.min_z);
    while let Some(p) = queue.pop_front() {
        if p == start {
            work.reverse_visits = seen.len();
            return false;
        }
        for (dx, dy) in DIRECTIONS {
            for dz in -step..=step {
                let q = Cell(p.0 + dx, p.1 + dy, p.2 + dz);
                if t.0.contains(q) && !seen.contains(&q) && t.adjacent(q, p, body) {
                    if seen.len() == REVERSE_LIMIT {
                        work.reverse_visits = seen.len();
                        return false;
                    }
                    seen.insert(q);
                    queue.push_back(q);
                }
            }
        }
    }
    work.reverse_visits = seen.len();
    true
}

pub(super) fn query(t: &Terrain, body: Body, start: Cell, target: Cell) -> Option<VecDeque<Cell>> {
    query_with_work(t, body, start, target).0
}

pub(super) fn get(t: &Terrain, body: Body, start: Cell, target: Cell) -> Option<(u32, Cell)> {
    search_with_work(t, body, start, target, ida::Budget::default())
        .0
        .map(|parents| parents.distance_first(target))
}

pub(super) fn query_with_work(
    t: &Terrain,
    body: Body,
    start: Cell,
    target: Cell,
) -> (Option<VecDeque<Cell>>, Work) {
    let (parents, work) = search_with_work(t, body, start, target, ida::Budget::default());
    (parents.map(|p| p.path(target)), work)
}

#[cfg(test)]
pub(super) fn query_with_budget(
    t: &Terrain,
    body: Body,
    start: Cell,
    target: Cell,
    budget: ida::Budget,
) -> (Option<VecDeque<Cell>>, Work) {
    let (result, work) = search_with_work(t, body, start, target, budget);
    (result.map(|p| p.path(target)), work)
}

fn search_with_work(
    t: &Terrain,
    body: Body,
    start: Cell,
    target: Cell,
    budget: ida::Budget,
) -> (Option<ResultPath>, Work) {
    let mut work = Work::default();
    if !t.supported(start, body) || !t.supported(target, body) {
        return (None, work);
    }
    if start == target {
        let mut parents = Parents {
            pages: BTreeMap::new(),
            step: 0,
        };
        parents.set(start, 1);
        return (Some(ResultPath::Packed(parents)), work);
    }
    if reverse_reject(t, body, start, target, &mut work) {
        return (None, work);
    }
    let (path, ida_work) = ida::try_path(t, body, start, target, budget);
    work.ida = ida_work;
    if let Some(path) = path {
        return (Some(ResultPath::Accelerated(path)), work);
    }
    let g = &t.0;
    assert!(
        fits(g),
        "packed query must be selected only for representable bounds"
    );
    let step = i32::from(body.step).min(g.max_z - g.min_z);
    let mut parents = Parents {
        pages: BTreeMap::new(),
        step,
    };
    parents.set(start, 1);
    work.discovered = 1;
    let mut frontier = Frontier::default();
    frontier.push(address(g, start));
    work.frontier_capacity = frontier.capacity();
    let mut found = false;
    'bfs: while let Some(at) = frontier.pop() {
        let p = cell(g, at);
        work.expanded += 1;
        for (direction, (dx, dy)) in DIRECTIONS.into_iter().enumerate() {
            for dz in -step..=step {
                let q = Cell(p.0 + dx, p.1 + dy, p.2 + dz);
                if g.contains(q) && parents.get(q) == 0 && t.adjacent(p, q, body) {
                    let code = 2 + direction as u32 * (step * 2 + 1) as u32 + (dz + step) as u32;
                    parents.set(q, code);
                    work.discovered += 1;
                    if q == target {
                        found = true;
                        break 'bfs;
                    }
                    frontier.push(address(g, q));
                    work.frontier_capacity = work.frontier_capacity.max(frontier.capacity());
                }
            }
        }
    }
    work.pages = parents.pages.len();
    work.page_bytes = work.pages * AREA * if step <= 31 { 1 } else { 4 };
    (found.then_some(ResultPath::Packed(parents)), work)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frontier_blocks_preserve_fifo_across_growth_consumption_and_reuse() {
        let mut q = Frontier::default();
        for n in 0..5000 {
            q.push(n);
        }
        for n in 0..3000 {
            assert_eq!(q.pop(), Some(n));
        }
        assert!(q.capacity() < 4096);
        for n in 5000..9000 {
            q.push(n);
        }
        for n in 3000..9000 {
            assert_eq!(q.pop(), Some(n));
        }
        assert_eq!(q.pop(), None);
        assert_eq!(q.capacity(), AREA);
        for n in 0..3000 {
            q.push(n);
            assert_eq!(q.pop(), Some(n));
            assert_eq!(q.pop(), None);
        }
        assert_eq!(q.capacity(), AREA);
    }
}
