use super::*;
use sim::geometry::{Cell, Chunk, Designation, Geometry};
use std::collections::BTreeSet;

fn install(ctx: &ReducerContext, g: &Geometry) {
    ctx.db.world_geometry().insert(WorldGeometry {
        id: 0,
        width: g.width,
        height: g.height,
        min_z: g.min_z,
        max_z: g.max_z,
    });
    for (&Cell(x, y, z), chunk) in &g.chunks {
        ctx.db
            .terrain_chunk()
            .insert(chunk_row(Cell(x, y, z), chunk));
    }
    install_materials(ctx);
    for d in &g.designations {
        write_designation(ctx, d);
    }
}

pub(super) fn install_materials(ctx: &ReducerContext) {
    for (id, name, density, strength, conductivity, heat, opaque) in [
        (0, "air", 1.225, 0.0, 0.025, 1005.0, false),
        (1, "soil", 1600.0, 150_000.0, 1.5, 800.0, true),
        (2, "stone", 2700.0, 100_000_000.0, 2.5, 790.0, true),
    ] {
        let row = TerrainMaterial {
            id,
            name: name.into(),
            density,
            strength,
            thermal_conductivity: conductivity,
            specific_heat_capacity: heat,
            opaque,
        };
        if ctx.db.terrain_material().id().find(id).is_some() {
            ctx.db.terrain_material().id().update(row);
        } else {
            ctx.db.terrain_material().insert(row);
        }
    }
}

fn designation_write_plan(g: &Geometry) -> impl Iterator<Item = (&Designation, bool, bool)> {
    g.designations.iter().filter_map(|d| {
        let public = g.dirty_designations.contains(&d.id);
        let private = g.dirty_jobs.contains(&d.id);
        (public || private).then_some((d, public, private))
    })
}

#[allow(dead_code)]
pub(super) fn reset(ctx: &ReducerContext, _seed: u64) {
    for row in ctx.db.world_geometry().iter() {
        ctx.db.world_geometry().id().delete(row.id);
    }
    for row in ctx.db.terrain_chunk().iter() {
        ctx.db.terrain_chunk().id().delete(row.id);
    }
    for row in ctx.db.terrain_material().iter() {
        ctx.db.terrain_material().id().delete(row.id);
    }
    for row in ctx.db.excavation_designation().iter() {
        ctx.db.excavation_designation().id().delete(row.id);
    }
    for row in ctx.db.excavation_jobs().iter() {
        ctx.db.excavation_jobs().id().delete(row.id);
    }
    let mut g = Geometry::seeded();
    g.designations[0].id = 0;
    install(ctx, &g);
}

pub(crate) fn load(ctx: &ReducerContext) -> Geometry {
    load_with_jobs(ctx, true, None)
}

/// Placement reads only material authority; do not deserialize unrelated job vectors.
pub(crate) fn load_for_placement(ctx: &ReducerContext, rect: crate::blocks::Rect) -> Geometry {
    load_with_jobs(ctx, false, Some(rect))
}

pub(crate) fn load_region(ctx: &ReducerContext, rect: crate::blocks::Rect) -> Geometry {
    load_with_jobs(ctx, true, Some(rect))
}

