//! Deterministic production suitability from authoritative persisted terrain.
//!
//! No generation, actor identity, depletion, or database access belongs here.

use super::{terrain::TerrainFields, WorkType};
use std::collections::BTreeMap;

/// Transaction-local copy of terrain rows, keyed by durable tile IDs, not indices.
pub type EcologicalData = BTreeMap<u32, TerrainFields>;

/// Yield relative to baseline: farming = `0.5 + fertility * moisture`;
/// logging and hunting = `0.5 + forest_density`; other work = `1`.
///
/// Inputs are clamped to `[0, 1]`; any nonfinite input is treated as zero.
/// Ecological yields are finite in `[0.5, 1.5]`. Missing terrain is exactly
/// neutral (`1.0`), preserving historical fixtures without generated ecology.
/// See `docs/ecological-production.md` for client mirroring and rollout semantics.
pub fn production_multiplier(work: WorkType, terrain: Option<&TerrainFields>) -> f32 {
    let Some(terrain) = terrain else {
        return 1.0;
    };
    match work {
        WorkType::Farming => {
            0.5 + normalized(terrain.soil_fertility) * normalized(terrain.moisture)
        }
        WorkType::Logging | WorkType::Hunting => 0.5 + normalized(terrain.forest_density),
        WorkType::None | WorkType::Mining => 1.0,
    }
}

fn normalized(value: f32) -> f32 {
    if value.is_finite() {
        value.clamp(0.0, 1.0)
    } else {
        0.0
    }
}

#[cfg(test)]
mod tests;
