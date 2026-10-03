//! Repeatable native population profile, independent of map expansion.
//!
//! Run from the repository root:
//! `cargo run --release --manifest-path backend/spacetimedb/Cargo.toml --example population_profile -- 3 12,48,128,256 12 120`
//!
//! Arguments are repeats, comma-separated populations, warmup intervals, and
//! measured intervals. Each interval is 60 in-game seconds. Timings cover only
//! `sim::step` (including event construction), not setup, validation, event drop,
//! database loading/saving, or network work. Each repeat starts fresh and warms
//! the same navigation cache; measured samples form a continuous trajectory,
//! not identical independent ticks. Release uses this module's opt-level=z.
//!
//! Fixed flat live geometry and operational facilities intentionally isolate
//! population from geometry scaling. Shared facilities have no occupancy limit.
//! Work and needs are staggered; initial full piles ensure actual haul traffic.
//! Native timing is NOT a WASM fuel/memory budget or a practical population max.
use continuum_module::sim::{self, geometry::Geometry, Activity, HaulPolicy, ResourceKind, Tuning};
use std::{hint::black_box, time::Instant};

const EDGE: i32 = 24;
const INTERVAL_SECONDS: f64 = 60.0;
const KINDS: [ResourceKind; 4] = [
    ResourceKind::Food,
    ResourceKind::Wood,
    ResourceKind::Stone,
    ResourceKind::Meat,
];

/// Stable, sequential durable IDs; repeated founders retain their work mix but
/// receive deterministic, staggered needs independent of wall-clock/randomness.
fn fresh(population: usize, policy: HaulPolicy) -> sim::World {
    let mut world = sim::new_world();
    world.geometry = Some(Geometry::flat_with_dimensions(EDGE, EDGE).unwrap());
    let founders = world.colonists.clone();
    world.colonists = (0..population)
        .map(|i| {
            let mut actor = founders[i % founders.len()].clone();
            actor.id = i as u64 + 1;
            actor.name = format!("Profile-{:04}", actor.id);
            actor.needs.hunger = if i % 6 == 0 { 90.0 } else { 10.0 };
            actor.needs.fatigue = if i % 6 == 1 { 80.0 } else { 10.0 };
            actor.needs.recreation = if i % 6 == 2 { 90.0 } else { 10.0 };
            actor
        })
        .collect();
    world.haul_policy = policy;
    world.resources.food = population as f32 * 50.0;
    let tuning = Tuning::default();
    world.stacks = world
        .work_orders
        .iter()
        .map(|order| {
            let tile = world.tiles.iter().find(|t| t.id == order.tile_id).unwrap();
            let kind = order.work.definition().unwrap().output;
            sim::ItemStack {
                id: sim::stack_id(tile.id, kind),
                tile_id: tile.id,
                x: tile.x,
                y: tile.y,
                z: tile.z,
                kind,
                amount: tuning.stack_size(kind),
            }
        })
        .collect();
    world.stacks.sort_by_key(|stack| stack.id);
    world
}

/// Total resource units across stored goods, ground piles, and carried cargo.
fn totals(world: &sim::World) -> [f64; 4] {
    KINDS.map(|kind| {
        world.resources.amount(kind) as f64
            + world
                .stacks
                .iter()
                .filter(|s| s.kind == kind)
                .map(|s| s.amount as f64)
                .sum::<f64>()
            + world
                .colonists
                .iter()
                .filter(|c| c.cargo.kind == kind)
                .map(|c| c.cargo.amount as f64)
                .sum::<f64>()
    })
}

/// Version-local FNV-1a state fingerprint, not a portable replay format.
/// Debug formatting captures all actor components; sort by durable IDs, exclude
/// derived navigation cache and immutable geometry, include mutable world state.
fn checksum(world: &sim::World) -> u64 {
    let mut actors: Vec<_> = world.colonists.iter().collect();
    actors.sort_by_key(|c| c.id);
    let mut stacks: Vec<_> = world.stacks.iter().collect();
    stacks.sort_by_key(|s| s.id);
    let state = format!(
        "{EDGE}:{actors:?}:{stacks:?}:{:?}:{:?}:{:?}:{:?}:{:?}:{:?}:{:?}:{:?}",
        world.resources,
        world.work_orders,
        world.tiles,
        world.haul_policy,
        world.meal_policy,
        world.game_seconds,
        world.mood_ema,
        world.productivity_ema,
    );
    state.bytes().fold(0xcbf29ce484222325, |hash, byte| {
        (hash ^ byte as u64).wrapping_mul(0x100000001b3)
    })
}

