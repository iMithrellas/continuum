//! Repeatable native-module profiling; no database, server or shared state.
//! cargo run --release --manifest-path backend/spacetimedb/Cargo.toml --example geometry_profile -- 5
use continuum_module::sim::{self, geometry::Geometry, Tuning};
use std::hint::black_box;
use std::time::Instant;

fn fresh() -> sim::World {
    let mut w = sim::new_world();
    w.geometry = Some(Geometry::seeded());
    w
}
fn main() {
    let repeats = std::env::args()
        .nth(1)
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(5)
        .max(1);
    println!(
        "native module, release opt-level=z; elapsed simulation only, fresh snapshot per sample"
    );
    for seconds in [0.0, 6.0, 60.0, 600.0, 3600.0, 100000.0] {
        let mut times = Vec::new();
        let mut last = (0, 0, 0);
        for _ in 0..repeats {
            let mut w = fresh();
            let now = Instant::now();
            w.repair_navigation_hops();
            black_box(sim::step(&mut w, &Tuning::default(), seconds));
            times.push(now.elapsed().as_secs_f64() * 1000.0);
            let n = w.navigation.borrow();
            last = (n.graph_builds, n.searches, n.route_builds);
        }
        times.sort_by(f64::total_cmp);
        println!(
            "fresh {seconds:>6.0}s median={:.3}ms max={:.3}ms graphs={} bfs={} routes={}",
            times[times.len() / 2],
            times[times.len() - 1],
            last.0,
            last.1,
            last.2
        );
    }
    for (height, label) in [(16, "9216 solid cells"), (15, "8640 buried cells")] {
        let mut times = Vec::new();
        let mut job = false;
        for _ in 0..repeats {
            let mut w = sim::new_world();
            let mut g = Geometry::flat();
            let d = g.designate(1, 0, 0, 23, 23, -16, height, 2).unwrap();
            g.designations.push(d);
            w.geometry = Some(g);
            let miner = w
                .colonists
                .iter()
                .position(|c| c.assignment.work == sim::WorkType::Mining)
                .unwrap();
            let now = Instant::now();
            job = black_box(w.mining_job(miner)).is_some();
            times.push(now.elapsed().as_secs_f64() * 1000.0);
        }
        times.sort_by(f64::total_cmp);
        println!(
            "designation {label}: cold median={:.3}ms max={:.3}ms reachable_job={job}",
            times[times.len() / 2],
            times[times.len() - 1]
        );
    }
}
