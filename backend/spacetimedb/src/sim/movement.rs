use super::geometry::{Cell, CELL_EDGE_METERS};
use super::{Movement, Position, Tuning};

/// Distance only: navigation remains responsible for validating the hop.
pub(super) fn hop_length_meters(start: Cell, next: Cell) -> f32 {
    let dx = (next.0 - start.0) as f32;
    let dy = (next.1 - start.1) as f32;
    let dz = (next.2 - start.2) as f32;
    (dx * dx + dy * dy + dz * dz).sqrt() * CELL_EDGE_METERS
}

pub(super) fn step_travel(
    position: &mut Position,
    movement: &mut Movement,
    tuning: &Tuning,
    dt_hours: f32,
) {
    let mut steps = movement.progress + tuning.move_tiles_per_hour * dt_hours;
    while steps >= 1.0 && *position != movement.target {
        steps -= 1.0;
        if position.x != movement.target.x {
            position.x += (movement.target.x - position.x).signum();
        } else if position.y != movement.target.y {
            position.y += (movement.target.y - position.y).signum();
        }
    }
    movement.progress = if *position == movement.target {
        0.0
    } else {
        steps
    };
}

#[cfg(test)]
mod tests;