fn validate(world: &sim::World, population: usize) {
    assert_eq!(world.colonists.len(), population);
    for (i, actor) in world.colonists.iter().enumerate() {
        assert_eq!(actor.id, i as u64 + 1);
        for value in [
            actor.needs.hunger,
            actor.needs.fatigue,
            actor.needs.recreation,
            actor.wellbeing.mood,
            actor.wellbeing.productivity,
            actor.cargo.amount,
            actor.movement.progress,
            actor.rest.hours,
            actor.rest.last_quality,
        ] {
            assert!(value.is_finite() && value >= 0.0, "invalid actor scalar");
        }
        assert!((0..EDGE).contains(&actor.position.x));
        assert!((0..EDGE).contains(&actor.position.y));
    }
    for kind in KINDS {
        let stored = world.resources.amount(kind);
        assert!(stored.is_finite() && stored >= 0.0);
    }
    for stack in &world.stacks {
        assert_eq!(stack.id, sim::stack_id(stack.tile_id, stack.kind));
        assert!(stack.amount.is_finite() && stack.amount >= 0.0);
    }
    assert!(world.stacks.windows(2).all(|s| s[0].id < s[1].id));
}

/// Nearest-rank percentile, with each measured step equally weighted.
fn percentile(sorted: &[f64], percent: usize) -> f64 {
    sorted[(sorted.len() * percent).div_ceil(100) - 1]
}

fn activity_index(activity: Activity) -> usize {
    match activity {
        Activity::Idle => 0,
        Activity::Travelling => 1,
        Activity::Working => 2,
        Activity::Hauling => 3,
        Activity::Eating => 4,
        Activity::Sleeping => 5,
        Activity::Recreating => 6,
    }
}

fn profile(population: usize, policy: HaulPolicy, repeats: usize, warmup: usize, measured: usize) {
    let tuning = Tuning::default();
    let mut times = Vec::with_capacity(repeats * measured);
    let mut expected = None;
    for repeat in 0..repeats {
        let mut world = fresh(population, policy);
        for _ in 0..warmup {
            black_box(sim::step(&mut world, &tuning, INTERVAL_SECONDS));
        }
        let before = totals(&world);
        let stored_before = KINDS.map(|k| world.resources.amount(k));
        let mut activities = [0usize; 7];
        let mut event_count = 0;
        for _ in 0..measured {
            let start = Instant::now();
            let events = black_box(sim::step(&mut world, &tuning, INTERVAL_SECONDS));
            times.push(start.elapsed().as_secs_f64() * 1000.0);
            event_count += events.len();
            for actor in &world.colonists {
                activities[activity_index(actor.task.activity)] += 1;
            }
            validate(&world, population);
        }
        let after = totals(&world);
        let produced = (1..4).map(|i| after[i] - before[i]).sum::<f64>();
        let delivered = (1..4)
            .map(|i| (world.resources.amount(KINDS[i]) - stored_before[i]) as f64)
            .sum::<f64>();
        assert!(
            produced > 0.0 && delivered > 0.0,
            "workload did not produce AND deliver goods"
        );
        assert!(
            (1..4).all(|i| after[i] + 0.01 >= before[i]),
            "non-food goods lost"
        );
        assert!(
            activities[2] > 0 && activities[3] > 0 && activities[4..].iter().any(|&n| n > 0),
            "workload must include measured work, haul, and needs service"
        );
        let fingerprint = checksum(&world);
        if let Some(previous) = expected {
            assert_eq!(
                fingerprint, previous,
                "fresh repeat changed deterministic state"
            );
        }
        expected = Some(fingerprint);
        if repeat == 0 {
            let nav = world.navigation.borrow();
            println!("  checksum={fingerprint:016x} measured_nonfood_produced={produced:.3} units delivered={delivered:.3} units events={event_count}");
            println!("  actor-intervals [idle,travel,work,haul,eat,sleep,recreate]={activities:?}; cumulative navigation graphs={} searches={} routes={}", nav.graph_builds, nav.searches, nav.route_builds);
        }
    }
    times.sort_by(f64::total_cmp);
    println!("population={population} policy={policy:?} samples={} p50={:.3}ms p95={:.3}ms max={:.3}ms per 60-game-second step",
        times.len(), percentile(&times, 50), percentile(&times, 95), times[times.len() - 1]);
}

