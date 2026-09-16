use super::{Movement, Position, Tuning};

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
