use super::*;

#[test]
fn component_mapping_preserves_every_persisted_colonist_field() {
    // Distinct, non-default values catch cross-wired fields as well as omissions.
    for amount in [0.0, 12.5] {
        let row = Colonist {
            id: u64::MAX,
            name: "Mapping fixture".into(),
            x: 3,
            y: 5,
            move_progress: 0.375,
            target_x: 17,
            target_y: 19,
            activity: sim::Activity::Travelling,
            work: sim::WorkType::Hunting,
            haul_role: sim::HaulRole::Hauler,
            carried_kind: sim::ResourceKind::Meat,
            carried_amount: amount,
            goal: sim::Goal::Haul,
            hunger: 21.0,
            fatigue: 32.0,
            recreation: 43.0,
            mood: 54.0,
            productivity: 65.0,
            sleep_hours: 7.25,
            last_sleep_quality: 0.625,
        };
        let state = sim::Colonist {
            id: u64::MAX,
            name: "Mapping fixture".into(),
            position: sim::Position { x: 3, y: 5 },
            movement: sim::Movement {
                target: sim::Position { x: 17, y: 19 },
                progress: 0.375,
            },
            task: sim::ActivityState {
                activity: sim::Activity::Travelling,
                goal: sim::Goal::Haul,
            },
            assignment: sim::WorkAssignment {
                work: sim::WorkType::Hunting,
                haul_role: sim::HaulRole::Hauler,
            },
            cargo: sim::Cargo {
                kind: sim::ResourceKind::Meat,
                amount,
            },
            needs: sim::Needs {
                hunger: 21.0,
                fatigue: 32.0,
                recreation: 43.0,
            },
            wellbeing: sim::Wellbeing {
                mood: 54.0,
                productivity: 65.0,
            },
            rest: sim::Rest {
                hours: 7.25,
                last_quality: 0.625,
            },
        };
        let saved = colonist_row(&state);
        macro_rules! unchanged {
            ($($field:ident),+ $(,)?) => { $(assert_eq!(saved.$field, row.$field, stringify!($field));)+ };
        }
        unchanged!(
            id,
            name,
            x,
            y,
            move_progress,
            target_x,
            target_y,
            activity,
            work,
            haul_role,
            carried_kind,
            carried_amount,
            goal,
            hunger,
            fatigue,
            recreation,
            mood,
            productivity,
            sleep_hours,
            last_sleep_quality
        );
        assert_eq!(colonist_state(row), state);
        assert_eq!(colonist_state(saved), state);
        assert_eq!(state.is_carrying(), amount > 0.0);
    }
}
