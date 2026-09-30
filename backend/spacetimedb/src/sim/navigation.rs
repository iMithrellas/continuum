//! Bounded derived navigation cache. It never owns authoritative terrain.
//! Graphs contain only supported body positions; actor BFS and routes are reused
//! within a valid material snapshot and discarded on EVERY actual voxel write.
use super::geometry::{Body, Cell, Geometry};
use super::World;
use std::collections::{BTreeMap, VecDeque};
use std::rc::Rc;

pub const MAX_CACHED_BODIES: usize = 8;
pub const MAX_CACHED_ACTORS: usize = 32;
const UNREACHED: u32 = u32::MAX;

#[derive(Clone, Debug)]
struct Graph {
    width: i32,
    height: i32,
    min_z: i32,
    max_z: i32,
    at: Vec<u32>,
    cells: Vec<Cell>,
    offsets: Vec<usize>,
    edges: Vec<usize>,
}
impl Graph {
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
    fn node(&self, p: Cell) -> Option<usize> {
        let n = self.at[self.offset(p)?];
        (n != UNREACHED).then_some(n as usize)
    }
    fn build(g: &Geometry, body: Body) -> Self {
        let mut graph = Self {
            width: g.width,
            height: g.height,
            min_z: g.min_z,
            max_z: g.max_z,
            at: vec![UNREACHED; (g.width * g.height * (g.max_z - g.min_z + 1)) as usize],
            cells: Vec::new(),
            offsets: Vec::new(),
            edges: Vec::new(),
        };
        for z in g.min_z + 1..=g.max_z {
            for y in 0..g.height {
                for x in 0..g.width {
                    let p = Cell(x, y, z);
                    if g.supported(p, body) {
                        let offset = graph.offset(p).unwrap();
                        graph.at[offset] = graph.cells.len() as u32;
                        graph.cells.push(p);
                    }
                }
            }
        }
        for &p in &graph.cells {
            graph.offsets.push(graph.edges.len());
            let step = i32::from(body.step).min(g.max_z - g.min_z);
            for (dx, dy) in [(1, 0), (0, 1), (-1, 0), (0, -1)] {
                for dz in -step..=step {
                    let q = Cell(p.0 + dx, p.1 + dy, p.2 + dz);
                    if let Some(n) = graph.node(q) {
                        if g.can_step(p, q, body) {
                            graph.edges.push(n);
                        }
                    }
                }
            }
        }
        graph.offsets.push(graph.edges.len());
        graph
    }
    fn adjacent(&self, a: Cell, b: Cell) -> bool {
        let (Some(a), Some(b)) = (self.node(a), self.node(b)) else {
            return false;
        };
        self.edges[self.offsets[a]..self.offsets[a + 1]].contains(&b)
    }
}

#[derive(Clone, Debug)]
pub struct Reachability {
    graph: Rc<Graph>,
    start: Cell,
    distances: Vec<u32>,
    parents: Vec<usize>,
    first: Vec<usize>,
}
impl Reachability {
    fn build(graph: Rc<Graph>, start: Cell) -> Self {
        let count = graph.cells.len();
        let mut s = Self {
            graph,
            start,
            distances: vec![UNREACHED; count],
            parents: vec![usize::MAX; count],
            first: vec![usize::MAX; count],
        };
        let Some(root) = s.graph.node(start) else {
            return s;
        };
        let mut queue = VecDeque::from([root]);
        s.distances[root] = 0;
        s.parents[root] = root;
        s.first[root] = root;
        while let Some(n) = queue.pop_front() {
            for &q in &s.graph.edges[s.graph.offsets[n]..s.graph.offsets[n + 1]] {
                if s.distances[q] == UNREACHED {
                    s.distances[q] = s.distances[n] + 1;
                    s.parents[q] = n;
                    s.first[q] = if n == root { q } else { s.first[n] };
                    queue.push_back(q);
                }
            }
        }
        s
    }
    pub fn get(&self, p: &Cell) -> Option<(u32, Cell)> {
        let n = self.graph.node(*p)?;
        (self.distances[n] != UNREACHED)
            .then(|| (self.distances[n], self.graph.cells[self.first[n]]))
    }
    pub fn contains_key(&self, p: &Cell) -> bool {
        self.get(p).is_some()
    }
    pub fn distance(&self, p: Cell) -> Option<u32> {
        self.get(&p).map(|(d, _)| d)
    }
    fn route(&self, p: Cell) -> Option<VecDeque<Cell>> {
        let mut n = self.graph.node(p)?;
        if self.distances[n] == UNREACHED {
            return None;
        }
        let mut path = VecDeque::new();
        loop {
            path.push_front(self.graph.cells[n]);
            if self.parents[n] == n {
                break;
            }
            n = self.parents[n];
        }
        Some(path)
    }
    /// Preserve a legitimate saved next hop, including equally short alternate
    /// routes. The temporary alternate BFS is not retained by coordinate key.
    pub fn serves(&self, saved: Cell, target: Cell) -> bool {
        let Some((distance, canonical)) = self.get(&target) else {
            return false;
        };
        if saved == canonical {
            return true;
        }
        if !self.graph.adjacent(self.start, saved) {
            return false;
        }
        Self::build(self.graph.clone(), saved)
            .distance(target)
            .is_some_and(|d| d + 1 == distance)
    }
}

