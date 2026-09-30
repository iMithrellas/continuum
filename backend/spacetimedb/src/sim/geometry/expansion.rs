//! Explicit horizontal growth. Never regenerate the old material rectangle.
use super::*;

pub(super) fn validate_dimensions(width: i32, height: i32) -> Result<(), String> {
    if !(1..=MAX_WORLD_EDGE).contains(&width) || !(1..=MAX_WORLD_EDGE).contains(&height) {
        return Err(format!(
            "world dimensions must be positive integers at most {MAX_WORLD_EDGE}"
        ));
    }
    Ok(())
}

fn flat_material(z: i32) -> u16 {
    match z {
        -1 => SOIL,
        ..=-2 => STONE,
        _ => AIR,
    }
}

pub(super) fn flat_chunk(key: Cell, width: i32, height: i32, min_z: i32, max_z: i32) -> Vec<u16> {
    let mut materials = vec![AIR; (EDGE * EDGE * EDGE) as usize];
    for z in 0..EDGE {
        let world_z = key.2 * EDGE + z;
        if !(min_z..=max_z).contains(&world_z) {
            continue;
        }
        for y in 0..EDGE {
            for x in 0..EDGE {
                if key.0 * EDGE + x < width && key.1 * EDGE + y < height {
                    materials[(x + EDGE * (y + EDGE * z)) as usize] = flat_material(world_z);
                }
            }
        }
    }
    materials
}

impl Geometry {
    /// Grow only, preserving all old cells, jobs, chunk identities and elevations.
    /// Equal dimensions are an idempotent no-op. New land uses migration-flat
    /// strata, NOT another hillside or new facilities. Former padding is seeded
    /// explicitly, including air, so stale padding cannot become boundary ghosts.
    pub fn expand(&mut self, width: i32, height: i32) -> Result<(), String> {
        validate_dimensions(width, height)?;
        if width < self.width || height < self.height {
            return Err("world expansion cannot shrink either dimension".into());
        }
        if (width, height) == (self.width, self.height) {
            return Ok(());
        }
        // Expansion is not corruption repair. A missing old chunk must never be
        // silently filled, since that could invent support or erase excavations.
        for z in self.min_z.div_euclid(EDGE)..=self.max_z.div_euclid(EDGE) {
            for y in 0..(self.height + EDGE - 1) / EDGE {
                for x in 0..(self.width + EDGE - 1) / EDGE {
                    if self
                        .chunks
                        .get(&Cell(x, y, z))
                        .is_none_or(|c| c.materials.len() != 4096)
                    {
                        return Err("cannot expand incomplete authoritative geometry".into());
                    }
                }
            }
        }
        let mut missing = Vec::new();
        for z in self.min_z.div_euclid(EDGE)..=self.max_z.div_euclid(EDGE) {
            for y in 0..(height + EDGE - 1) / EDGE {
                for x in 0..(width + EDGE - 1) / EDGE {
                    let key = Cell(x, y, z);
                    if !self.chunks.contains_key(&key) {
                        missing.push(key);
                    }
                }
            }
        }
        let max_id = self.chunks.values().map(|c| c.id).max().unwrap_or(0);
        max_id
            .checked_add(missing.len() as u64)
            .ok_or("chunk ID exhausted")?;
        let epoch = self
            .nav_epoch
            .checked_add(1)
            .ok_or("terrain mutation epoch exhausted")?;
        // All failure checks precede any mutation, also for callers outside a DB
        // transaction. Allocate durable IDs beyond the maximum, never by coords.
        for (index, key) in missing.into_iter().enumerate() {
            self.chunks.insert(
                key,
                Chunk {
                    id: max_id + index as u64 + 1,
                    materials: flat_chunk(key, width, height, self.min_z, self.max_z),
                    revision: 0,
                },
            );
            self.changed.insert(key);
        }
        for (&key, chunk) in &mut self.chunks {
            if key.0 * EDGE >= self.width || key.1 * EDGE >= self.height {
                continue; // entirely new chunks already contain their strata
            }
            let mut modified = false;
            for z in 0..EDGE {
                let world_z = key.2 * EDGE + z;
                if !(self.min_z..=self.max_z).contains(&world_z) {
                    continue;
                }
                for y in 0..EDGE {
                    for x in 0..EDGE {
                        let (wx, wy) = (key.0 * EDGE + x, key.1 * EDGE + y);
                        if wx >= width || wy >= height || (wx < self.width && wy < self.height) {
                            continue;
                        }
                        let i = (x + EDGE * (y + EDGE * z)) as usize;
                        let material = flat_material(world_z);
                        if chunk.materials[i] != material {
                            chunk.materials[i] = material;
                            modified = true;
                        }
                    }
                }
            }
            if modified && self.changed.insert(key) {
                chunk.revision = chunk.revision.wrapping_add(1);
            }
        }
        self.width = width;
        self.height = height;
        self.nav_epoch = epoch;
        Ok(())
    }
}
