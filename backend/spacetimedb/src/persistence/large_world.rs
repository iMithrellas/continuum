//! Complete server-authored compact terrain, bounded initialization and exact snapshots.
use super::*;
use sim::{
    geometry::{Cell, Geometry},
    world_generation::{self as gen, ColumnChunk},
};
use spacetimedb::TimeDuration;
use std::{
    collections::{BTreeMap, BTreeSet},
    rc::Rc,
};

const TERRAIN_BATCH: u64 = 16;
const VALIDATION_BATCH: u64 = 64;

pub(crate) fn is_ready(ctx: &ReducerContext) -> bool {
    ctx.db
        .world_generation()
        .id()
        .find(0)
        .map(|s| s.ready && s.phase == GenerationPhase::Ready)
        .unwrap_or_else(|| {
            ctx.db.config().id().find(0).is_some() && ctx.db.colony().id().find(0).is_some()
        })
}
pub(crate) fn require_ready(ctx: &ReducerContext) -> Result<(), String> {
    if is_ready(ctx) {
        Ok(())
    } else {
        Err("world generation is not ready".into())
    }
}
pub(crate) fn require_legacy_ready(ctx: &ReducerContext) -> Result<(), String> {
    require_ready(ctx)?;
    if ctx.db.world_generation().id().find(0).is_some() {
        Err("compact worlds require explicit regeneration; legacy expansion is unsupported".into())
    } else {
        Ok(())
    }
}
pub(crate) fn schedule(ctx: &ReducerContext, generation_id: u64) -> u64 {
    ctx.db
        .world_generation_task()
        .insert(WorldGenerationTask {
            scheduled_id: 0,
            scheduled_at: (ctx.timestamp + TimeDuration::from_micros(1_000)).into(),
            generation_id,
        })
        .scheduled_id
}

pub(crate) fn begin(
    ctx: &ReducerContext,
    width: i32,
    height: i32,
    seed: u64,
    time_scale: f64,
) -> Result<(), String> {
    gen::validate_large_dimensions(width, height)?;
    crate::speed_policy::validate_time_scale(time_scale)?;
    let generation_id = ctx
        .db
        .world_generation()
        .id()
        .find(0)
        .map(|s| s.generation_id)
        .unwrap_or(0)
        .checked_add(1)
        .ok_or("generation nonce exhausted")?;
    let generation = ctx
        .db
        .config()
        .id()
        .find(0)
        .map(|s| s.generation)
        .unwrap_or(0)
        .checked_add(1)
        .ok_or("colony generation exhausted")?;
    let (starter_x, starter_y) = gen::centered_origin(width, height);
    super::clear_colony(ctx);
    for d in ctx.db.excavation_designation().iter() {
        ctx.db.excavation_designation().id().delete(d.id);
    }
    for d in ctx.db.excavation_jobs().iter() {
        ctx.db.excavation_jobs().id().delete(d.id);
    }
    for task in ctx.db.world_generation_task().iter() {
        ctx.db
            .world_generation_task()
            .scheduled_id()
            .delete(task.scheduled_id);
    }
    super::upsert_world_seed(ctx, seed);
    super::upsert_config(
        ctx,
        Config {
            id: 0,
            time_scale: 0.0,
            game_seconds: 8.0 * 3600.0,
            generation,
            haul_policy: HaulPolicy::SelfHaul,
            meal_policy: MealPolicy::Normal,
        },
    );
    let bounds = WorldGeometry {
        id: 0,
        width,
        height,
        min_z: -16,
        max_z: 15,
    };
    if ctx.db.world_geometry().id().find(0).is_some() {
        ctx.db.world_geometry().id().update(bounds);
    } else {
        ctx.db.world_geometry().insert(bounds);
    }
    let state = WorldGeneration {
        id: 0,
        generation_id,
        generator_version: 1,
        storage_version: 1,
        seed,
        width,
        height,
        min_z: -16,
        max_z: 15,
        starter_x,
        starter_y,
        phase: GenerationPhase::Preparing,
        completed_chunks: 0,
        total_chunks: (((width + 31) / 32) * ((height + 31) / 32)) as u32,
        completed_units: 0,
        total_units: ctx.db.terrain_column_chunk().count()
            + ctx.db.terrain_overview_chunk().count()
            + ctx.db.terrain_chunk().count(),
        ready: false,
        error: String::new(),
    };
    if ctx.db.world_generation().id().find(0).is_some() {
        ctx.db.world_generation().id().update(state);
    } else {
        ctx.db.world_generation().insert(state);
    }
    let control = WorldGenerationControl {
        id: 0,
        generation_id,
        expected_task_id: schedule(ctx, generation_id),
        resume_phase: GenerationPhase::Preparing,
        requested_time_scale: time_scale,
    };
    if ctx.db.world_generation_control().id().find(0).is_some() {
        ctx.db.world_generation_control().id().update(control);
    } else {
        ctx.db.world_generation_control().insert(control);
    }
    let allocator = TerrainOverrideAllocator { id: 0, next_id: 1 };
    if ctx.db.terrain_override_allocator().id().find(0).is_some() {
        ctx.db.terrain_override_allocator().id().update(allocator);
    } else {
        ctx.db.terrain_override_allocator().insert(allocator);
    }
    Ok(())
}