fn load_with_jobs(
    ctx: &ReducerContext,
    include_jobs: bool,
    region: Option<crate::blocks::Rect>,
) -> Geometry {
    if ctx.db.world_geometry().id().find(0).is_none() {
        install(ctx, &Geometry::flat());
    }
    let row = ctx.db.world_geometry().id().find(0).unwrap();
    let coverage = region.map(|r| {
        (
            r.min_x.div_euclid(16) * 16,
            r.min_y.div_euclid(16) * 16,
            ((r.max_x.div_euclid(16) + 1) * 16 - 1).min(row.width - 1),
            ((r.max_y.div_euclid(16) + 1) * 16 - 1).min(row.height - 1),
        )
    });
    let source: Vec<_> = if let Some((x0, y0, x1, y1)) = coverage {
        let mut out = Vec::new();
        for x in x0 / 16..=x1 / 16 {
            out.extend(
                ctx.db
                    .terrain_chunk()
                    .by_xyz()
                    .filter((x, y0 / 16..=y1 / 16)),
            );
        }
        out
    } else {
        ctx.db.terrain_chunk().iter().collect()
    };
    let chunks = source
        .into_iter()
        .map(|c| {
            assert_eq!(
                c.materials.len(),
                4096,
                "invalid authoritative terrain chunk"
            );
            chunk_state(c)
        })
        .collect();
    let mut designations: Vec<_> = if include_jobs {
        ctx.db
            .excavation_designation()
            .iter()
            .map(|d| {
                let cells = ctx
                    .db
                    .excavation_jobs()
                    .id()
                    .find(d.id)
                    .expect("designation jobs missing")
                    .cells;
                designation_state(d, cells)
            })
            .collect()
    } else {
        Vec::new()
    };
    designations.sort_by_key(|d| d.id);
    Geometry {
        width: row.width,
        height: row.height,
        min_z: row.min_z,
        max_z: row.max_z,
        chunks,
        columns: crate::persistence::large_world::load_columns_region(ctx, coverage),
        coverage,
        next_chunk_id: ctx
            .db
            .terrain_override_allocator()
            .id()
            .find(0)
            .map(|r| r.next_id)
            .unwrap_or(1),
        changed: BTreeSet::new(),
        changed_columns: BTreeSet::new(),
        designations,
        nav_epoch: 0,
        dirty_jobs: BTreeSet::new(),
        dirty_designations: BTreeSet::new(),
    }
}

/// Geometry-only transaction: expansion must not repair actors, backfill terrain
/// fields, save resources, rewrite intents or advance the clock as a side effect.
pub(crate) fn expand(ctx: &ReducerContext, width: i32, height: i32) -> Result<(), String> {
    let mut g = load(ctx);
    g.expand(width, height)?;
    for &key in &g.changed {
        let chunk = &g.chunks[&key];
        let row = chunk_row(key, chunk);
        if ctx.db.terrain_chunk().id().find(chunk.id).is_some() {
            ctx.db.terrain_chunk().id().update(row);
        } else {
            ctx.db.terrain_chunk().insert(row);
        }
    }
    let mut row = ctx.db.world_geometry().id().find(0).unwrap();
    if (row.width, row.height) != (width, height) {
        row.width = width;
        row.height = height;
        ctx.db.world_geometry().id().update(row);
    }
    Ok(())
}

pub(crate) fn write_designation(ctx: &ReducerContext, d: &Designation) -> u64 {
    let row = designation_row(d);
    let id = if d.id != 0 && ctx.db.excavation_designation().id().find(d.id).is_some() {
        ctx.db.excavation_designation().id().update(row).id
    } else {
        ctx.db.excavation_designation().insert(row).id
    };
    let jobs = ExcavationJobs {
        id,
        cells: d.cells.clone(),
    };
    if ctx.db.excavation_jobs().id().find(id).is_some() {
        ctx.db.excavation_jobs().id().update(jobs);
    } else {
        ctx.db.excavation_jobs().insert(jobs);
    }
    id
}

pub(super) fn save(ctx: &ReducerContext, g: &Geometry) {
    for &key in &g.changed {
        let chunk = &g.chunks[&key];
        let row = chunk_row(key, chunk);
        if ctx.db.terrain_chunk().id().find(chunk.id).is_some() {
            ctx.db.terrain_chunk().id().update(row);
        } else {
            ctx.db.terrain_chunk().insert(row);
        }
    }
    if g.columns.is_some() {
        let mut allocator = ctx
            .db
            .terrain_override_allocator()
            .id()
            .find(0)
            .expect("override allocator missing");
        if allocator.next_id < g.next_chunk_id {
            allocator.next_id = g.next_chunk_id;
            ctx.db.terrain_override_allocator().id().update(allocator);
        }
        super::large_world::refresh_overviews(ctx, g);
    }
    for (d, public, private) in designation_write_plan(g) {
        if public {
            ctx.db
                .excavation_designation()
                .id()
                .update(designation_row(d));
        }
        if private {
            ctx.db.excavation_jobs().id().update(ExcavationJobs {
                id: d.id,
                cells: d.cells.clone(),
            });
        }
    }
}

