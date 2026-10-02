use super::*;
use crate::sim::geometry::{Geometry, STONE};
use crate::sim::{self, Colonist, Tile, TileKind, WorkType, World};

fn close(actual: f32, expected: f32) {
    assert!((actual - expected).abs() < 0.0001, "{actual} != {expected}");
}

fn flat(seconds: f32, progress: f32, target: Position) -> (Position, Movement) {
    let mut position = Position { x: 0, y: 0 };
    let mut movement = Movement { target, progress };
    step_travel(
        &mut position,
        &mut movement,
        &Tuning::default(),
        seconds / 3600.0,
    );
    (position, movement)
}

fn world(live: bool) -> World {
    let mut w = sim::new_world();
    w.game_seconds = 0.0;
    w.tiles = vec![Tile {
        id: 71,
        x: 250,
        y: 0,
        z: 0,
        kind: TileKind::Recreation,
        enabled: true,
        width: 1,
        depth: 1,
        clearance_height: 4,
    }];
    w.work_orders.clear();
    w.stacks.clear();
    let mut c = Colonist::new(19, "Walker", 0, 0);
    c.assignment.work = WorkType::None;
    c.needs.hunger = 0.0;
    c.needs.fatigue = 0.0;
    c.needs.recreation = 80.0;
    c.movement.target = Position { x: 250, y: 0 };
    w.colonists = vec![c];
    w.geometry = live.then(|| Geometry::flat_with_dimensions(256, 1).unwrap());
    w
}

fn flat_distance(w: &World) -> f32 {
    (w.colonists[0].position.x as f32 + w.colonists[0].movement.progress) * CELL_EDGE_METERS
}

#[test]
fn default_flat_walking_is_one_point_four_metres_per_game_second() {
    close(Tuning::default().move_tiles_per_hour, 10080.0);
    let (p, m) = flat(1.0, 0.0, Position { x: 10, y: 0 });
    assert_eq!(p, Position { x: 2, y: 0 });
    close(m.progress, 0.8);
    close((p.x as f32 + m.progress) * CELL_EDGE_METERS, 1.4);
    let (p, m) = flat(0.0, 0.4, Position { x: 10, y: 0 });
    assert_eq!(p.x, 0);
    close(m.progress, 0.4);
    let (p, m) = flat(100.0, 0.4, Position { x: 1, y: 1 });
    assert_eq!(p, m.target);
    assert_eq!(m.progress, 0.0);
}

#[test]
fn flat_elapsed_subdivision_and_existing_rate_override_are_preserved() {
    let (expected, m) = flat(6.0, 0.3, Position { x: 100, y: 0 });
    let mut p = Position { x: 0, y: 0 };
    let mut split = Movement {
        target: m.target,
        progress: 0.3,
    };
    for _ in 0..60 {
        step_travel(&mut p, &mut split, &Tuning::default(), 0.1 / 3600.0);
    }
    assert_eq!(p, expected);
    close(split.progress, m.progress);
    let tuning = Tuning {
        move_tiles_per_hour: 600.0,
        ..Tuning::default()
    };
    p = Position { x: 0, y: 0 };
    split.progress = 0.0;
    step_travel(&mut p, &mut split, &tuning, 6.0 / 3600.0);
    assert_eq!(p.x, 1);
    close(split.progress, 0.0);
}

#[test]
fn supported_live_straight_line_matches_flat_and_discards_arrival_budget() {
    let mut w = world(true);
    w.step_live_travel(0, &Tuning::default(), 1.0 / 3600.0);
    assert_eq!(w.actor_cell(0), Cell(2, 0, 0));
    assert_eq!(w.colonists[0].spatial.next, Cell(3, 0, 0));
    close(w.colonists[0].movement.progress, 0.8);
    close(flat_distance(&w), 1.4);
    let before = w.colonists[0].clone();
    w.step_live_travel(0, &Tuning::default(), 0.0);
    assert_eq!(w.colonists[0], before);
    w.colonists[0].movement.target.x = 3;
    w.step_live_travel(0, &Tuning::default(), 1.0);
    assert_eq!(w.actor_cell(0), Cell(3, 0, 0));
    assert_eq!(w.colonists[0].spatial.next, Cell(3, 0, 0));
    assert_eq!(w.colonists[0].movement.progress, 0.0);
}

#[test]
fn blocked_live_route_discards_progress_without_crossing_wall_or_missing_support() {
    for wall in [true, false] {
        let mut w = world(true);
        let g = w.geometry.as_mut().unwrap();
        if wall {
            for z in 0..5 {
                g.set(Cell(1, 0, z), STONE);
            }
        } else {
            g.set(Cell(1, 0, -1), 0);
            // A one-cell depression is navigable; this gap exceeds body.step.
            g.set(Cell(1, 0, -2), 0);
        }
        w.colonists[0].movement.progress = 0.6;
        w.step_live_travel(0, &Tuning::default(), 1.0);
        assert_eq!(w.actor_cell(0), Cell(0, 0, 0));
        assert_eq!(w.colonists[0].spatial.next, Cell(0, 0, 0));
        assert_eq!(w.colonists[0].movement.progress, 0.0);
    }
}

