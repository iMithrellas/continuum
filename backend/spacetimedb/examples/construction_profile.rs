//! Native profiling of the actual bounded planner, not a reimplementation.
//! cargo run --release --manifest-path backend/spacetimedb/Cargo.toml --example construction_profile -- 7
use continuum_module::sim::{
    self,
    construction::{self, BlockRect},
    geometry::Geometry,
    Tile, TileKind,
};
use std::hint::black_box;
use std::time::Instant;

fn rect(edge: i32) -> BlockRect {
    BlockRect {
        min_x: 24,
        min_y: 24,
        max_x: edge - 1,
        max_y: edge - 1,
    }
}
fn main() {
    let samples = std::env::args()
        .nth(1)
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(7)
        .max(1);
    println!(
        "native actual construction planner; release opt-level=z; cap=4096; samples={samples}"
    );
    let g = Geometry::flat_with_dimensions(256, 256).unwrap();
    let sparse = sim::default_tiles();
    let mut dense = sparse.clone();
    let mut id = 577;
    for y in 24..256 {
        for x in 24..256 {
            dense.push(Tile {
                id,
                x,
                y,
                z: 0,
                kind: TileKind::Empty,
                enabled: true,
                width: 1,
                depth: 1,
                clearance_height: 4,
            });
            id += 1;
        }
    }
    let mut reserved = dense.clone();
    for tile in &mut reserved {
        if tile.x > 87 || tile.y > 87 {
            tile.kind = TileKind::Farm;
        }
    }
    for (label, area, wood) in [
        ("unaffordable-within-cap", rect(88), 0.0),
        ("unaffordable-10816", rect(128), 0.0),
        ("unaffordable-53824", rect(256), 0.0),
        ("affordable-cap-10816", rect(128), 1_500_000.0),
        ("affordable-cap-53824", rect(256), 1_500_000.0),
    ] {
        let iterations = 10000;
        let mut times = Vec::new();
        for _ in 0..samples {
            let started = Instant::now();
            for _ in 0..iterations {
                black_box(
                    construction::plan_block(
                        black_box(&g),
                        black_box(&dense),
                        black_box(area),
                        0,
                        TileKind::Farm,
                        black_box(wood),
                    )
                    .unwrap_err(),
                );
            }
            times.push(started.elapsed().as_secs_f64() * 1_000_000.0 / iterations as f64);
        }
        times.sort_by(f64::total_cmp);
        println!("reject {label} rows={} cells={} median={:.3}us max={:.3}us per_call ({iterations} calls/sample)", dense.len(), area.cells().unwrap(), times[times.len()/2], times[times.len()-1]);
    }
    for (label, existing) in [
        ("starter", &sparse),
        ("populated", &dense),
        ("reserved", &reserved),
    ] {
        for edge in [48, 56, 88] {
            let area = rect(edge);
            let mut times = Vec::new();
            for _ in 0..samples {
                let started = Instant::now();
                let plan =
                    construction::plan_block(&g, existing, area, 0, TileKind::Farm, 1_500_000.0)
                        .unwrap();
                assert_eq!(plan.tiles.len() as u64, area.cells().unwrap());
                black_box(plan);
                times.push(started.elapsed().as_secs_f64() * 1000.0);
            }
            times.sort_by(f64::total_cmp);
            println!(
                "plan {label} rows={} cells={} median={:.3}ms max={:.3}ms",
                existing.len(),
                area.cells().unwrap(),
                times[times.len() / 2],
                times[times.len() - 1]
            );
        }
    }
}