pub(crate) fn retry(ctx: &ReducerContext) -> Result<(), String> {
    let mut state = ctx
        .db
        .world_generation()
        .id()
        .find(0)
        .ok_or("no staged generation")?;
    if state.ready {
        return Err("world already ready".into());
    }
    let mut control = ctx
        .db
        .world_generation_control()
        .id()
        .find(0)
        .ok_or("generation control missing")?;
    if state.phase == GenerationPhase::Failed {
        state.phase = control.resume_phase;
        state.error.clear();
    }
    control.expected_task_id = schedule(ctx, state.generation_id);
    ctx.db.world_generation().id().update(state);
    ctx.db.world_generation_control().id().update(control);
    Ok(())
}

fn phase(state: &mut WorldGeneration, next: GenerationPhase, total: u64) {
    state.phase = next;
    state.completed_units = 0;
    state.total_units = total;
}
fn column_row(s: &WorldGeneration, cx: i32, cy: i32) -> TerrainColumnChunk {
    let c = gen::generate_columns(s.seed, s.width, s.height, cx, cy);
    TerrainColumnChunk {
        id: gen::column_id(cx, cy),
        chunk_x: cx,
        chunk_y: cy,
        generation_id: s.generation_id,
        revision: 0,
        base_z: c.physical.base_z,
        soil_depth: c.physical.soil_depth,
        soil_fertility: c.soil_fertility,
        forest_density: c.forest_density,
        moisture: c.moisture,
    }
}
fn validate_column(s: &WorldGeneration, row: &TerrainColumnChunk) -> Result<(), String> {
    let expected = column_row(s, row.chunk_x, row.chunk_y);
    if row.generation_id != s.generation_id
        || row.id != expected.id
        || row.revision != 0
        || row.base_z != expected.base_z
        || row.soil_depth != expected.soil_depth
        || row.soil_fertility != expected.soil_fertility
        || row.forest_density != expected.forest_density
        || row.moisture != expected.moisture
    {
        return Err(format!("invalid generated column chunk {}", row.id));
    }
    Ok(())
}

