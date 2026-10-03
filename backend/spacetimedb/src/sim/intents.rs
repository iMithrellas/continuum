//! Speculative goal planning, separated from ordered, authoritative execution.
//!
//! World queries (including navigation's RefCell cache) run only at the actor's turn.
//! Workers receive only owned components and query results, never World or row indices.

use super::decisions::{decide, Availability, Decision};
use super::logistics::labour_goal;
use super::{ActivityState, Colonist, Goal, Needs, Rest, Tuning, World};

#[cfg(test)]
std::thread_local! {
    /// Count gathering, not pure worker evaluations; each test thread is isolated.
    pub(super) static GATHER_COUNT: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

/// Complete read set of the pure goal decision. Shared-world dependencies are
/// represented by their query results, not a coarse stock/geometry version.
#[derive(Clone, Debug, PartialEq)]
pub(super) struct DecisionInput {
    actor: u64,
    task: ActivityState,
    needs: Needs,
    rest: Rest,
    availability: Availability,
    labour: Option<Goal>,
}

impl DecisionInput {
    /// Query-free speculative input: labour is optimistically absent and need
    /// facilities use interval availability without live reachability filtering.
    /// Both assumptions must be validated at the ordered actor turn. Never warm
    /// navigation here: even exact searches can evict another actor's saved route.
    pub(super) fn speculate(actor: &Colonist, interval: Availability) -> Self {
        Self::from_actor(actor, interval, None)
    }

    fn from_actor(actor: &Colonist, availability: Availability, labour: Option<Goal>) -> Self {
        Self {
            actor: actor.id,
            task: actor.task.clone(),
            needs: actor.needs.clone(),
            rest: actor.rest.clone(),
            availability,
            labour,
        }
    }

    /// Gather on the schedule thread. Interval availability intentionally keeps
    /// the historical food snapshot even after earlier consumption or deposits.
    pub(super) fn gather(
        world: &World,
        index: usize,
        tuning: &Tuning,
        interval: Availability,
    ) -> Self {
        #[cfg(test)]
        GATHER_COUNT.with(|count| count.set(count.get() + 1));
        let labour = labour_goal(world, index, tuning);
        let availability = if world.geometry.is_some() {
            Availability {
                food: interval.food && world.live_destination(index, tuning, Goal::Eat).is_some(),
                kitchen: interval.kitchen
                    && world.live_destination(index, tuning, Goal::Eat).is_some(),
                sleep: interval.sleep
                    && world.live_destination(index, tuning, Goal::Sleep).is_some(),
                recreation: interval.recreation
                    && world
                        .live_destination(index, tuning, Goal::Recreate)
                        .is_some(),
            }
        } else {
            interval
        };
        Self::from_actor(&world.colonists[index], availability, labour)
    }

    /// Pure immediate plan for the one-worker ordered path. Nothing can change
    /// between gathering and this decision, so no validation/re-query is needed.
    pub(super) fn decide(&self, tuning: &Tuning) -> Decision {
        decide(
            &self.task,
            &self.needs,
            &self.rest,
            tuning,
            &self.availability,
            self.labour,
        )
    }
}

/// A proposal is not a reservation and never mutates state or emits events.
pub(super) struct Proposal {
    input: DecisionInput,
    decision: Decision,
}

impl Proposal {
    fn plan(input: DecisionInput, tuning: &Tuning) -> Self {
        let decision = input.decide(tuning);
        Self { input, decision }
    }

    /// Validate against the single gather at this actor's ordered commit turn.
    /// Earlier actors may change labour/reachability; speculation never queries it.
    /// Equal query results mean the pure decision's full read set is unchanged;
    /// otherwise recompute before *any* events, destination changes or actions.
    pub(super) fn validate(self, current: DecisionInput, tuning: &Tuning) -> Decision {
        assert_eq!(self.input.actor, current.actor, "proposal actor mismatch");
        if self.input == current {
            self.decision
        } else {
            current.decide(tuning)
        }
    }
}

/// Portable default. The opt-in native executor is bounded to eight workers;
/// WASM never creates threads, including when the feature is enabled.
pub(super) fn worker_count() -> usize {
    #[cfg(all(feature = "native-parallel-intents", not(target_arch = "wasm32")))]
    {
        std::thread::available_parallelism()
            .map(|count| count.get().min(8))
            .unwrap_or(1)
    }
    #[cfg(not(all(feature = "native-parallel-intents", not(target_arch = "wasm32"))))]
    {
        1
    }
}

/// Disable speculative allocation when threads are unavailable or not requested.
/// In particular an explicitly requested worker count cannot enable it on WASM.
pub(super) fn uses_speculation(workers: usize, actors: usize) -> bool {
    cfg!(all(
        feature = "native-parallel-intents",
        not(target_arch = "wasm32")
    )) && workers > 1
        && actors > 1
}

/// Independently batchable evaluation; output order always matches input order.
/// Only narrow component snapshots cross threads. Query gathering and conflict
/// validation are serial, so this seam is not a promise of a speedup.
pub(super) fn plan_batch(
    inputs: Vec<DecisionInput>,
    tuning: &Tuning,
    workers: usize,
) -> Vec<Proposal> {
    #[cfg(all(feature = "native-parallel-intents", not(target_arch = "wasm32")))]
    if workers > 1 && inputs.len() > 1 {
        let workers = workers.min(8).min(inputs.len());
        let chunk_size = inputs.len().div_ceil(workers);
        return std::thread::scope(|scope| {
            let handles: Vec<_> = inputs
                .chunks(chunk_size)
                .map(|chunk| {
                    scope.spawn(move || {
                        chunk
                            .iter()
                            .cloned()
                            .map(|input| Proposal::plan(input, tuning))
                            .collect::<Vec<_>>()
                    })
                })
                .collect();
            handles
                .into_iter()
                .flat_map(|handle| handle.join().expect("pure decision worker panicked"))
                .collect()
        });
    }
    let _ = workers;
    inputs
        .into_iter()
        .map(|input| Proposal::plan(input, tuning))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pure_proposals_are_independent_of_submission_order_and_worker_count() {
        let world = crate::sim::new_world();
        let tuning = Tuning::default();
        let availability = Availability {
            food: true,
            kitchen: true,
            sleep: true,
            recreation: true,
        };
        let inputs: Vec<_> = world
            .colonist_order()
            .into_iter()
            .map(|index| DecisionInput::gather(&world, index, &tuning, availability))
            .collect();
        let expected: Vec<_> = plan_batch(inputs.clone(), &tuning, 1)
            .into_iter()
            .map(|proposal| (proposal.input.actor, proposal.decision))
            .collect();
        for workers in [1, 2, 4, 8] {
            let mut reversed = inputs.clone();
            reversed.reverse();
            let mut actual: Vec<_> = plan_batch(reversed, &tuning, workers)
                .into_iter()
                .map(|proposal| (proposal.input.actor, proposal.decision))
                .collect();
            actual.reverse();
            assert_eq!(actual, expected);
        }
    }
}