#[derive(Clone, Debug)]
struct ActorSearch {
    body: Body,
    search: Rc<Reachability>,
}
#[derive(Clone, Debug)]
struct Route {
    body: Body,
    target: Cell,
    path: VecDeque<Cell>,
}

#[derive(Clone, Debug, Default)]
pub struct Navigation {
    stamp: Option<(i32, i32, i32, i32, u64)>,
    graphs: BTreeMap<Body, Rc<Graph>>,
    actors: BTreeMap<u64, ActorSearch>,
    routes: BTreeMap<u64, Route>,
    pub graph_builds: u64,
    pub searches: u64,
    pub route_builds: u64,
}
/// Derived cache population and eviction do not participate in world equality.
impl PartialEq for Navigation {
    fn eq(&self, _: &Self) -> bool {
        true
    }
}
impl Navigation {
    fn validate(&mut self, g: &Geometry) {
        let stamp = (g.width, g.height, g.min_z, g.max_z, g.nav_epoch);
        if self.stamp != Some(stamp) {
            self.graphs.clear();
            self.actors.clear();
            self.routes.clear();
            self.stamp = Some(stamp);
        }
    }
    pub fn reachable(
        &mut self,
        g: &Geometry,
        id: u64,
        start: Cell,
        body: Body,
    ) -> Rc<Reachability> {
        self.validate(g);
        if let Some(a) = self.actors.get(&id) {
            if a.body == body && a.search.start == start {
                return a.search.clone();
            }
        }
        let graph = if let Some(graph) = self.graphs.get(&body) {
            graph.clone()
        } else {
            let graph = Rc::new(Graph::build(g, body));
            if self.graphs.len() >= MAX_CACHED_BODIES {
                self.graphs.clear();
                self.actors.clear();
                self.routes.clear();
            }
            self.graphs.insert(body, graph.clone());
            self.graph_builds += 1;
            graph
        };
        let search = Rc::new(Reachability::build(graph, start));
        self.searches += 1;
        if self.actors.len() >= MAX_CACHED_ACTORS && !self.actors.contains_key(&id) {
            let old = *self.actors.first_key_value().unwrap().0;
            self.actors.remove(&old);
            self.routes.remove(&old);
        }
        self.actors.insert(
            id,
            ActorSearch {
                body,
                search: search.clone(),
            },
        );
        search
    }
    pub fn route(
        &mut self,
        g: &Geometry,
        id: u64,
        start: Cell,
        body: Body,
        target: Cell,
        saved: Cell,
    ) -> VecDeque<Cell> {
        self.validate(g);
        if let Some(r) = self.routes.get(&id) {
            if r.body == body && r.target == target && r.path.front() == Some(&start) {
                return r.path.clone();
            }
        }
        let reached = self.reachable(g, id, start, body);
        let mut path = reached.route(target).unwrap_or_default();
        if path.len() > 1 && path[1] != saved && reached.serves(saved, target) {
            path = Reachability::build(reached.graph.clone(), saved)
                .route(target)
                .unwrap();
            path.push_front(start);
        }
        self.route_builds += 1;
        self.routes.insert(
            id,
            Route {
                body,
                target,
                path: path.clone(),
            },
        );
        path
    }
    pub fn consume_route(&mut self, id: u64, count: usize) {
        if let Some(r) = self.routes.get_mut(&id) {
            for _ in 0..count {
                r.path.pop_front();
            }
        }
    }
    pub fn cached_counts(&self) -> (usize, usize, usize) {
        (self.graphs.len(), self.actors.len(), self.routes.len())
    }
}

impl World {
    pub fn actor_reachability(&self, index: usize) -> Rc<Reachability> {
        let c = &self.colonists[index];
        self.navigation.borrow_mut().reachable(
            self.geometry.as_ref().expect("live navigation geometry"),
            c.id,
            self.actor_cell(index),
            c.spatial.body,
        )
    }
}

#[cfg(test)]
mod tests;