pub(crate) fn advance(
    ctx: &ReducerContext,
    s: &mut WorldGeneration,
    control: &WorldGenerationControl,
) -> Result<(), String> {
    gen::validate_large_dimensions(s.width, s.height)?;
    if s.generator_version != 1
        || s.storage_version != 1
        || s.min_z != -16
        || s.max_z != 15
        || s.completed_units > s.total_units
        || s.total_chunks != (((s.width + 31) / 32) * ((s.height + 31) / 32)) as u32
    {
        return Err("invalid or unsupported generation descriptor".into());
    }
    let tiles = gen::overview_tiles(s.width, s.height);
    match s.phase {
        GenerationPhase::Preparing => {
            let columns: Vec<_> = ctx
                .db
                .terrain_column_chunk()
                .iter()
                .take(64)
                .map(|r| r.id)
                .collect();
            let overview: Vec<_> = ctx
                .db
                .terrain_overview_chunk()
                .iter()
                .take(64)
                .map(|r| r.id)
                .collect();
            let voxels: Vec<_> = ctx
                .db
                .terrain_chunk()
                .iter()
                .take(64)
                .map(|r| r.id)
                .collect();
            s.completed_units += (columns.len() + overview.len() + voxels.len()) as u64;
            for id in columns {
                ctx.db.terrain_column_chunk().id().delete(id);
            }
            for id in overview {
                ctx.db.terrain_overview_chunk().id().delete(id);
            }
            for id in voxels {
                ctx.db.terrain_chunk().id().delete(id);
            }
            if ctx.db.terrain_column_chunk().iter().next().is_none()
                && ctx.db.terrain_overview_chunk().iter().next().is_none()
                && ctx.db.terrain_chunk().iter().next().is_none()
            {
                super::geometry::install_materials(ctx);
                phase(s, GenerationPhase::Terrain, u64::from(s.total_chunks));
            }
        }
        GenerationPhase::Terrain => {
            let end = (s.completed_units + TERRAIN_BATCH).min(s.total_units);
            let across = (s.width + 31) / 32;
            let planned: Vec<_> = (s.completed_units..end)
                .map(|i| column_row(s, (i % across as u64) as i32, (i / across as u64) as i32))
                .collect();
            for row in planned {
                ctx.db.terrain_column_chunk().insert(row);
            }
            s.completed_units = end;
            s.completed_chunks = end as u32;
            if end == s.total_units {
                phase(s, GenerationPhase::Overview, tiles.len() as u64 * 32);
            }
        }
        GenerationPhase::Overview => {
            let (lod, x, y) = tiles[(s.completed_units / 32) as usize];
            let rows = make_overviews(ctx, s, lod, x, y)?;
            for row in rows {
                ctx.db.terrain_overview_chunk().insert(row);
            }
            s.completed_units += 32;
            if s.completed_units == s.total_units {
                phase(
                    s,
                    GenerationPhase::Validating,
                    u64::from(s.total_chunks) + tiles.len() as u64 * 32,
                );
            }
        }
        GenerationPhase::Validating => {
            let end = (s.completed_units + VALIDATION_BATCH).min(s.total_units);
            for i in s.completed_units..end {
                if i < u64::from(s.total_chunks) {
                    let across = ((s.width + 31) / 32) as u64;
                    let row = ctx
                        .db
                        .terrain_column_chunk()
                        .id()
                        .find(gen::column_id((i % across) as i32, (i / across) as i32))
                        .ok_or("generated column missing")?;
                    validate_column(s, &row)?;
                } else {
                    let index = i - u64::from(s.total_chunks);
                    let (lod, x, y) = tiles[(index / 32) as usize];
                    let cut = (index % 32) as i32 - 16;
                    let row = ctx
                        .db
                        .terrain_overview_chunk()
                        .id()
                        .find(gen::overview_id(lod, cut, x, y))
                        .ok_or("generated overview missing")?;
                    if row.generation_id != s.generation_id
                        || row.id != gen::overview_id(lod, cut, x, y)
                        || row.lod != lod
                        || row.cut_z != cut
                        || row.chunk_x != x
                        || row.chunk_y != y
                        || [
                            row.surface_z.len(),
                            row.material.len(),
                            row.soil_fertility.len(),
                            row.forest_density.len(),
                            row.moisture.len(),
                        ]
                        .iter()
                        .any(|&n| n != 256)
                    {
                        return Err("invalid overview arrays".into());
                    }
                    if row.surface_z.iter().zip(&row.material).any(|(&z, &m)| {
                        m > 2 || i32::from(z) > cut || z < -17 || (m == 0) != (z == -17)
                    }) {
                        return Err("invalid overview exposure".into());
                    }
                }
            }
            s.completed_units = end;
            if end == s.total_units {
                phase(s, GenerationPhase::Founding, 1);
            }
        }
        GenerationPhase::Founding => {
            let mut g = super::geometry::load(ctx);
            for z in 0..6 {
                for y in 8..12 {
                    for x in 22..24 {
                        if !g.set(
                            Cell(s.starter_x + x, s.starter_y + y, z),
                            sim::geometry::STONE,
                        ) {
                            return Err("failed finite fixture materialization".into());
                        }
                    }
                }
            }
            let d = g.designate(
                0,
                s.starter_x + 22,
                s.starter_y + 8,
                s.starter_x + 23,
                s.starter_y + 11,
                0,
                6,
                2,
            )?;
            super::geometry::save(ctx, &g);
            super::geometry::write_designation(ctx, &d);
            super::found_colony(
                ctx,
                control.requested_time_scale,
                s.seed,
                (s.starter_x, s.starter_y),
            );
            s.phase = GenerationPhase::Ready;
            s.ready = true;
            s.completed_units = 1;
        }
        GenerationPhase::Ready | GenerationPhase::Failed => {}
    }
    Ok(())
}

