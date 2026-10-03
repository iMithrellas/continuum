use crate::{
    auth::{authorize, RequiredRole},
    persistence::large_world,
    schema::*,
};
#[cfg(feature = "generation-test-probes")]
use spacetimedb::Table;
use spacetimedb::{reducer, ReducerContext};

#[reducer]
pub fn reset_world_large(
    ctx: &ReducerContext,
    width: i32,
    height: i32,
    seed: u64,
) -> Result<(), String> {
    authorize(ctx, RequiredRole::Admin)?;
    large_world::begin(ctx, width, height, seed, 0.0)
}

#[reducer]
pub fn retry_world_generation(ctx: &ReducerContext) -> Result<(), String> {
    authorize(ctx, RequiredRole::Admin)?;
    large_world::retry(ctx)
}

#[reducer]
pub fn advance_world_generation(
    ctx: &ReducerContext,
    task: WorldGenerationTask,
) -> Result<(), String> {
    authorize(ctx, RequiredRole::Scheduler)?;
    let Some(mut state) = ctx.db.world_generation().id().find(0) else {
        return Ok(());
    };
    let Some(mut control) = ctx.db.world_generation_control().id().find(0) else {
        return Ok(());
    };
    if !accepts_task(&state, &control, &task) {
        return Ok(());
    }
    let phase = state.phase;
    match large_world::advance(ctx, &mut state, &control) {
        Ok(()) => {
            control.resume_phase = state.phase;
            control.expected_task_id = if state.ready {
                0
            } else {
                large_world::schedule(ctx, state.generation_id)
            };
        }
        Err(mut error) => {
            state.phase = GenerationPhase::Failed;
            state.ready = false;
            if error.len() > 1024 {
                let end = (0..=1024)
                    .rev()
                    .find(|&i| error.is_char_boundary(i))
                    .unwrap_or(0);
                error.truncate(end);
            }
            state.error = error;
            control.resume_phase = phase;
            control.expected_task_id = 0;
        }
    }
    ctx.db.world_generation().id().update(state);
    ctx.db.world_generation_control().id().update(control);
    Ok(())
}

fn accepts_task(
    state: &WorldGeneration,
    control: &WorldGenerationControl,
    task: &WorldGenerationTask,
) -> bool {
    task.generation_id == state.generation_id
        && control.generation_id == state.generation_id
        && control.expected_task_id != 0
        && task.scheduled_id == control.expected_task_id
        && !state.ready
        && !matches!(
            state.phase,
            GenerationPhase::Ready | GenerationPhase::Failed
        )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn persisted_generation_nonce_and_expected_task_reject_stale_duplicate_and_terminal_work() {
        let mut s = WorldGeneration {
            id: 0,
            generation_id: 7,
            generator_version: 1,
            storage_version: 1,
            seed: 13,
            width: 2048,
            height: 2048,
            min_z: -16,
            max_z: 15,
            starter_x: 1012,
            starter_y: 1012,
            phase: GenerationPhase::Terrain,
            completed_chunks: 16,
            total_chunks: 4096,
            completed_units: 16,
            total_units: 4096,
            ready: false,
            error: String::new(),
        };
        let mut c = WorldGenerationControl {
            id: 0,
            generation_id: 7,
            expected_task_id: 31,
            resume_phase: GenerationPhase::Terrain,
            requested_time_scale: 0.0,
        };
        let mut t = WorldGenerationTask {
            scheduled_id: 31,
            scheduled_at: spacetimedb::TimeDuration::from_micros(1000).into(),
            generation_id: 7,
        };
        assert!(accepts_task(&s, &c, &t));
        c.expected_task_id = 32;
        assert!(!accepts_task(&s, &c, &t));
        t.scheduled_id = 32;
        t.generation_id = 6;
        assert!(!accepts_task(&s, &c, &t));
        t.generation_id = 7;
        c.generation_id = 6;
        assert!(!accepts_task(&s, &c, &t));
        c.generation_id = 7;
        s.phase = GenerationPhase::Failed;
        assert!(!accepts_task(&s, &c, &t));
        s.phase = GenerationPhase::Ready;
        assert!(!accepts_task(&s, &c, &t));
        s.phase = GenerationPhase::Terrain;
        s.ready = true;
        assert!(!accepts_task(&s, &c, &t));
        s.ready = false;
        c.expected_task_id = 0;
        t.scheduled_id = 0;
        assert!(!accepts_task(&s, &c, &t));
    }
}

