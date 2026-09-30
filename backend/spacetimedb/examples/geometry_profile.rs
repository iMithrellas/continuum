//! Repeatable native-module profiling; no database, server or shared state.
//! cargo run --release --manifest-path backend/spacetimedb/Cargo.toml --example geometry_profile -- 5
use continuum_module::sim::{self, geometry::Geometry, Tuning};
use std::hint::black_box;
use std::time::Instant;

fn fresh(edge: i32) -> sim::World {
    let mut w = sim::new_world();
    let mut g = Geometry::seeded();
    g.expand(edge, edge).unwrap();
    w.geometry = Some(g);
    w
}
fn main() {
    let repeats = std::env::args()
        .nth(1)
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(5)
        .max(1);
    let edge = std::env::args()
        .nth(2)
        .map(|s| s.parse::<i32>().unwrap())
        .unwrap_or(128);
    assert!(
        (128..=256).contains(&edge),
        "profile edge must be 128..=256"
    );
    let w = fresh(edge);
    let g = w.geometry.as_ref().unwrap();
    println!(
        "native module, release opt-level=z; {edge}x{edge}x32 cells; elapsed simulation only, fresh snapshot per sample"
    );
    println!(
        "payload chunks={} material_bytes={} operational_rows={} actors={}",
        g.chunks.len(),
        g.chunks.len() * 4096 * 2,
        w.tiles.len(),
        w.colonists.len()
    );
    for count in [w.tiles.len(), (edge * edge) as usize] {
        let mut times = Vec::new();
        for _ in 0..repeats {
            let now = Instant::now();
            let fields: Vec<_> = (0..count)
                .map(|i| {
                    sim::terrain::sample(1, (i % edge as usize) as i32, (i / edge as usize) as i32)
                })
                .collect();
            black_box(fields);
            times.push(now.elapsed().as_secs_f64() * 1000.0);
        }
        times.sort_by(f64::total_cmp);
        println!(
            "environment sampling rows={count} median={:.3}ms max={:.3}ms (not part of tick)",
            times[times.len() / 2],
            times[times.len() - 1]
        );
    }
    for label in ["seed", "payload clone"] {
        let mut times = Vec::new();
        for _ in 0..repeats {
            let now = Instant::now();
            if label == "seed" {
                black_box(fresh(edge));
            } else {
                black_box(g.chunks.clone());
            }
            times.push(now.elapsed().as_secs_f64() * 1000.0);
        }
        times.sort_by(f64::total_cmp);
        println!(
            "{label} median={:.3}ms max={:.3}ms",
            times[times.len() / 2],
            times[times.len() - 1]
        );
    }
    for seconds in [0.0, 6.0, 60.0, 600.0, 3600.0, 100000.0] {
        let mut times = Vec::new();
        let mut last = (0, 0, 0);
        for _ in 0..repeats {
            let mut w = fresh(edge);
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
            let mut g = Geometry::flat_with_dimensions(edge, edge).unwrap();
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
    let mut times = Vec::new();
    for _ in 0..repeats {
        let mut g = Geometry::flat_with_dimensions(edge, edge).unwrap();
        let mut first = g
            .designate(1, 0, 0, edge / 2 - 1, edge - 1, -3, 1, 3)
            .unwrap();
        first.enabled = false;
        g.designations.push(first);
        let now = Instant::now();
        black_box(
            g.designate(2, edge / 2, 0, edge - 1, edge - 1, -3, 1, 3)
                .unwrap(),
        );
        times.push(now.elapsed().as_secs_f64() * 1000.0);
    }
    times.sort_by(f64::total_cmp);
    println!(
        "adjacent designation cells={} each: median={:.3}ms max={:.3}ms",
        edge * edge / 2,
        times[times.len() / 2],
        times[times.len() - 1]
    );
}