pub(super) fn load_columns_region(
    ctx: &ReducerContext,
    coverage: Option<(i32, i32, i32, i32)>,
) -> Option<Rc<BTreeMap<Cell, ColumnChunk>>> {
    let state = ctx.db.world_generation().id().find(0)?;
    assert_eq!(
        state.storage_version, 1,
        "unsupported compact storage version"
    );
    let source: Box<dyn Iterator<Item = TerrainColumnChunk>> =
        if let Some((x0, y0, x1, y1)) = coverage {
            let mut out = Vec::new();
            for x in x0 / 32..=x1 / 32 {
                out.extend(
                    ctx.db
                        .terrain_column_chunk()
                        .by_xy()
                        .filter((x, y0 / 32..=y1 / 32)),
                );
            }
            Box::new(out.into_iter())
        } else {
            Box::new(ctx.db.terrain_column_chunk().iter())
        };
    let columns = source
        .map(|r| {
            assert_eq!(
                r.generation_id, state.generation_id,
                "stale compact terrain"
            );
            assert_eq!(r.base_z.len(), 1024);
            assert_eq!(r.soil_depth.len(), 1024);
            (
                Cell(r.chunk_x, r.chunk_y, 0),
                ColumnChunk {
                    base_z: r.base_z,
                    soil_depth: r.soil_depth,
                },
            )
        })
        .collect::<BTreeMap<_, _>>();
    assert_eq!(
        columns.len(),
        coverage
            .map(|(x0, y0, x1, y1)| ((x1 / 32 - x0 / 32 + 1) * (y1 / 32 - y0 / 32 + 1)) as usize)
            .unwrap_or(state.total_chunks as usize),
        "incomplete compact physical snapshot"
    );
    Some(Rc::new(columns))
}
pub(super) fn ecology_at(
    ctx: &ReducerContext,
    x: i32,
    y: i32,
) -> Option<sim::terrain::TerrainFields> {
    let r = ctx
        .db
        .terrain_column_chunk()
        .id()
        .find(gen::column_id(x.div_euclid(32), y.div_euclid(32)))?;
    let i = (x.rem_euclid(32) + 32 * y.rem_euclid(32)) as usize;
    Some(sim::terrain::TerrainFields {
        soil_fertility: f32::from(*r.soil_fertility.get(i)?) / 255.0,
        forest_density: f32::from(*r.forest_density.get(i)?) / 255.0,
        moisture: f32::from(*r.moisture.get(i)?) / 255.0,
    })
}

