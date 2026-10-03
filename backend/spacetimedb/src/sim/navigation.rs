//! Sparse derived navigation cache. Its shared terrain snapshot is immutable.
//! Graphs discover only local supported positions; actor BFS and routes are reused
//! within a valid material snapshot and discarded on EVERY actual voxel write.
use super::geometry::{Body, Cell, Geometry};
use super::World;
use std::cell::RefCell;
use std::collections::{BTreeMap, VecDeque};
use std::rc::Rc;
mod ida;
mod packed;
mod terrain;

pub const MAX_CACHED_BODIES: usize = 8;
pub const MAX_CACHED_ACTORS: usize = 32;
const MAX_LOCAL_VISITS: usize = 4096;
const MAX_CACHED_GRAPH_NODES: usize = 1024;
const MAX_PACKED_ANSWERS: usize = 128;

#[derive(Clone, Debug)]
struct Graph {
    terrain: terrain::Terrain,
    body: Body,
    edges: RefCell<BTreeMap<Cell, Vec<Cell>>>,
}
impl Graph {
    fn node(&self, p: Cell) -> Option<Cell> {
        self.terrain.supported(p, self.body).then_some(p)
    }
    fn build(snapshot: Rc<Geometry>, body: Body) -> Self {
        Self {
            terrain: terrain::Terrain::new(snapshot),
            body,
            edges: RefCell::new(BTreeMap::new()),
        }
    }
    fn adjacent(&self, a: Cell, b: Cell) -> bool {
        self.terrain.adjacent(a, b, self.body)
    }
}

#[derive(Clone, Copy, Debug)]
struct Visit {
    distance: u32,
    parent: Cell,
    first: Cell,
}

#[derive(Clone, Debug)]
struct Search {
    seen: BTreeMap<Cell, Visit>,
    queue: Vec<Cell>,
    head: usize,
    packed: bool,
    answers: BTreeMap<Cell, Option<(u32, Cell)>>,
}
impl Search {
    /// Resume the SAME cardinal BFS until the requested node is discovered.
    /// Query order affects work performed, never distances, parents or tie breaks.
    /// An unreachable query drains the connected component rather than truncating.
    fn visit_until(&mut self, graph: &Graph, target: Cell) {
        while !self.seen.contains_key(&target) && self.head < self.queue.len() {
            if self.seen.len() >= MAX_LOCAL_VISITS && packed::fits(&graph.terrain.0) {
                self.queue = Vec::new();
                self.head = 0;
                self.packed = true;
                return;
            }
            let n = self.queue[self.head];
            self.head += 1;
            let visit = self.seen[&n];
            let mut edges = graph.edges.borrow_mut();
            if edges.len() >= MAX_CACHED_GRAPH_NODES && !edges.contains_key(&n) {
                edges.clear();
            }
            let neighbors = edges
                .entry(n)
                .or_insert_with(|| graph.terrain.neighbors(n, graph.body));
            for &q in neighbors.iter() {
                if let std::collections::btree_map::Entry::Vacant(entry) = self.seen.entry(q) {
                    entry.insert(Visit {
                        distance: visit.distance + 1,
                        parent: n,
                        first: if visit.distance == 0 { q } else { visit.first },
                    });
                    self.queue.push(q);
                }
            }
        }
    }
    fn cache_answer(&mut self, target: Cell, answer: Option<(u32, Cell)>) {
        if self.answers.len() >= MAX_PACKED_ANSWERS && !self.answers.contains_key(&target) {
            self.answers.clear();
        }
        self.answers.insert(target, answer);
    }
}

#[derive(Clone, Debug)]
pub struct Reachability {
    graph: Rc<Graph>,
    start: Cell,
    search: RefCell<Search>,
}
impl Reachability {
    fn build(graph: Rc<Graph>, start: Cell) -> Self {
        let mut search = Search {
            seen: BTreeMap::new(),
            queue: Vec::new(),
            head: 0,
            packed: false,
            answers: BTreeMap::new(),
        };
        if graph.node(start).is_some() {
            search.queue.push(start);
            search.seen.insert(
                start,
                Visit {
                    distance: 0,
                    parent: start,
                    first: start,
                },
            );
        }
        Self {
            graph,
            start,
            search: RefCell::new(search),
        }
    }
    pub fn get(&self, p: &Cell) -> Option<(u32, Cell)> {
        let n = self.graph.node(*p)?;
        let mut s = self.search.borrow_mut();
        if !s.packed {
            s.visit_until(&self.graph, n);
        }
        if s.packed {
            if let Some(v) = s.seen.get(p) {
                return Some((v.distance, v.first));
            }
            if let Some(answer) = s.answers.get(p) {
                return *answer;
            }
            drop(s);
            let answer = packed::get(&self.graph.terrain, self.graph.body, self.start, *p);
            self.search.borrow_mut().cache_answer(*p, answer);
            return answer;
        }
        s.seen.get(&n).map(|v| (v.distance, v.first))
    }
    pub fn contains_key(&self, p: &Cell) -> bool {
        self.get(p).is_some()
    }
    pub fn distance(&self, p: Cell) -> Option<u32> {
        self.get(&p).map(|(d, _)| d)
    }
    fn route(&self, p: Cell) -> Option<VecDeque<Cell>> {
        self.graph.node(p)?;
        let mut search = self.search.borrow_mut();
        if !search.packed {
            search.visit_until(&self.graph, p);
        }
        if search.packed && !search.seen.contains_key(&p) {
            if search.answers.get(&p) == Some(&None) {
                return None;
            }
            drop(search);
            let path = packed::query(&self.graph.terrain, self.graph.body, self.start, p);
            let answer = path
                .as_ref()
                .map(|path| ((path.len() - 1) as u32, *path.get(1).unwrap_or(&self.start)));
            self.search.borrow_mut().cache_answer(p, answer);
            return path;
        }
        if !search.seen.contains_key(&p) {
            return None;
        }
        let mut n = self.graph.node(p)?;
        let s = search;
        let mut path = VecDeque::new();
        loop {
            path.push_front(n);
            if s.seen[&n].parent == n {
                break;
            }
            n = s.seen[&n].parent;
        }
        Some(path)
    }
    /// Preserve a legitimate saved next hop, including equally short alternate
    /// routes. The temporary alternate BFS is not retained by coordinate key.
    pub fn serves(&self, saved: Cell, target: Cell) -> bool {
        if saved == self.start {
            return target == self.start && self.get(&target).is_some();
        }
        if !self.graph.adjacent(self.start, saved) {
            return false;
        }
        let Some((distance, canonical)) = self.get(&target) else {
            return false;
        };
        if saved == canonical {
            return true;
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
    snapshot: Option<Rc<Geometry>>,
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
            self.snapshot = None;
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
            let snapshot = self
                .snapshot
                .get_or_insert_with(|| Rc::new(g.clone()))
                .clone();
            let graph = Rc::new(Graph::build(snapshot, body));
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
        if path.len() <= MAX_LOCAL_VISITS {
            self.routes.insert(
                id,
                Route {
                    body,
                    target,
                    path: path.clone(),
                },
            );
        } else {
            self.routes.remove(&id);
        }
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
