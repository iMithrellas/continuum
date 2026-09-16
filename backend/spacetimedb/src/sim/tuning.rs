use super::{ResourceKind, SECONDS_PER_DAY};

/// All simulation constants in one place. Rates are expressed per **in-game hour**.
#[derive(Clone, Copy, Debug)]
pub struct Tuning {
    pub hunger_per_hour: f32,
    pub fatigue_per_hour: f32,
    /// Extra fatigue accrued on top of `fatigue_per_hour` while working.
    pub work_fatigue_per_hour: f32,
    pub recreation_per_hour: f32,

    pub crit_hunger: f32,
    pub crit_fatigue: f32,
    pub crit_recreation: f32,

    pub eat_rate_per_hour: f32,
    pub eat_stop: f32,
    /// Food units consumed per point of hunger removed.
    pub food_per_hunger: f32,

    pub sleep_recovery_per_hour: f32,
    /// Sleep quality at mood 0. Quality scales linearly to 1.0 at mood 100.
    pub sleep_quality_floor: f32,
    pub sleep_stop_fatigue: f32,
    /// Hard cap on one sleep. This is what turns "bad sleep quality" into
    /// "permanently accumulating fatigue".
    pub max_sleep_hours: f32,
    /// Waking with more fatigue than this counts as "poorly rested".
    pub poorly_rested_fatigue: f32,
    /// Going to sleep with less mood than this is worth reporting.
    pub low_mood_sleep_threshold: f32,

    pub recreate_rate_per_hour: f32,
    pub recreate_stop: f32,

    /// Resource units produced per in-game hour by a colonist at 100%
    /// productivity. Food is much higher than the rest because food demand
    /// scales with the whole population while the other resources have no
    /// consumer yet.
    pub output_food_per_hour: f32,
    pub output_wood_per_hour: f32,
    pub output_stone_per_hour: f32,
    pub output_meat_per_hour: f32,

    /// How much of one resource fits in a single carried stack. A production
    /// site accumulates a ground pile; trips carry up to one stack. Partial piles
    /// are collected when nobody is working or heading to work on that tile.
    pub stack_food: f32,
    pub stack_wood: f32,
    pub stack_stone: f32,
    pub stack_meat: f32,

    pub mood_base: f32,
    pub mood_w_hunger: f32,
    pub mood_w_fatigue: f32,
    pub mood_w_recreation: f32,
    /// How fast mood chases its target, in mood points per in-game hour.
    pub mood_rate_per_hour: f32,

    pub prod_base: f32,
    pub prod_w_fatigue: f32,
    pub prod_w_mood_deficit: f32,

    pub move_tiles_per_hour: f32,

    /// Time constant, in in-game seconds, for the smoothed colony-level mood and
    /// productivity figures. Instantaneous averages swing wildly (everyone is
    /// asleep at the same time), so alerts are driven by the smoothed values.
    pub stat_ema_tau_seconds: f32,
}

impl Default for Tuning {
    fn default() -> Self {
        Self {
            hunger_per_hour: 5.0,
            fatigue_per_hour: 4.0,
            work_fatigue_per_hour: 1.5,
            recreation_per_hour: 3.0,

            crit_hunger: 60.0,
            crit_fatigue: 60.0,
            crit_recreation: 60.0,

            eat_rate_per_hour: 200.0,
            eat_stop: 5.0,
            food_per_hunger: 0.16,

            sleep_recovery_per_hour: 16.0,
            sleep_quality_floor: 0.10,
            sleep_stop_fatigue: 10.0,
            max_sleep_hours: 6.0,
            poorly_rested_fatigue: 20.0,
            low_mood_sleep_threshold: 35.0,

            recreate_rate_per_hour: 60.0,
            recreate_stop: 5.0,

            output_food_per_hour: 14.0,
            output_wood_per_hour: 6.0,
            output_stone_per_hour: 5.0,
            output_meat_per_hour: 4.0,

            stack_food: 30.0,
            stack_wood: 25.0,
            stack_stone: 20.0,
            stack_meat: 15.0,

            mood_base: 110.0,
            mood_w_hunger: 0.20,
            mood_w_fatigue: 0.15,
            mood_w_recreation: 0.70,
            mood_rate_per_hour: 15.0,

            prod_base: 114.0,
            prod_w_fatigue: 0.35,
            prod_w_mood_deficit: 0.45,

            move_tiles_per_hour: 40.0,

            stat_ema_tau_seconds: SECONDS_PER_DAY as f32,
        }
    }
}

impl Tuning {
    pub fn output_per_hour(&self, kind: ResourceKind) -> f32 {
        match kind {
            ResourceKind::Food => self.output_food_per_hour,
            ResourceKind::Wood => self.output_wood_per_hour,
            ResourceKind::Stone => self.output_stone_per_hour,
            ResourceKind::Meat => self.output_meat_per_hour,
        }
    }

    pub fn stack_size(&self, kind: ResourceKind) -> f32 {
        match kind {
            ResourceKind::Food => self.stack_food,
            ResourceKind::Wood => self.stack_wood,
            ResourceKind::Stone => self.stack_stone,
            ResourceKind::Meat => self.stack_meat,
        }
    }
}