fn main() {
    let args: Vec<_> = std::env::args().skip(1).collect();
    assert!(
        args.len() <= 4,
        "usage: population_profile [repeats populations warmup measured]"
    );
    let number = |index: usize, default: usize| {
        args.get(index)
            .map_or(default, |s| s.parse().expect("expected positive integer"))
    };
    let repeats = number(0, 3);
    let populations: Vec<usize> = args.get(1).map_or_else(
        || vec![12, 48, 128, 256],
        |s| {
            s.split(',')
                .map(|n| n.parse().expect("expected comma-separated populations"))
                .collect()
        },
    );
    let warmup = number(2, 12);
    let measured = number(3, 120);
    assert!((1..=10).contains(&repeats));
    assert!((1..=60).contains(&warmup));
    assert!((30..=240).contains(&measured));
    assert!(!populations.is_empty() && populations.len() <= 8);
    assert!(
        populations.iter().all(|n| (12..=256).contains(n)),
        "bounded profile populations must be 12..=256"
    );
    let fixture = fresh(12, HaulPolicy::SelfHaul);
    println!("native module profile={} opt-level=z in release; fixed flat {EDGE}x{EDGE}x32 geometry chunks={} operational_rows={} work_orders={} seeded_piles={} meal_policy=Normal default tuning",
        if cfg!(debug_assertions) { "debug (not baseline)" } else { "release" },
        fixture.geometry.as_ref().unwrap().chunks.len(), fixture.tiles.len(), fixture.work_orders.len(), fixture.stacks.len());
    println!("repeats={repeats} warmup={warmup} measured={measured} interval={INTERVAL_SECONDS} game seconds; setup/validation/persistence excluded; native is not WASM budget");
    for population in populations {
        for policy in [HaulPolicy::SelfHaul, HaulPolicy::DedicatedHaulers] {
            profile(population, policy, repeats, warmup, measured);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percentile_uses_nearest_rank() {
        let values: Vec<_> = (1..=100).map(f64::from).collect();
        assert_eq!(percentile(&values, 50), 50.0);
        assert_eq!(percentile(&values, 95), 95.0);
    }

    #[test]
    fn stable_ids_and_storage_order_do_not_change_replay() {
        for policy in [HaulPolicy::SelfHaul, HaulPolicy::DedicatedHaulers] {
            let mut a = fresh(12, policy);
            let mut b = fresh(12, policy);
            b.colonists.reverse();
            for _ in 0..30 {
                assert_eq!(
                    sim::step(&mut a, &Tuning::default(), INTERVAL_SECONDS),
                    sim::step(&mut b, &Tuning::default(), INTERVAL_SECONDS)
                );
            }
            validate(&a, 12);
            assert_eq!(checksum(&a), checksum(&b));
        }
    }

    #[test]
    fn hauling_without_production_conserves_nonfood_goods() {
        for policy in [HaulPolicy::SelfHaul, HaulPolicy::DedicatedHaulers] {
            let mut world = fresh(12, policy);
            world.work_orders.clear();
            let before = totals(&world);
            for _ in 0..60 {
                sim::step(&mut world, &Tuning::default(), INTERVAL_SECONDS);
                let after = totals(&world);
                for i in 1..4 {
                    assert!((after[i] - before[i]).abs() < 0.01);
                }
            }
            assert!(world.resources.wood + world.resources.stone + world.resources.meat > 0.0);
        }
    }
}