#[cfg(feature = "generation-test-probes")]
#[reducer]
pub fn generation_test_force_missing_source(ctx: &ReducerContext) -> Result<(), String> {
    authorize(ctx, RequiredRole::Admin)?;
    let mut s = ctx
        .db
        .world_generation()
        .id()
        .find(0)
        .ok_or("generation missing")?;
    if s.ready {
        return Err("probe requires unfinished generation".into());
    }
    ctx.db.terrain_column_chunk().id().delete(0);
    s.phase = GenerationPhase::Overview;
    s.completed_units = 0;
    s.total_units =
        crate::sim::world_generation::overview_tiles(s.width, s.height).len() as u64 * 32;
    ctx.db.world_generation().id().update(s);
    large_world::retry(ctx)
}

#[cfg(feature = "generation-test-probes")]
#[reducer]
pub fn generation_test_repair_source(ctx: &ReducerContext) -> Result<(), String> {
    authorize(ctx, RequiredRole::Admin)?;
    let mut s = ctx
        .db
        .world_generation()
        .id()
        .find(0)
        .ok_or("generation missing")?;
    if s.phase != GenerationPhase::Failed {
        return Err("probe requires failed generation".into());
    }
    let c = crate::sim::world_generation::generate_columns(s.seed, s.width, s.height, 0, 0);
    ctx.db.terrain_column_chunk().insert(TerrainColumnChunk {
        id: 0,
        chunk_x: 0,
        chunk_y: 0,
        generation_id: s.generation_id,
        revision: 0,
        base_z: c.physical.base_z,
        soil_depth: c.physical.soil_depth,
        soil_fertility: c.soil_fertility,
        forest_density: c.forest_density,
        moisture: c.moisture,
    });
    let n = ctx.db.terrain_column_chunk().count();
    s.completed_units = n;
    s.total_units = u64::from(s.total_chunks);
    s.completed_chunks = n as u32;
    let mut c = ctx
        .db
        .world_generation_control()
        .id()
        .find(0)
        .ok_or("control missing")?;
    c.resume_phase = GenerationPhase::Terrain;
    ctx.db.world_generation().id().update(s);
    ctx.db.world_generation_control().id().update(c);
    large_world::retry(ctx)
}

#[cfg(feature = "generation-test-probes")]
#[reducer]
pub fn generation_test_profile_snapshot(ctx: &ReducerContext) -> Result<(), String> {
    authorize(ctx, RequiredRole::Admin)?;
    large_world::require_ready(ctx)?;
    let w = crate::persistence::load_world(ctx);
    let g = w.geometry.as_ref().ok_or("geometry missing")?;
    if g.columns.as_ref().map(|c| c.len()) != Some(4096) {
        return Err("profile expects complete 2048 snapshot".into());
    }
    std::hint::black_box(&w);
    #[cfg(target_arch = "wasm32")]
    crate::events::log_event(
        ctx,
        Severity::Info,
        format!(
            "GENERATION_TEST_SNAPSHOT_LINEAR_BYTES={}",
            core::arch::wasm32::memory_size::<0>() * 65536
        ),
    );
    Ok(())
}

#[cfg(feature = "generation-test-probes")]
#[reducer]
pub fn generation_test_route(ctx: &ReducerContext, x: i32, y: i32) -> Result<(), String> {
    authorize(ctx, RequiredRole::Admin)?;
    large_world::require_ready(ctx)?;
    let w = crate::persistence::load_world(ctx);
    let g = w.geometry.as_ref().ok_or("geometry missing")?;
    let s = ctx
        .db
        .world_generation()
        .id()
        .find(0)
        .ok_or("generation missing")?;
    let body = crate::sim::geometry::Body::default();
    let z = (g.min_z..=g.max_z - 3)
        .rev()
        .find(|&z| g.supported(crate::sim::geometry::Cell(x, y, z), body))
        .ok_or("target has no supported surface")?;
    let search = w.navigation.borrow_mut().reachable(
        g,
        999,
        crate::sim::geometry::Cell(s.starter_x + 12, s.starter_y + 12, 0),
        body,
    );
    search
        .get(&crate::sim::geometry::Cell(x, y, z))
        .ok_or("target genuinely unreachable")?;
    #[cfg(target_arch = "wasm32")]
    crate::events::log_event(
        ctx,
        Severity::Info,
        format!(
            "GENERATION_TEST_ROUTE_LINEAR_BYTES={}",
            core::arch::wasm32::memory_size::<0>() * 65536
        ),
    );
    Ok(())
}