fn slope_world() -> World {
    let mut w = world(true);
    w.colonists[0].movement.target.x = 6;
    let g = w.geometry.as_mut().unwrap();
    g.set(Cell(2, 0, 0), STONE);
    g.set(Cell(3, 0, 0), STONE);
    w
}

#[test]
fn slope_fraction_preserves_start_progress_and_charges_true_distance_and_time() {
    let mut w = slope_world();
    w.colonists[0].position.x = 1;
    w.colonists[0].spatial.next = Cell(2, 0, 1);
    w.colonists[0].movement.progress = 0.5;
    let length = 0.5_f32 * 2.0_f32.sqrt();
    close(hop_length_meters(Cell(1, 0, 0), Cell(2, 0, 1)), length);
    w.step_live_travel(0, &Tuning::default(), 0.1 / 3600.0);
    assert_eq!(w.actor_cell(0), Cell(1, 0, 0));
    close(w.colonists[0].movement.progress, 0.5 + 0.14 / length);
    // Completing the remaining distance takes (half a slope - 0.14m)/1.4s.
    // Include another 0.1m to verify carry into the next, flat half-metre hop.
    let remaining_seconds = (0.5 * length - 0.14 + 0.1) / 1.4;
    w.step_live_travel(0, &Tuning::default(), remaining_seconds / 3600.0);
    assert_eq!(w.actor_cell(0), Cell(2, 0, 1));
    close(w.colonists[0].movement.progress, 0.2);
}

#[test]
fn multiple_flat_slope_flat_hops_convert_budget_and_match_elapsed_subdivision() {
    let mut w = slope_world();
    let mut split = w.clone();
    w.step_live_travel(0, &Tuning::default(), 1.0 / 3600.0);
    let slope = 0.5_f32 * 2.0_f32.sqrt();
    assert_eq!(w.actor_cell(0), Cell(2, 0, 1));
    assert_eq!(w.colonists[0].spatial.next, Cell(3, 0, 1));
    close(w.colonists[0].movement.progress, (1.4 - 0.5 - slope) / 0.5);
    w.step_live_travel(0, &Tuning::default(), 1.0 / 3600.0);
    // 2.8m covers flat, up, flat, down, and part of another flat hop.
    assert_eq!(w.actor_cell(0), Cell(4, 0, 0));
    close(
        w.colonists[0].movement.progress,
        (2.8 - 1.0 - 2.0 * slope) / 0.5,
    );
    for _ in 0..20 {
        split.step_live_travel(0, &Tuning::default(), 0.1 / 3600.0);
    }
    assert_eq!(split.actor_cell(0), w.actor_cell(0));
    close(
        split.colonists[0].movement.progress,
        w.colonists[0].movement.progress,
    );
}

#[test]
fn world_schedule_obeys_game_clock_real_second_speed_multipliers_and_pause() {
    for live in [false, true] {
        let tuning = Tuning::default();
        let mut one_game_second = world(live);
        sim::step(&mut one_game_second, &tuning, 1.0);
        close(flat_distance(&one_game_second), 1.4);
        let mut baseline = world(live);
        // User 1x is six game seconds per real second; 6x is six times that.
        sim::step(&mut baseline, &tuning, crate::DEFAULT_TIME_SCALE);
        close(flat_distance(&baseline), 8.4);
        let mut accelerated = world(live);
        sim::step(&mut accelerated, &tuning, crate::DEFAULT_TIME_SCALE * 6.0);
        close(flat_distance(&accelerated), 50.4);
        let mut subdivided = world(live);
        for _ in 0..6 {
            sim::step(&mut subdivided, &tuning, crate::DEFAULT_TIME_SCALE);
        }
        assert_eq!(
            subdivided.colonists[0].position,
            accelerated.colonists[0].position
        );
        close(flat_distance(&subdivided), flat_distance(&accelerated));
        let paused = accelerated.clone();
        assert!(sim::step(&mut accelerated, &tuning, 0.0).is_empty());
        assert_eq!(accelerated.colonists, paused.colonists);
        assert_eq!(accelerated.game_seconds, paused.game_seconds);
        let mut bounded = world(live);
        let mut split = bounded.clone();
        sim::step(&mut bounded, &tuning, 61.0);
        sim::step(&mut split, &tuning, 60.0);
        sim::step(&mut split, &tuning, 1.0);
        assert_eq!(bounded.colonists, split.colonists);
        close(flat_distance(&bounded), 85.4);
        assert_eq!(bounded.game_seconds, 61.0);
    }
}