fn chunk_row(key: Cell, c: &Chunk) -> TerrainChunk {
    TerrainChunk {
        id: c.id,
        chunk_x: key.0,
        chunk_y: key.1,
        chunk_z: key.2,
        materials: c.materials.clone(),
        revision: c.revision,
    }
}
fn chunk_state(c: TerrainChunk) -> (Cell, Chunk) {
    (
        Cell(c.chunk_x, c.chunk_y, c.chunk_z),
        Chunk {
            id: c.id,
            materials: c.materials,
            revision: c.revision,
        },
    )
}
fn designation_row(d: &Designation) -> ExcavationDesignation {
    ExcavationDesignation {
        id: d.id,
        x0: d.x0,
        y0: d.y0,
        x1: d.x1,
        y1: d.y1,
        bottom_z: d.bottom_z,
        height: d.height,
        priority: d.priority,
        enabled: d.enabled,
        total_cells: d.cells.len() as u32,
        completed_cells: d.completed(),
    }
}
fn designation_state(
    d: ExcavationDesignation,
    cells: Vec<sim::geometry::MiningCell>,
) -> Designation {
    assert_eq!(d.total_cells, cells.len() as u32);
    let state = Designation {
        id: d.id,
        x0: d.x0,
        y0: d.y0,
        x1: d.x1,
        y1: d.y1,
        bottom_z: d.bottom_z,
        height: d.height,
        priority: d.priority,
        enabled: d.enabled,
        cells,
    };
    assert_eq!(d.completed_cells, state.completed());
    state
}

#[cfg(test)]
mod tests {
    use super::*;
    use spacetimedb::sats::bsatn;
    #[test]
    fn designation_write_plan_omits_unchanged_paused_and_completed_vectors() {
        let mut w = sim::new_world();
        w.geometry = Some(Geometry::seeded());
        w.colonists.truncate(1);
        w.colonists[0].assignment.work = sim::WorkType::None;
        let g = w.geometry.as_mut().unwrap();
        g.designations[0].enabled = false;
        assert_eq!(designation_write_plan(g).count(), 0);
        sim::step(&mut w, &sim::Tuning::default(), 0.0);
        assert_eq!(
            designation_write_plan(w.geometry.as_ref().unwrap()).count(),
            0
        );
        sim::step(&mut w, &sim::Tuning::default(), 60.0);
        assert_eq!(
            designation_write_plan(w.geometry.as_ref().unwrap()).count(),
            0
        );
        let g = w.geometry.as_mut().unwrap();
        for c in &mut g.designations[0].cells {
            c.material = 0;
            c.progress = 1.0;
        }
        g.dirty_jobs.clear();
        g.dirty_designations.clear();
        assert_eq!(designation_write_plan(g).count(), 0);
        g.dirty_jobs.insert(g.designations[0].id);
        let plan: Vec<_> = designation_write_plan(g)
            .map(|(d, p, j)| (d.id, p, j))
            .collect();
        assert_eq!(plan, vec![(1, false, true)]);
        g.dirty_designations.insert(1);
        assert_eq!(
            designation_write_plan(g)
                .map(|(d, p, j)| (d.id, p, j))
                .collect::<Vec<_>>(),
            vec![(1, true, true)]
        );
    }
    #[test]
    fn chunk_mapping_and_wire_roundtrip_preserve_negative_origin_and_every_cell() {
        let key = Cell(1, 0, -1);
        let c = Chunk {
            id: 89,
            materials: (0..4096).map(|i| (i % 3) as u16).collect(),
            revision: 71,
        };
        let bytes = bsatn::to_vec(&chunk_row(key, &c)).unwrap();
        let row: TerrainChunk = bsatn::from_slice(&bytes).unwrap();
        assert_eq!(chunk_state(row), (key, c));
    }
    #[test]
    fn designation_and_private_progress_roundtrip_preserve_all_fields() {
        let mut g = Geometry::flat();
        let mut d = g.designate(17, 4, 3, 2, 1, -6, 3, 1).unwrap();
        d.enabled = false;
        d.cells[0].material = 0;
        d.cells[0].progress = 1.0;
        d.cells[1].progress = 0.625;
        let row: ExcavationDesignation =
            bsatn::from_slice(&bsatn::to_vec(&designation_row(&d)).unwrap()).unwrap();
        assert_eq!(row.completed_cells, 1);
        let private = ExcavationJobs {
            id: 17,
            cells: d.cells.clone(),
        };
        let jobs: ExcavationJobs = bsatn::from_slice(&bsatn::to_vec(&private).unwrap()).unwrap();
        assert_eq!(jobs.id, 17);
        assert_eq!(designation_state(row, jobs.cells), d);
        g.designations.push(d);
    }
}
