//! Deterministic, continuous environmental fields for the colony grid.

const OCTAVES: usize = 4;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TerrainFields {
    pub soil_fertility: f32,
    pub forest_density: f32,
    pub moisture: f32,
}

/// Generate overlapping environmental fields for one tile coordinate.
pub fn sample(seed: u64, x: i32, y: i32) -> TerrainFields {
    let moisture = fbm(
        seed ^ 0x9e37_79b9_7f4a_7c15,
        x as f64 * 0.11,
        y as f64 * 0.11,
    );
    let soil = fbm(
        seed ^ 0xa54f_f53a_5f1d_36f1,
        x as f64 * 0.14,
        y as f64 * 0.14,
    );
    let forest = fbm(
        seed ^ 0x243f_6a88_85a3_08d3,
        x as f64 * 0.12,
        y as f64 * 0.12,
    );

    TerrainFields {
        soil_fertility: contrast(0.68 * soil + 0.32 * moisture),
        forest_density: contrast(0.62 * forest + 0.38 * moisture),
        moisture: contrast(moisture),
    }
}

fn fbm(seed: u64, x: f64, y: f64) -> f32 {
    let mut total = 0.0;
    let mut amplitude = 1.0;
    let mut frequency = 1.0;
    let mut amplitude_sum = 0.0;
    for octave in 0..OCTAVES {
        total += gradient_noise(
            seed.wrapping_add(octave as u64 * 0x517c_c1b7_2722_0a95),
            x * frequency,
            y * frequency,
        ) * amplitude;
        amplitude_sum += amplitude;
        amplitude *= 0.5;
        frequency *= 2.0;
    }
    ((total / amplitude_sum) * 0.5 + 0.5).clamp(0.0, 1.0) as f32
}

fn gradient_noise(seed: u64, x: f64, y: f64) -> f64 {
    let x0 = x.floor() as i64;
    let y0 = y.floor() as i64;
    let tx = x - x.floor();
    let ty = y - y.floor();
    let n00 = gradient(seed, x0, y0, tx, ty);
    let n10 = gradient(seed, x0 + 1, y0, tx - 1.0, ty);
    let n01 = gradient(seed, x0, y0 + 1, tx, ty - 1.0);
    let n11 = gradient(seed, x0 + 1, y0 + 1, tx - 1.0, ty - 1.0);
    let u = fade(tx);
    let v = fade(ty);
    lerp(lerp(n00, n10, u), lerp(n01, n11, u), v)
}

fn gradient(seed: u64, x: i64, y: i64, dx: f64, dy: f64) -> f64 {
    let mut z = seed
        ^ (x as u64).wrapping_mul(0x9e37_79b9_7f4a_7c15)
        ^ (y as u64).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    z ^= z >> 30;
    z = z.wrapping_mul(0xbf58_476d_1ce4_e5b9);
    z ^= z >> 27;
    match z & 3 {
        0 => dx,
        1 => -dx,
        2 => dy,
        _ => -dy,
    }
}

fn fade(t: f64) -> f64 {
    t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
}

fn lerp(a: f64, b: f64, t: f64) -> f64 {
    a + (b - a) * t
}

fn clamp01(value: f32) -> f32 {
    value.clamp(0.0, 1.0)
}

fn contrast(value: f32) -> f32 {
    clamp01((value - 0.5) * 2.2 + 0.5)
}

#[cfg(test)]
mod tests {
    use super::*;

    const DEFAULT_SEED: u64 = 0x6c6f_6e67_7365_6564;

    #[test]
    fn default_grid_is_varied_and_has_overlapping_rich_forest() {
        let values: Vec<_> = (0..24)
            .flat_map(|y| (0..24).map(move |x| sample(DEFAULT_SEED, x, y)))
            .collect();
        let soil_min = values.iter().map(|v| v.soil_fertility).fold(1.0, f32::min);
        let soil_max = values.iter().map(|v| v.soil_fertility).fold(0.0, f32::max);
        let overlap = values
            .iter()
            .filter(|v| v.soil_fertility > 0.6 && v.forest_density > 0.6)
            .count();
        assert!(soil_max - soil_min > 0.15);
        assert!(overlap > 8);
    }

    #[test]
    fn sampling_is_seeded_bounded_and_continuous() {
        let a = sample(DEFAULT_SEED, 7, 11);
        assert_eq!(a, sample(DEFAULT_SEED, 7, 11));
        assert_ne!(a, sample(DEFAULT_SEED + 1, 7, 11));
        for value in [a.soil_fertility, a.forest_density, a.moisture] {
            assert!((0.0..=1.0).contains(&value));
        }
        let b = sample(DEFAULT_SEED, 8, 11);
        assert!((a.soil_fertility - b.soil_fertility).abs() < 0.35);
        assert!((a.forest_density - b.forest_density).abs() < 0.35);
    }
}
