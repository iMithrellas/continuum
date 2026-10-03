use crate::reducers::advance_world_generation;
use spacetimedb::{table, ScheduleAt};

#[derive(spacetimedb::SpacetimeType, Clone, Copy, Debug, PartialEq, Eq)]
pub enum GenerationPhase {
    Preparing,
    Terrain,
    Overview,
    Validating,
    Founding,
    Ready,
    Failed,
}

#[table(accessor = world_generation, public)]
pub struct WorldGeneration {
    #[primary_key]
    pub id: u32,
    pub generation_id: u64,
    pub generator_version: u32,
    pub storage_version: u32,
    pub seed: u64,
    pub width: i32,
    pub height: i32,
    pub min_z: i32,
    pub max_z: i32,
    pub starter_x: i32,
    pub starter_y: i32,
    pub phase: GenerationPhase,
    pub completed_chunks: u32,
    pub total_chunks: u32,
    pub completed_units: u64,
    pub total_units: u64,
    pub ready: bool,
    pub error: String,
}

#[table(accessor = terrain_column_chunk, public,
    index(accessor = by_xy, btree(columns = [chunk_x, chunk_y])))]
pub struct TerrainColumnChunk {
    #[primary_key]
    pub id: u64,
    pub chunk_x: i32,
    pub chunk_y: i32,
    pub generation_id: u64,
    pub revision: u32,
    pub base_z: Vec<i16>,
    pub soil_depth: Vec<u8>,
    pub soil_fertility: Vec<u8>,
    pub forest_density: Vec<u8>,
    pub moisture: Vec<u8>,
}

#[table(accessor = terrain_overview_chunk, public,
    index(accessor = by_view, btree(columns = [lod, cut_z, chunk_x, chunk_y])))]
pub struct TerrainOverviewChunk {
    #[primary_key]
    pub id: u64,
    pub generation_id: u64,
    pub revision: u32,
    pub lod: u8,
    pub cut_z: i32,
    pub chunk_x: i32,
    pub chunk_y: i32,
    pub surface_z: Vec<i16>,
    pub material: Vec<u16>,
    pub soil_fertility: Vec<u8>,
    pub forest_density: Vec<u8>,
    pub moisture: Vec<u8>,
}

#[table(accessor = world_generation_task, scheduled(advance_world_generation))]
pub struct WorldGenerationTask {
    #[primary_key]
    #[auto_inc]
    pub scheduled_id: u64,
    pub scheduled_at: ScheduleAt,
    pub generation_id: u64,
}

#[table(accessor = world_generation_control)]
pub struct WorldGenerationControl {
    #[primary_key]
    pub id: u32,
    pub generation_id: u64,
    pub expected_task_id: u64,
    pub resume_phase: GenerationPhase,
    pub requested_time_scale: f64,
}

#[table(accessor = terrain_override_allocator)]
pub struct TerrainOverrideAllocator {
    #[primary_key]
    pub id: u32,
    pub next_id: u64,
}