fn exposed(g: &Geometry, x: i32, y: i32, cut: i32) -> (i16, u16) {
    for z in (g.min_z..=cut.min(g.max_z)).rev() {
        if let Some(m) = g.material(Cell(x, y, z)) {
            if m != sim::geometry::AIR {
                return (z as i16, m);
            }
        }
    }
    ((g.min_z - 1) as i16, 0)
}
fn make_overviews(
    ctx: &ReducerContext,
    s: &WorldGeneration,
    lod: u8,
    cx: i32,
    cy: i32,
) -> Result<Vec<TerrainOverviewChunk>, String> {
    let stride = 1i32 << lod;
    let mut source = BTreeMap::new();
    for y in 0..16 {
        for x in 0..16 {
            let (wx, wy) = (
                (cx * 16 + x) * stride + stride / 2,
                (cy * 16 + y) * stride + stride / 2,
            );
            if wx >= s.width || wy >= s.height {
                continue;
            }
            let id = gen::column_id(wx / 32, wy / 32);
            if let std::collections::btree_map::Entry::Vacant(e) = source.entry(id) {
                let row = ctx
                    .db
                    .terrain_column_chunk()
                    .id()
                    .find(id)
                    .ok_or("overview source missing")?;
                if row.generation_id != s.generation_id
                    || [
                        row.base_z.len(),
                        row.soil_depth.len(),
                        row.soil_fertility.len(),
                        row.forest_density.len(),
                        row.moisture.len(),
                    ]
                    .iter()
                    .any(|&n| n != 1024)
                {
                    return Err("invalid overview source".into());
                }
                e.insert(row);
            }
        }
    }
    let mut out = Vec::with_capacity(32);
    for cut in -16..=15 {
        let mut r = TerrainOverviewChunk {
            id: gen::overview_id(lod, cut, cx, cy),
            generation_id: s.generation_id,
            revision: 0,
            lod,
            cut_z: cut,
            chunk_x: cx,
            chunk_y: cy,
            surface_z: Vec::with_capacity(256),
            material: Vec::with_capacity(256),
            soil_fertility: Vec::with_capacity(256),
            forest_density: Vec::with_capacity(256),
            moisture: Vec::with_capacity(256),
        };
        for y in 0..16 {
            for x in 0..16 {
                let (wx, wy) = (
                    (cx * 16 + x) * stride + stride / 2,
                    (cy * 16 + y) * stride + stride / 2,
                );
                if wx >= s.width || wy >= s.height {
                    r.surface_z.push(-17);
                    r.material.push(0);
                    r.soil_fertility.push(0);
                    r.forest_density.push(0);
                    r.moisture.push(0);
                    continue;
                }
                let c = &source[&gen::column_id(wx / 32, wy / 32)];
                let i = (wx % 32 + 32 * (wy % 32)) as usize;
                let z = (i32::from(c.base_z[i]) - 1).min(cut);
                r.surface_z.push(z as i16);
                r.material.push(
                    if z >= i32::from(c.base_z[i]) - i32::from(c.soil_depth[i]) {
                        1
                    } else {
                        2
                    },
                );
                r.soil_fertility.push(c.soil_fertility[i]);
                r.forest_density.push(c.forest_density[i]);
                r.moisture.push(c.moisture[i]);
            }
        }
        out.push(r);
    }
    Ok(out)
}

pub(super) fn refresh_overviews(ctx: &ReducerContext, g: &Geometry) {
    let touched = overview_updates(g);
    for (id, indices) in touched {
        let mut r = ctx
            .db
            .terrain_overview_chunk()
            .id()
            .find(id)
            .expect("complete overview missing");
        let stride = 1i32 << r.lod;
        let mut changed = false;
        for i in indices {
            let (x, y) = (
                (r.chunk_x * 16 + i as i32 % 16) * stride + stride / 2,
                (r.chunk_y * 16 + i as i32 / 16) * stride + stride / 2,
            );
            let (z, m) = exposed(g, x, y, r.cut_z);
            if r.surface_z[i] != z || r.material[i] != m {
                r.surface_z[i] = z;
                r.material[i] = m;
                changed = true;
            }
        }
        if changed {
            r.revision = r.revision.wrapping_add(1);
            ctx.db.terrain_overview_chunk().id().update(r);
        }
    }
}

