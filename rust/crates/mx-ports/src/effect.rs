use crate::{ClockEffect, ContainerEffect, FsEffect, GhEffect, GitEffect, ProcEffect, lock};
use std::sync::{Arc, Mutex};

/// One recorded call to a port.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Effect {
    Gh(GhEffect),
    Git(GitEffect),
    Containers(ContainerEffect),
    Clock(ClockEffect),
    Fs(FsEffect),
    Proc(ProcEffect),
}

/// The calls made through the fakes, in order.
///
/// Clones share one list. Give every fake the same log to see the order of
/// calls across ports, for example that a lease is cleared after a token is
/// scrubbed.
#[derive(Debug, Clone, Default)]
pub struct EffectLog(Arc<Mutex<Vec<Effect>>>);

impl EffectLog {
    /// An empty log.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Appends one call.
    pub fn push(&self, effect: Effect) {
        lock(&self.0).push(effect);
    }

    /// A copy of every call so far.
    #[must_use]
    pub fn entries(&self) -> Vec<Effect> {
        lock(&self.0).clone()
    }

    /// How many calls were recorded.
    #[must_use]
    pub fn len(&self) -> usize {
        lock(&self.0).len()
    }

    /// True when no call was recorded.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        lock(&self.0).is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn clones_share_one_list() {
        let log = EffectLog::new();
        let other = log.clone();
        other.push(Effect::Clock(ClockEffect::Now));
        assert_eq!(log.len(), 1);
        assert!(!log.is_empty());
    }

    #[test]
    fn entries_keep_call_order() {
        let log = EffectLog::new();
        log.push(Effect::Clock(ClockEffect::Now));
        log.push(Effect::Clock(ClockEffect::Sleep(Duration::from_secs(2))));
        assert_eq!(
            log.entries(),
            vec![
                Effect::Clock(ClockEffect::Now),
                Effect::Clock(ClockEffect::Sleep(Duration::from_secs(2)))
            ]
        );
    }
}
