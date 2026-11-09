use crate::{Effect, EffectLog, lock};
use std::sync::Mutex;
use std::time::Duration;

/// Time, as the programs use it: seconds since the Unix epoch, and sleeping.
pub trait Clock {
    /// Whole seconds since the Unix epoch.
    fn now_unix(&self) -> u64;

    /// Blocks for `duration`.
    fn sleep(&self, duration: Duration);
}

/// One call to a [`Clock`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClockEffect {
    Now,
    Sleep(Duration),
}

/// A clock that moves only when told to. `sleep` advances it and returns at
/// once, so a retry loop with a backoff runs in no time and the test can still
/// read how long it would have waited.
#[derive(Debug)]
pub struct FakeClock {
    since_epoch: Mutex<Duration>,
    log: EffectLog,
}

impl FakeClock {
    /// A clock showing `unix_secs`.
    #[must_use]
    pub fn at(unix_secs: u64, log: &EffectLog) -> Self {
        Self { since_epoch: Mutex::new(Duration::from_secs(unix_secs)), log: log.clone() }
    }

    /// Moves the clock forward without recording a call.
    pub fn advance(&self, by: Duration) {
        *lock(&self.since_epoch) += by;
    }
}

impl Clock for FakeClock {
    fn now_unix(&self) -> u64 {
        self.log.push(Effect::Clock(ClockEffect::Now));
        lock(&self.since_epoch).as_secs()
    }

    fn sleep(&self, duration: Duration) {
        self.log.push(Effect::Clock(ClockEffect::Sleep(duration)));
        *lock(&self.since_epoch) += duration;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn now_reads_the_set_time_and_records_the_call() {
        let log = EffectLog::new();
        let clock = FakeClock::at(1_000, &log);
        assert_eq!(clock.now_unix(), 1_000);
        assert_eq!(log.entries(), vec![Effect::Clock(ClockEffect::Now)]);
    }

    #[test]
    fn sleep_advances_time_without_waiting_and_records_the_duration() {
        let log = EffectLog::new();
        let clock = FakeClock::at(10, &log);
        let started = std::time::Instant::now();
        clock.sleep(Duration::from_hours(1));
        assert!(started.elapsed() < Duration::from_secs(5), "the fake clock slept for real");
        assert_eq!(clock.now_unix(), 3610);
        assert_eq!(log.entries()[0], Effect::Clock(ClockEffect::Sleep(Duration::from_hours(1))));
    }

    #[test]
    fn advance_moves_time_and_records_nothing() {
        let log = EffectLog::new();
        let clock = FakeClock::at(0, &log);
        clock.advance(Duration::from_secs(7));
        assert!(log.is_empty());
        assert_eq!(clock.now_unix(), 7);
    }
}
