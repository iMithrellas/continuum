//! Version-one deterministic physical landscape. No database or per-cell entities.
use super::geometry::{Body, Cell, Geometry, AIR, EDGE, SOIL, STONE};

pub const PROTECTED_EDGE: i32 = 32;
pub const COLUMN_EDGE: i32 = 32;
pub const LARGE_WORLD_EDGE: i32 = 2048;
pub const MAX_LARGE_WORLD_EDGE: i32 = 8192;
pub const OVERVIEW_LODS: [u8; 4] = [3, 5, 7, 9];

#[derive(Clone, Debug, PartialEq)]
pub struct ColumnChunk {
    pub base_z: Vec<i16>,
    pub soil_depth: Vec<u8>,
}
impl ColumnChunk {
    pub fn material(&self, c: Cell) -> Option<u16> {
        let i = (c.0.rem_euclid(32) + 32 * c.1.rem_euclid(32)) as usize;
        Some(
            Column {
                base_z: i32::from(*self.base_z.get(i)?),
                soil_depth: i32::from(*self.soil_depth.get(i)?),
            }
            .material(c.2),
        )
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct GeneratedColumns {
    pub physical: ColumnChunk,
    pub soil_fertility: Vec<u8>,
    pub forest_density: Vec<u8>,
    pub moisture: Vec<u8>,
}

pub fn validate_large_dimensions(width: i32, height: i32) -> Result<(), String> {
    if !(64..=MAX_LARGE_WORLD_EDGE).contains(&width)
        || !(64..=MAX_LARGE_WORLD_EDGE).contains(&height)
    {
        return Err(format!(
            "large world dimensions must be 64..={MAX_LARGE_WORLD_EDGE}"
        ));
    }
    Ok(())
}
pub fn column_id(x: i32, y: i32) -> u64 {
    ((y as u64) << 32) | x as u64
}
/// Packs 8-bit LOD, 8-bit cut offset, 24-bit Y, and 24-bit X after bounds validation.
pub fn overview_id(lod: u8, cut_z: i32, x: i32, y: i32) -> u64 {
    ((lod as u64) << 56) | (((cut_z + 16) as u64) << 48) | ((y as u64) << 24) | x as u64
}
pub fn centered_origin(width: i32, height: i32) -> (i32, i32) {
    (width / 2 - 12, height / 2 - 12)
}

pub fn centered_sample(seed: u64, x: i32, y: i32, origin: (i32, i32)) -> Column {
    let distance = (origin.0 - 4 - x)
        .max(x - origin.0 - 27)
        .max(origin.1 - 4 - y)
        .max(y - origin.1 - 27)
        .max(0);
    Column {
        base_z: (field(seed, x, y, 48, 16) - 6).clamp(-distance, distance),
        soil_depth: if distance == 0 {
            1
        } else {
            (field(seed ^ 0xa54f_f53a_5f1d_36f1, x, y, 32, 6) - 1).max(0)
        },
    }
}
pub fn generate_columns(seed: u64, width: i32, height: i32, cx: i32, cy: i32) -> GeneratedColumns {
    let origin = centered_origin(width, height);
    let mut out = GeneratedColumns {
        physical: ColumnChunk {
            base_z: Vec::with_capacity(1024),
            soil_depth: Vec::with_capacity(1024),
        },
        soil_fertility: Vec::with_capacity(1024),
        forest_density: Vec::with_capacity(1024),
        moisture: Vec::with_capacity(1024),
    };
    for y in 0..32 {
        for x in 0..32 {
            let (wx, wy) = (cx * 32 + x, cy * 32 + y);
            let c = if wx < width && wy < height {
                centered_sample(seed, wx, wy, origin)
            } else {
                Column {
                    base_z: -16,
                    soil_depth: 0,
                }
            };
            let protected = (origin.0 - 4..=origin.0 + 27).contains(&wx)
                && (origin.1 - 4..=origin.1 + 27).contains(&wy);
            let mut moisture = if wx < width && wy < height {
                field(seed ^ 0x9e37_79b9_7f4a_7c15, wx, wy, 48, 255) as u8
            } else {
                0
            };
            if protected {
                moisture = moisture.max(192);
            }
            let mut fertility = if c.soil_depth == 0 {
                0
            } else {
                ((u32::from(moisture) + c.soil_depth as u32 * 42) / 2).min(255) as u8
            };
            let mut forest = if c.soil_depth == 0 {
                0
            } else {
                ((field(seed ^ 0x243f_6a88_85a3_08d3, wx, wy, 32, 255) + i32::from(moisture)) / 2)
                    as u8
            };
            if protected {
                fertility = fertility.max(192);
                forest = forest.max(160);
            }
            out.physical.base_z.push(c.base_z as i16);
            out.physical.soil_depth.push(c.soil_depth as u8);
            out.moisture.push(moisture);
            out.soil_fertility.push(fertility);
            out.forest_density.push(forest);
        }
    }
    out
}

/// Row-major horizontal overview tile list, independent of the 32 cut rows.
pub fn overview_tiles(width: i32, height: i32) -> Vec<(u8, i32, i32)> {
    let mut out = Vec::new();
    for lod in OVERVIEW_LODS {
        let edge = 16 * (1i32 << lod);
        for y in 0..(height + edge - 1) / edge {
            for x in 0..(width + edge - 1) / edge {
                out.push((lod, x, y));
            }
        }
    }
    out
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Column {
    /// Feet elevation of the exposed supported surface, not a cosmetic value.
    pub base_z: i32,
    pub soil_depth: i32,
}
impl Column {
    pub fn material(self, z: i32) -> u16 {
        if z >= self.base_z {
            AIR
        } else if z >= self.base_z - self.soil_depth {
            SOIL
        } else {
            STONE
        }
    }
}

fn hash(seed: u64, x: i32, y: i32) -> u64 {
    let mut v = seed
        ^ (x as u64).wrapping_mul(0x9e37_79b9_7f4a_7c15)
        ^ (y as u64).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    v = (v ^ (v >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    v = (v ^ (v >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    v ^ (v >> 31)
}

/// Integer bilinear field. Maximum cardinal gradient is range / spacing;
/// elevation's 16/48 gradient leaves ample margin for one-cell terrace steps.
fn field(seed: u64, x: i32, y: i32, spacing: i32, range: i32) -> i32 {
    let (cx, cy) = (x.div_euclid(spacing), y.div_euclid(spacing));
    let (tx, ty) = (x.rem_euclid(spacing), y.rem_euclid(spacing));
    let value = |dx, dy| (hash(seed, cx + dx, cy + dy) % (range as u64 + 1)) as i32;
    let a = value(0, 0) * (spacing - tx) + value(1, 0) * tx;
    let b = value(0, 1) * (spacing - tx) + value(1, 1) * tx;
    (a * (spacing - ty) + b * ty).div_euclid(spacing * spacing)
}

pub fn sample(seed: u64, x: i32, y: i32) -> Column {
    let distance = (x - PROTECTED_EDGE + 1).max(y - PROTECTED_EDGE + 1).max(0);
    Column {
        base_z: (field(seed, x, y, 48, 16) - 6).clamp(-distance, distance),
        soil_depth: if distance == 0 {
            1
        } else {
            field(seed ^ 0xa54f_f53a_5f1d_36f1, x, y, 32, 6).saturating_sub(1)
        },
    }
}

fn surface(g: &Geometry, x: i32, y: i32) -> Option<i32> {
    (g.min_z..=g.max_z - 3)
        .rev()
        .find(|&z| g.supported(Cell(x, y, z), Body::default()))
}

/// Fill only outside the old rectangle. Complete interior chunks are skipped;
/// partial boundary chunks retain their IDs and increment revision at most once.
fn fill(g: &mut Geometry, old_w: i32, old_h: i32, column: impl Fn(i32, i32) -> Column) {
    for (&key, chunk) in &mut g.chunks {
        if (key.0 + 1) * EDGE <= old_w && (key.1 + 1) * EDGE <= old_h {
            continue;
        }
        let mut modified = false;
        for y in 0..EDGE {
            for x in 0..EDGE {
                let (wx, wy) = (key.0 * EDGE + x, key.1 * EDGE + y);
                if wx >= g.width || wy >= g.height || (wx < old_w && wy < old_h) {
                    continue;
                }
                let c = column(wx, wy);
                for z in 0..EDGE {
                    let wz = key.2 * EDGE + z;
                    let i = (x + EDGE * (y + EDGE * z)) as usize;
                    let m = c.material(wz);
                    if chunk.materials[i] != m {
                        chunk.materials[i] = m;
                        modified = true;
                    }
                }
            }
        }
        if modified && g.changed.insert(key) {
            chunk.revision = chunk.revision.wrapping_add(1);
        }
    }
}

/// Seeded growth with an apron anchored to the actual old supported boundary.
/// Excavated shafts/unsupported edges are not repaired; their apron uses z=0.
/// Existing cliff discontinuities remain, but a flat old edge joins in <=1 steps.
pub fn expand(g: &mut Geometry, seed: u64, width: i32, height: i32) -> Result<(), String> {
    if !(1..=256).contains(&width)
        || !(1..=256).contains(&height)
        || width < g.width
        || height < g.height
    {
        return Err("varied expansion requires grow-only dimensions in 1..=256".into());
    }
    if (width, height) == (g.width, g.height) {
        return Ok(());
    }
    if !(1..=256).contains(&g.width)
        || !(1..=256).contains(&g.height)
        || g.min_z != -16
        || g.max_z != 15
        || g.chunks
            .values()
            .any(|c| c.materials.len() != 4096 || c.materials.iter().any(|&m| m > STONE))
    {
        return Err("unsupported authoritative geometry".into());
    }
    let ids: std::collections::BTreeSet<_> = g.chunks.values().map(|c| c.id).collect();
    if ids.len() != g.chunks.len()
        || g.chunks.keys().any(|k| {
            k.0 < 0
                || k.1 < 0
                || k.0 >= (g.width + 15) / 16
                || k.1 >= (g.height + 15) / 16
                || !(-1..=0).contains(&k.2)
        })
    {
        return Err("invalid authoritative chunk identity or coordinate".into());
    }
    let (old_w, old_h) = (g.width, g.height);
    let east: Vec<_> = (0..old_h)
        .map(|y| surface(g, old_w - 1, y).unwrap_or(0))
        .collect();
    let south: Vec<_> = (0..old_w)
        .map(|x| surface(g, x, old_h - 1).unwrap_or(0))
        .collect();
    g.expand(width, height)?;
    fill(g, old_w, old_h, |x, y| {
        let mut c = sample(seed, x, y);
        let (anchor, distance) = if x >= old_w && y >= old_h {
            (
                east[(old_h - 1) as usize],
                (x - old_w + 1).max(y - old_h + 1),
            )
        } else if x >= old_w {
            (east[y as usize], x - old_w + 1)
        } else {
            (south[x as usize], y - old_h + 1)
        };
        c.base_z = c.base_z.clamp(anchor - distance, anchor + distance);
        c
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deterministic_physical_terraces_have_soils_bedrock_and_clear_steps() {
        for seed in [0, 1, 0x6c6f_6e67_7365_6565, u64::MAX] {
            let mut columns = std::collections::BTreeMap::new();
            for cy in 0..8 {
                for cx in 0..8 {
                    let c = generate_columns(seed, 256, 256, cx, cy);
                    assert_eq!(c, generate_columns(seed, 256, 256, cx, cy));
                    columns.insert(Cell(cx, cy, 0), c.physical);
                }
            }
            let g = Geometry::compact(256, 256, columns, 1).unwrap();
            let mut elevations = std::collections::BTreeSet::new();
            let mut depths = std::collections::BTreeSet::new();
            for y in 0..256 {
                for x in 0..256 {
                    let c = centered_sample(seed, x, y, centered_origin(256, 256));
                    elevations.insert(c.base_z);
                    depths.insert(c.soil_depth);
                    assert!(g.supported(Cell(x, y, c.base_z), Body::default()));
                    for (dx, dy) in [(1, 0), (0, 1)] {
                        if x + dx >= 256 || y + dy >= 256 {
                            continue;
                        }
                        let n = centered_sample(seed, x + dx, y + dy, centered_origin(256, 256));
                        assert!((c.base_z - n.base_z).abs() <= 1);
                        if !((22..24).contains(&(x + dx)) && (8..12).contains(&(y + dy))) {
                            assert!(g.can_step(
                                Cell(x, y, c.base_z),
                                Cell(x + dx, y + dy, n.base_z),
                                Body::default()
                            ));
                        }
                    }
                    assert_eq!(
                        g.material(Cell(x, y, c.base_z - 1)),
                        Some(if c.soil_depth > 0 { SOIL } else { STONE })
                    );
                }
            }
            assert!(elevations.len() >= 8, "{seed}: {elevations:?}");
            assert!(
                depths.contains(&0) && depths.len() >= 4,
                "{seed}: {depths:?}"
            );
            assert!(g.chunks.is_empty());
        }
        assert_ne!(
            generate_columns(1, 256, 256, 0, 0),
            generate_columns(2, 256, 256, 0, 0)
        );
    }

    #[test]
    fn protected_colony_and_fixture_are_identical_to_legacy_seed() {
        let old = Geometry::seeded();
        let mut columns = std::collections::BTreeMap::new();
        for y in 31..33 {
            for x in 31..33 {
                columns.insert(
                    Cell(x, y, 0),
                    generate_columns(19, 2048, 2048, x, y).physical,
                );
            }
        }
        let mut g = Geometry::compact(2048, 2048, columns, 1).unwrap();
        let (ox, oy) = centered_origin(2048, 2048);
        for z in 0..6 {
            for y in 8..12 {
                for x in 22..24 {
                    assert!(g.set(Cell(ox + x, oy + y, z), STONE));
                }
            }
        }
        for z in -16..=15 {
            for y in 0..28 {
                for x in 0..28 {
                    assert_eq!(
                        g.material(Cell(ox + x, oy + y, z)),
                        old.material(Cell(x, y, z))
                    );
                }
            }
        }
        assert_eq!(g.chunks.len(), 1);
        assert_eq!(g.next_chunk_id, 2);
        let fixture = g
            .designate(1, ox + 22, oy + 8, ox + 23, oy + 11, 0, 6, 2)
            .unwrap();
        assert_eq!(fixture.cells.len(), 48);
        assert!(g.set(Cell(ox, oy, -1), AIR));
        assert_eq!(g.material(Cell(ox, oy, -1)), Some(AIR));
        assert!(!g.supported(Cell(ox, oy, 0), Body::default()));
    }

    #[test]
    fn complete_2048_baseline_is_only_twelve_mib_physical_and_never_dense_voxels() {
        let mut columns = std::collections::BTreeMap::new();
        let mut bytes = 0;
        for y in 0..64 {
            for x in 0..64 {
                let c = generate_columns(17, 2048, 2048, x, y);
                assert_eq!(c.physical.base_z.len(), 1024);
                assert_eq!(c.physical.soil_depth.len(), 1024);
                assert!(c.physical.base_z.iter().all(|&z| (-6..=10).contains(&z)));
                assert!(c.physical.soil_depth.iter().all(|&z| z <= 5));
                bytes += c.physical.base_z.len() * 2 + c.physical.soil_depth.len();
                columns.insert(Cell(x, y, 0), c.physical);
            }
        }
        assert_eq!(bytes, 12 * 1024 * 1024);
        let g = Geometry::compact(2048, 2048, columns, 1).unwrap();
        assert!(g.chunks.is_empty());
        assert_eq!(g.columns.as_ref().unwrap().len(), 4096);
        assert!(g.supported(Cell(1024, 1024, 0), Body::default()));
        assert_eq!(overview_tiles(2048, 2048).len() * 32, 8768);
        for (w, h) in [(0, 2048), (8193, 2048), (2048, i32::MAX)] {
            assert!(validate_large_dimensions(w, h).is_err());
        }
        assert!(validate_large_dimensions(8192, 8192).is_ok());
    }

    #[test]
    fn partial_chunk_growth_preserves_old_bytes_ids_revisions_jobs_and_ramps() {
        let mut g = Geometry::flat();
        g.set(Cell(3, 3, -1), AIR);
        g.designations
            .push(g.designate(7, 4, 4, 5, 5, -2, 1, 3).unwrap());
        g.changed.clear();
        let old = g.clone();
        expand(&mut g, 7, 256, 256).unwrap();
        for z in -16..=15 {
            for y in 0..24 {
                for x in 0..24 {
                    assert_eq!(g.material(Cell(x, y, z)), old.material(Cell(x, y, z)));
                }
            }
        }
        for (key, c) in &old.chunks {
            assert_eq!(g.chunks[key].id, c.id);
            if key.0 == 0 && key.1 == 0 {
                assert_eq!(&g.chunks[key], c);
            } else {
                assert!(
                    g.chunks[key].revision == c.revision
                        || g.chunks[key].revision == c.revision + 1
                );
            }
        }
        assert_eq!(g.designations, old.designations);
        assert_eq!(g.dirty_jobs, old.dirty_jobs);
        assert_eq!(g.dirty_designations, old.dirty_designations);
        for y in 0..24 {
            let z = surface(&g, 24, y).unwrap();
            assert!(g.can_step(Cell(23, y, 0), Cell(24, y, z), Body::default()));
        }
        let before = g.clone();
        expand(&mut g, 7, 256, 256).unwrap();
        assert_eq!(g, before);
    }

    #[test]
    fn invalid_growth_is_atomic_including_missing_chunks_and_exhaustion() {
        for (w, h) in [(0, 256), (257, 256), (23, 256), (256, -1), (i32::MAX, 256)] {
            let mut g = Geometry::flat();
            let old = g.clone();
            assert!(expand(&mut g, 1, w, h).is_err());
            assert_eq!(g, old);
        }
        for corruption in 0..5 {
            let mut g = Geometry::flat();
            match corruption {
                0 => {
                    g.chunks.remove(&Cell(0, 0, -1));
                }
                1 => {
                    g.chunks.get_mut(&Cell(0, 0, -1)).unwrap().materials.pop();
                }
                2 => {
                    g.min_z = -17;
                }
                3 => {
                    g.chunks.get_mut(&Cell(0, 0, -1)).unwrap().id = u64::MAX;
                }
                _ => {
                    g.chunks.get_mut(&Cell(0, 0, -1)).unwrap().materials[0] = 99;
                }
            }
            let old = g.clone();
            assert!(expand(&mut g, 1, 256, 256).is_err());
            assert_eq!(g, old);
        }
    }
}
