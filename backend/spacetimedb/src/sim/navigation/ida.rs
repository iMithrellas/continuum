//! Optional bounded-work canonical IDA*. `None` means "use exact BFS", NEVER
//! unreachable. Unit-cost ordered edges make BFS's first shortest route the
//! lexicographically first shortest edge sequence. An admissible heuristic cannot
//! prune that route at the optimal bound. Canonical DFS at the first successful
//! bound thus returns that same sequence; path-cycle pruning removes no shortest
//! route. No global visited/transposition pruning or heuristic queue ties are used.
use super::terrain::Terrain;
use crate::sim::geometry::{Body, Cell};
use std::collections::{BTreeSet, VecDeque};

#[derive(Clone, Copy)]
pub(super) struct Budget {
    /// Counts BOTH entered nodes and candidate probes, including rejected edges.
    pub work: usize,
    pub path: usize,
    pub iterations: usize,
}
impl Default for Budget {
    fn default() -> Self {
        Self {
            work: 65_536,
            path: 8192,
            iterations: 16,
        }
    }
}

#[derive(Default, Debug)]
pub(super) struct Work {
    pub units: usize,
    pub expanded: usize,
    pub iterations: usize,
    pub peak_path: usize,
    pub stack_bytes: usize,
    pub solved: bool,
}

struct Frame {
    p: Cell,
    next: u32,
}

/// Manhattan XY and ceil(vertical separation / max step) each change by at
/// most one on any legal edge; their max is admissible and consistent even
/// for directed edges, caves, unknown cells and multi-cell bodies. With step=0
/// use only XY (still admissible); BFS handles any unchanging-z impossibility.
fn heuristic(a: Cell, b: Cell, step: i32) -> u64 {
    let horizontal = (i64::from(a.0) - i64::from(b.0)).unsigned_abs()
        + (i64::from(a.1) - i64::from(b.1)).unsigned_abs();
    let vertical = if step > 0 {
        (i64::from(a.2) - i64::from(b.2))
            .unsigned_abs()
            .div_ceil(step as u64)
    } else {
        0
    };
    horizontal.max(vertical)
}

pub(super) fn try_path(
    t: &Terrain,
    body: Body,
    start: Cell,
    target: Cell,
    budget: Budget,
) -> (Option<VecDeque<Cell>>, Work) {
    let mut work = Work::default();
    if budget.path == 0 || !t.supported(start, body) || !t.supported(target, body) {
        return (None, work);
    }
    let step = i32::from(body.step).min(t.0.max_z - t.0.min_z);
    let span = (2 * step + 1) as u32;
    let mut bound = heuristic(start, target, step);
    let mut stack = Vec::new();
    let mut path = BTreeSet::new();
    for _ in 0..budget.iterations {
        work.iterations += 1;
        let mut exceeded: Option<u64> = None;
        stack.clear();
        path.clear();
        stack.push(Frame { p: start, next: 0 });
        path.insert(start);
        while !stack.is_empty() {
            let depth = stack.len() - 1;
            let frame = stack.last_mut().unwrap();
            if frame.next == 0 {
                if work.units == budget.work {
                    return (None, work);
                }
                work.units += 1;
                work.expanded += 1;
                work.peak_path = work.peak_path.max(depth + 1);
                work.stack_bytes = work
                    .stack_bytes
                    .max(stack.capacity() * std::mem::size_of::<Frame>());
                if stack[depth].p == target {
                    work.solved = true;
                    return (Some(stack.iter().map(|f| f.p).collect()), work);
                }
            }
            let frame = stack.last_mut().unwrap();
            if frame.next == 4 * span {
                path.remove(&frame.p);
                stack.pop();
                continue;
            }
            if work.units == budget.work {
                return (None, work);
            }
            work.units += 1;
            let edge = frame.next;
            frame.next += 1;
            let (dx, dy) = [(1, 0), (0, 1), (-1, 0), (0, -1)][(edge / span) as usize];
            let dz = (edge % span) as i32 - step;
            let p = frame.p;
            let q = Cell(p.0 + dx, p.1 + dy, p.2 + dz);
            if !t.0.contains(q) || path.contains(&q) || !t.adjacent(p, q, body) {
                continue;
            }
            let f = (depth + 1) as u64 + heuristic(q, target, step);
            if f > bound {
                exceeded = Some(exceeded.map_or(f, |old| old.min(f)));
                continue;
            }
            if stack.len() == budget.path {
                return (None, work);
            }
            path.insert(q);
            stack.push(Frame { p: q, next: 0 });
        }
        let Some(next) = exceeded else {
            return (None, work);
        };
        bound = next;
    }
    (None, work)
}

#[cfg(test)]
mod tests;
