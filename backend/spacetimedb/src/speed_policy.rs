//! Pure validation and wall-clock cooldown arithmetic for simulation speed.

pub const MAX_TIME_SCALE: f64 = 100_000.0;
pub const MAX_COOLDOWN_SECONDS: u32 = 3_600;

pub fn validate_time_scale(time_scale: f64) -> Result<(), String> {
    if time_scale.is_finite() && (0.0..=MAX_TIME_SCALE).contains(&time_scale) {
        Ok(())
    } else {
        Err("time_scale must be between 0 and 100000 and finite".into())
    }
}

pub fn validate_cooldown(cooldown_seconds: u32) -> Result<(), String> {
    if cooldown_seconds <= MAX_COOLDOWN_SECONDS {
        Ok(())
    } else {
        Err("cooldown_seconds must be between 0 and 3600".into())
    }
}

/// Return whole seconds still blocked, rounding a fractional second up.
/// A clock moving backwards is treated as no elapsed time, not as a bypass.
pub fn remaining_cooldown_seconds(
    cooldown_seconds: u32,
    now_micros: i64,
    changed_micros: i64,
) -> u32 {
    let cooldown_micros = i64::from(cooldown_seconds) * 1_000_000;
    let elapsed_micros = now_micros.saturating_sub(changed_micros).max(0);
    if elapsed_micros >= cooldown_micros {
        return 0;
    }
    ((cooldown_micros - elapsed_micros) as u64).div_ceil(1_000_000) as u32
}

#[cfg(test)]
mod tests {
    use super::{remaining_cooldown_seconds, validate_cooldown, validate_time_scale};

    #[test]
    fn validates_speed_and_cooldown_ranges_and_finiteness() {
        assert!(validate_time_scale(0.0).is_ok());
        assert!(validate_time_scale(100_000.0).is_ok());
        assert!(validate_time_scale(f64::NAN).is_err());
        assert!(validate_time_scale(f64::INFINITY).is_err());
        assert!(validate_time_scale(-0.1).is_err());
        assert!(validate_cooldown(3_600).is_ok());
        assert!(validate_cooldown(3_601).is_err());
    }

    #[test]
    fn remaining_time_has_exact_boundary_and_fractional_rounding() {
        assert_eq!(remaining_cooldown_seconds(10, 10_000_000, 0), 0);
        assert_eq!(remaining_cooldown_seconds(10, 9_999_999, 0), 1);
        assert_eq!(remaining_cooldown_seconds(10, 9_500_000, 0), 1);
        assert_eq!(remaining_cooldown_seconds(10, 8_999_999, 0), 2);
    }

    #[test]
    fn backwards_clock_keeps_the_full_cooldown() {
        assert_eq!(remaining_cooldown_seconds(10, 99, 100), 10);
    }
}
