//! Explicit geometry-only growth; never load/save the operational World.
use crate::{
    auth,
    schema::*,
    sim::{
        geometry::{Cell, Chunk, Geometry},
        world_generation,
    },
};
use spacetimedb::{ReducerContext, Table};
use std::collections::{BTreeMap, BTreeSet};

#[spacetimedb::reducer]
pub fn expand_world_varied(ctx: &ReducerContext, width: i32, height: i32) -> Result<(), String> {
    auth::authorize(ctx, auth::RequiredRole::Admin)?;
    crate::persistence::large_world::require_legacy_ready(ctx)?;
    let mut bounds = ctx
        .db
        .world_geometry()
        .id()
        .find(0)
        .ok_or("world geometry missing")?;
    if !(1..=256).contains(&width)
        || !(1..=256).contains(&height)
        || width < bounds.width
        || height < bounds.height
    {
        return Err("varied expansion requires grow-only dimensions in 1..=256".into());
    }
    if (width, height) == (bounds.width, bounds.height) {
        return Ok(());
    }
    let seed = ctx
        .db
        .world_seed()
        .id()
        .find(0)
        .ok_or("world seed missing")?
        .seed;
    let mut chunks = BTreeMap::new();
    for row in ctx.db.terrain_chunk().iter() {
        if chunks
            .insert(
                Cell(row.chunk_x, row.chunk_y, row.chunk_z),
                Chunk {
                    id: row.id,
                    materials: row.materials,
                    revision: row.revision,
                },
            )
            .is_some()
        {
            return Err("duplicate terrain chunk coordinate".into());
        }
    }
    let old_ids: BTreeSet<_> = chunks.values().map(|c| c.id).collect();
    let mut g = Geometry {
        width: bounds.width,
        height: bounds.height,
        min_z: bounds.min_z,
        max_z: bounds.max_z,
        chunks,
        columns: None,
        coverage: None,
        next_chunk_id: 1,
        changed: BTreeSet::new(),
        changed_columns: BTreeSet::new(),
        designations: Vec::new(),
        nav_epoch: 0,
        dirty_jobs: BTreeSet::new(),
        dirty_designations: BTreeSet::new(),
    };
    world_generation::expand(&mut g, seed, width, height)?;
    for key in &g.changed {
        let c = &g.chunks[key];
        let row = TerrainChunk {
            id: c.id,
            chunk_x: key.0,
            chunk_y: key.1,
            chunk_z: key.2,
            materials: c.materials.clone(),
            revision: c.revision,
        };
        if old_ids.contains(&c.id) {
            ctx.db.terrain_chunk().id().update(row);
        } else {
            ctx.db.terrain_chunk().insert(row);
        }
    }
    bounds.width = width;
    bounds.height = height;
    ctx.db.world_geometry().id().update(bounds);
    Ok(())
}
