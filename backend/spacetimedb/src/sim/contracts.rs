use super::*;

// Fingerprint explicit observable fields, not struct layout or DefaultHasher.
// Captured before composition; a schedule/math change must explain a new trace.
struct Trace(u64);

impl Trace {
    fn record(&mut self, value: impl std::fmt::Debug) {
        for byte in format!("{value:?}\n").bytes() {
            self.0 = (self.0 ^ u64::from(byte)).wrapping_mul(0x100000001b3);
        }
    }

    fn world(&mut self, world: &World) {
        self.record((world.game_seconds, world.mood_ema, world.productivity_ema));
        self.record((&world.resources, world.haul_policy, world.meal_policy));
        self.record((&world.tiles, &world.work_orders, &world.stacks));
        for c in &world.colonists {
            self.record((c.id, &c.name, c.x, c.y, c.target_x, c.target_y, c.move_progress));
            self.record((c.activity, c.goal, c.work, c.haul_role));
            self.record((c.carried_kind, c.carried_amount));
            self.record((c.hunger, c.fatigue, c.recreation, c.mood, c.productivity));
            self.record((c.sleep_hours, c.last_sleep_quality));
        }
    }
}

#[test]
fn simulation_matches_pre_composition_trace() {
    let mut traces = Vec::new();
    for hauling in [HaulPolicy::SelfHaul, HaulPolicy::DedicatedHaulers] {
        for meals in [MealPolicy::Normal, MealPolicy::Rationed] {
            let mut world = new_world();
            world.haul_policy = hauling;
            world.meal_policy = meals;
            let mut trace = Trace(0xcbf29ce484222325);
            trace.world(&world);
            for phase in 0..3 {
                for tile in &mut world.tiles {
                    if tile.kind == TileKind::Recreation {
                        tile.enabled = phase != 1;
                    }
                }
                if phase == 1 {
                    world.resources.food = 0.0;
                }
                for _ in 0..48 {
                    for dt in [6.0, 60.0, 3600.0] {
                        trace.record(step(&mut world, &Tuning::default(), dt));
                        trace.world(&world);
                    }
                }
            }
            traces.push(trace.0);
        }
    }
    assert_eq!(
        traces,
        vec![
            6869741487606980237,
            16097870207008624385,
            8860477168860726982,
            16079113804947565384,
        ]
    );
}
