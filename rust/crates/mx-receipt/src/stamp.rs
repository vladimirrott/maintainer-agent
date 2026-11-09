//! The two fields a receipt takes from its surroundings: when, and by whom.

/// `recorded_at` and `recorded_by`. The bash gate reads them from
/// `datetime.now().astimezone().isoformat()` and `getpass.getuser()`; the
/// library takes them as values so a test can fix them and no clock is read
/// here.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Stamp {
    pub recorded_at: String,
    pub recorded_by: String,
}

impl Stamp {
    #[must_use]
    pub fn new(recorded_at: impl Into<String>, recorded_by: impl Into<String>) -> Self {
        Self { recorded_at: recorded_at.into(), recorded_by: recorded_by.into() }
    }
}

/// Python's `datetime.isoformat()` for an aware datetime: seconds since the
/// Unix epoch (UTC) plus microseconds, shown at a fixed UTC offset.
///
/// The fraction `.ffffff` is left out when `micros` is 0, as Python leaves it
/// out, and the offset is `+HH:MM`, with `:SS` added only when the offset has
/// a seconds part.
#[must_use]
pub fn iso_with_offset(unix_secs: i64, micros: u32, offset_secs: i32) -> String {
    let local = unix_secs + i64::from(offset_secs);
    let days = local.div_euclid(86_400);
    let secs_of_day = local.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    let (hour, minute, second) = (secs_of_day / 3600, secs_of_day % 3600 / 60, secs_of_day % 60);
    let fraction = if micros == 0 { String::new() } else { format!(".{micros:06}") };
    let sign = if offset_secs < 0 { '-' } else { '+' };
    let off = offset_secs.unsigned_abs();
    let (oh, om, os) = (off / 3600, off % 3600 / 60, off % 60);
    let offset_seconds = if os == 0 { String::new() } else { format!(":{os:02}") };
    format!(
        "{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}{fraction}{sign}{oh:02}:{om:02}{offset_seconds}"
    )
}

/// Days since 1970-01-01 to a proleptic Gregorian date (Howard Hinnant's algorithm).
fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_epoch_in_utc() {
        assert_eq!(iso_with_offset(0, 0, 0), "1970-01-01T00:00:00+00:00");
    }

    #[test]
    fn the_golden_fixture_instant() {
        assert_eq!(iso_with_offset(1_767_225_600, 0, 0), "2026-01-01T00:00:00+00:00");
    }

    #[test]
    fn a_positive_offset_shifts_the_clock_and_prints_plus() {
        assert_eq!(iso_with_offset(1_767_225_600, 0, 3 * 3600), "2026-01-01T03:00:00+03:00");
    }

    #[test]
    fn a_negative_half_hour_offset_crosses_midnight_backwards() {
        let want = "2025-12-31T18:30:00-05:30";
        assert_eq!(iso_with_offset(1_767_225_600, 0, -(5 * 3600 + 1800)), want);
    }

    #[test]
    fn microseconds_print_six_digits_and_are_left_out_at_zero() {
        assert_eq!(iso_with_offset(1_767_225_600, 120_000, 0), "2026-01-01T00:00:00.120000+00:00");
        assert_eq!(iso_with_offset(1_767_225_600, 1, 0), "2026-01-01T00:00:00.000001+00:00");
    }

    #[test]
    fn a_leap_day_and_the_day_after() {
        // 2024-02-29T12:00:00Z and 2024-03-01T00:00:00Z.
        assert_eq!(iso_with_offset(1_709_208_000, 0, 0), "2024-02-29T12:00:00+00:00");
        assert_eq!(iso_with_offset(1_709_251_200, 0, 0), "2024-03-01T00:00:00+00:00");
    }

    #[test]
    fn an_offset_with_seconds_adds_the_seconds_part_like_python() {
        assert_eq!(iso_with_offset(0, 0, 3600 + 30), "1970-01-01T01:00:30+01:00:30");
    }

    #[test]
    fn a_date_before_the_epoch() {
        assert_eq!(iso_with_offset(-86_400, 0, 0), "1969-12-31T00:00:00+00:00");
    }
}
