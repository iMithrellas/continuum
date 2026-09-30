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
    for (id, name, density, strength, conductivity, heat, opaque) in [
        (0, "air", 1.225, 0.0, 0.025, 1005.0, false),
        (1, "soil", 1600.0, 150_000.0, 1.5, 800.0, true),
        (2, "stone", 2700.0, 100_000_000.0, 2.5, 790.0, true),
    ] {
        ctx.db.terrain_material().insert(TerrainMaterial {
            id,
            name: name.into(),
            density,
            strength,
            thermal_conductivity: conductivity,
            specific_heat_capacity: heat,
            opaque,
        });
    }
    for d in &g.designations {
        write_designation(ctx, d);
    }
}

pub(super) fn reset(ctx: &ReducerContext) {
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

pub(super) fn load(ctx: &ReducerContext) -> Geometry {
    if ctx.db.world_geometry().id().find(0).is_none() {
        install(ctx, &Geometry::flat());
    }
    let row = ctx.db.world_geometry().id().find(0).unwrap();
    let chunks = ctx
        .db
        .terrain_chunk()
        .iter()
        .map(|c| {
            assert_eq!(
                c.materials.len(),
                4096,
                "invalid authoritative terrain chunk"
            );
            chunk_state(c)
        })
        .collect();
    let mut designations: Vec<_> = ctx
        .db
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
        .collect();
    designations.sort_by_key(|d| d.id);
    Geometry {
        width: row.width,
        height: row.height,
        min_z: row.min_z,
        max_z: row.max_z,
        chunks,
        changed: BTreeSet::new(),
        designations,
    }
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
        ctx.db.terrain_chunk().id().update(chunk_row(key, chunk));
    }
    for d in &g.designations {
        write_designation(ctx, d);
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
