use super::{Activity, MealPolicy, Needs, ResourceKind, Resources, Rest, Tuning, Wellbeing};

fn clamp_percentage(v: f32) -> f32 {
    v.clamp(0.0, 100.0)
}

/// Sleep quality in `[floor, 1.0]`, driven entirely by mood.
///
/// This is the hinge of the failure chain: unmet recreation lowers mood, low mood
/// lowers sleep quality, and low sleep quality means the `max_sleep_hours` cap is
/// hit before the fatigue is actually cleared.
pub fn sleep_quality(mood: f32, tuning: &Tuning) -> f32 {
    tuning.sleep_quality_floor
        + (1.0 - tuning.sleep_quality_floor) * (mood.clamp(0.0, 100.0) / 100.0)
}

pub(super) fn step_eat(
    needs: &mut Needs,
    resources: &mut Resources,
    policy: MealPolicy,
    tuning: &Tuning,
    dt_hours: f32,
) {
    let recovery_multiplier = policy.hunger_recovery_multiplier();
    let cost_per_hunger = tuning.food_per_hunger * policy.food_cost_per_hunger_multiplier();
    let want = (tuning.eat_rate_per_hour * dt_hours * recovery_multiplier).min(needs.hunger);
    if want <= 0.0 {
        return;
    }
    let needed = want * cost_per_hunger;
    let taken = resources.take(ResourceKind::Food, needed);
    let removed = if cost_per_hunger > 0.0 {
        taken / cost_per_hunger
    } else {
        want
    };
    needs.hunger = clamp_percentage(needs.hunger - removed);
}

pub(super) fn step_sleep(
    needs: &mut Needs,
    rest: &mut Rest,
    mood: f32,
    tuning: &Tuning,
    dt_hours: f32,
) {
    let sleep_hours = dt_hours.min((tuning.max_sleep_hours - rest.hours).max(0.0));
    let quality = sleep_quality(mood, tuning);
    rest.last_quality = quality;
    needs.fatigue =
        clamp_percentage(needs.fatigue - tuning.sleep_recovery_per_hour * quality * sleep_hours);
    rest.hours = (rest.hours + sleep_hours).min(tuning.max_sleep_hours);
}

pub(super) fn step_recreate(needs: &mut Needs, tuning: &Tuning, dt_hours: f32) {
    needs.recreation =
        clamp_percentage(needs.recreation - tuning.recreate_rate_per_hour * dt_hours);
}

pub(super) fn accrue_needs(needs: &mut Needs, activity: Activity, tuning: &Tuning, dt_hours: f32) {
    needs.hunger = clamp_percentage(needs.hunger + tuning.hunger_per_hour * dt_hours);
    if activity != Activity::Sleeping {
        let extra_fatigue = if matches!(activity, Activity::Working | Activity::Hauling) {
            tuning.work_fatigue_per_hour
        } else {
            0.0
        };
        needs.fatigue =
            clamp_percentage(needs.fatigue + (tuning.fatigue_per_hour + extra_fatigue) * dt_hours);
    }
    if activity != Activity::Recreating {
        needs.recreation =
            clamp_percentage(needs.recreation + tuning.recreation_per_hour * dt_hours);
    }
}

pub(super) fn update_wellbeing(
    wellbeing: &mut Wellbeing,
    needs: &Needs,
    tuning: &Tuning,
    dt_hours: f32,
) {
    let target = clamp_percentage(
        tuning.mood_base
            - tuning.mood_w_hunger * needs.hunger
            - tuning.mood_w_fatigue * needs.fatigue
            - tuning.mood_w_recreation * needs.recreation,
    );
    let max_step = tuning.mood_rate_per_hour * dt_hours;
    let delta = (target - wellbeing.mood).clamp(-max_step, max_step);
    wellbeing.mood = clamp_percentage(wellbeing.mood + delta);
    wellbeing.productivity = clamp_percentage(
        tuning.prod_base
            - tuning.prod_w_fatigue * needs.fatigue
            - tuning.prod_w_mood_deficit * (100.0 - wellbeing.mood),
    );
}
