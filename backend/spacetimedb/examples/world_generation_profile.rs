//! Native opt-level=z generation/expansion timings; excludes database/network.
use continuum_module::sim::{
    geometry::{Cell, Geometry},
    world_generation,
};
use std::collections::BTreeMap;
use std::{hint::black_box, time::Instant};

fn main() {
    for repeat in 0..5 {
        let start = Instant::now();
        let mut columns = BTreeMap::new();
        for cy in 0..64 {
            for cx in 0..64 {
                columns.insert(
                    Cell(cx, cy, 0),
                    world_generation::generate_columns(0x6c6f_6e67_7365_6565, 2048, 2048, cx, cy)
                        .physical,
                );
            }
        }
        let g = Geometry::compact(2048, 2048, columns, 1).unwrap();
        let fresh_ms = start.elapsed().as_secs_f64() * 1000.0;
        let bytes: usize = g
            .columns
            .as_ref()
            .unwrap()
            .values()
            .map(|c| c.base_z.len() * 2 + c.soil_depth.len())
            .sum();
        black_box(&g);
        let mut old = Geometry::seeded();
        old.changed.clear();
        let start = Instant::now();
        world_generation::expand(&mut old, 0x6c6f_6e67_7365_6565, 256, 256).unwrap();
        let expand_ms = start.elapsed().as_secs_f64() * 1000.0;
        println!("repeat={repeat} compact_2048_ms={fresh_ms:.3} legacy_expand_128_ms={expand_ms:.3} compact_chunks={} physical_bytes={bytes}", g.columns.as_ref().unwrap().len());
        black_box(old);
    }
}