fn overview_updates(g: &Geometry) -> BTreeMap<u64, BTreeSet<usize>> {
    let mut touched: BTreeMap<u64, BTreeSet<usize>> = BTreeMap::new();
    for &(x, y) in &g.changed_columns {
        for lod in gen::OVERVIEW_LODS {
            let stride = 1i32 << lod;
            if x >= g.width
                || y >= g.height
                || x.rem_euclid(stride) != stride / 2
                || y.rem_euclid(stride) != stride / 2
            {
                continue;
            }
            let (sx, sy) = (x / stride, y / stride);
            let i = (sx % 16 + 16 * (sy % 16)) as usize;
            for cut in g.min_z..=g.max_z {
                touched
                    .entry(gen::overview_id(lod, cut, sx / 16, sy / 16))
                    .or_default()
                    .insert(i);
            }
        }
    }
    touched
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn compact_and_overview_bsatn_row_payloads_have_exact_bounded_sizes() {
        let c = gen::generate_columns(17, 2048, 2048, 31, 31);
        let row = TerrainColumnChunk {
            id: gen::column_id(31, 31),
            chunk_x: 31,
            chunk_y: 31,
            generation_id: 1,
            revision: 0,
            base_z: c.physical.base_z,
            soil_depth: c.physical.soil_depth,
            soil_fertility: c.soil_fertility,
            forest_density: c.forest_density,
            moisture: c.moisture,
        };
        assert_eq!(spacetimedb::sats::bsatn::to_vec(&row).unwrap().len(), 6192);
        let overview = TerrainOverviewChunk {
            id: gen::overview_id(3, 15, 7, 7),
            generation_id: 1,
            revision: 0,
            lod: 3,
            cut_z: 15,
            chunk_x: 7,
            chunk_y: 7,
            surface_z: vec![-1; 256],
            material: vec![1; 256],
            soil_fertility: vec![192; 256],
            forest_density: vec![160; 256],
            moisture: vec![192; 256],
        };
        assert_eq!(
            spacetimedb::sats::bsatn::to_vec(&overview).unwrap().len(),
            1845
        );
    }
    #[test]
    fn overview_targets_only_real_changed_representative_columns_and_cut_exposure() {
        let columns = BTreeMap::from([(
            Cell(0, 0, 0),
            ColumnChunk {
                base_z: vec![0; 1024],
                soil_depth: vec![1; 1024],
            },
        )]);
        let mut g = Geometry::compact(64, 64, columns, 1).unwrap();
        assert!(g.set(Cell(1, 1, -1), 0));
        assert!(overview_updates(&g).is_empty());
        assert_eq!(exposed(&g, 4, 4, 15), (-1, 1));
        assert!(g.set(Cell(4, 4, -1), 0));
        let changed = overview_updates(&g);
        assert_eq!(changed.len(), 32);
        assert_eq!(changed[&gen::overview_id(3, 15, 0, 0)], BTreeSet::from([0]));
        assert_eq!(exposed(&g, 4, 4, 15), (-2, 2));
        assert_eq!(exposed(&g, 4, 4, -3), (-3, 2));
        for z in -16..=-2 {
            assert!(g.set(Cell(4, 4, z), 0));
        }
        assert_eq!(exposed(&g, 4, 4, 15), (-17, 0));
        assert_eq!(g.chunks.len(), 1);
    }
    #[test]
    fn partial_spatial_coverage_never_substitutes_unloaded_override_with_compact_default() {
        let columns = BTreeMap::from([(
            Cell(0, 0, 0),
            ColumnChunk {
                base_z: vec![0; 1024],
                soil_depth: vec![1; 1024],
            },
        )]);
        let mut g = Geometry::compact(64, 64, columns, 1).unwrap();
        g.coverage = Some((0, 0, 15, 15));
        assert_eq!(g.material(Cell(15, 15, -1)), Some(1));
        assert_eq!(g.material(Cell(16, 15, -1)), None);
        let before = g.clone();
        assert!(!g.set(Cell(16, 15, -1), 0));
        assert_eq!(g, before);
        let snapshot = g.clone();
        assert!(g.set(Cell(4, 4, -1), 0));
        assert_eq!(snapshot.material(Cell(4, 4, -1)), Some(1));
        assert_eq!(g.material(Cell(4, 4, -1)), Some(0));
        assert!(Rc::ptr_eq(
            snapshot.columns.as_ref().unwrap(),
            g.columns.as_ref().unwrap()
        ));
    }
}
