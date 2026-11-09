use crate::Refusal;
use std::fmt::Display;

/// What a read of the outside world produced.
///
/// A page that has not loaded and a page with nothing on it look the same from
/// outside, and so do a `gh` call that failed and a `gh` call that found
/// nothing. `Fact` keeps them apart:
///
/// - [`Fact::Known`]: the value was read.
/// - [`Fact::Absent`]: the read succeeded and the thing is not there.
/// - [`Fact::Unreadable`]: the read could not be made, with the reason.
///
/// The rule every method here keeps: **`Unreadable` never becomes `Absent`**.
/// There is deliberately no `Default`, no `unwrap_or`, and no conversion into
/// `Option`, because each of those folds the third state into "nothing".
#[derive(Debug, Clone, PartialEq, Eq)]
#[must_use = "a Fact that is never inspected is a check that never ran"]
pub enum Fact<T> {
    /// The value was read.
    Known(T),
    /// The read succeeded and the thing does not exist.
    Absent,
    /// The read could not be made; the string says why.
    Unreadable(String),
}

impl<T> Fact<T> {
    /// Builds a fact from a read that may fail: `Ok(Some)` is known, `Ok(None)`
    /// is absent, and an error is unreadable with the error's text.
    pub fn from_result<E: Display>(result: Result<Option<T>, E>) -> Self {
        match result {
            Ok(Some(value)) => Self::Known(value),
            Ok(None) => Self::Absent,
            Err(error) => Self::Unreadable(error.to_string()),
        }
    }

    /// The value when it was read.
    ///
    /// `None` means "not known" and covers both `Absent` and `Unreadable`. Use
    /// it to decline to go on. When the difference changes the outcome, use
    /// [`Fact::absent_ok`] or [`Fact::require`].
    #[must_use]
    pub fn known(self) -> Option<T> {
        match self {
            Self::Known(value) => Some(value),
            Self::Absent | Self::Unreadable(_) => None,
        }
    }

    /// True when the value was read.
    #[must_use]
    pub fn is_known(&self) -> bool {
        matches!(self, Self::Known(_))
    }

    /// True only when the read succeeded and found nothing. An unreadable fact
    /// is not absent.
    #[must_use]
    pub fn is_absent(&self) -> bool {
        matches!(self, Self::Absent)
    }

    /// True when the read could not be made.
    #[must_use]
    pub fn is_unreadable(&self) -> bool {
        matches!(self, Self::Unreadable(_))
    }

    /// For a thing whose absence is an acceptable answer: `Known` gives
    /// `Some`, `Absent` gives `None`, and `Unreadable` is a refusal.
    ///
    /// `what` names the thing, for the refusal text.
    pub fn absent_ok(self, what: impl Into<String>) -> Result<Option<T>, Refusal> {
        match self {
            Self::Known(value) => Ok(Some(value)),
            Self::Absent => Ok(None),
            Self::Unreadable(reason) => Err(Refusal::Unreadable { what: what.into(), reason }),
        }
    }

    /// For a thing that must be there: `Known` gives the value, `Absent` is
    /// [`Refusal::Missing`], and `Unreadable` is [`Refusal::Unreadable`].
    pub fn require(self, what: impl Into<String>) -> Result<T, Refusal> {
        match self {
            Self::Known(value) => Ok(value),
            Self::Absent => Err(Refusal::Missing { what: what.into() }),
            Self::Unreadable(reason) => Err(Refusal::Unreadable { what: what.into(), reason }),
        }
    }

    /// Applies `f` to a known value and leaves the other two states alone.
    pub fn map<U>(self, f: impl FnOnce(T) -> U) -> Fact<U> {
        match self {
            Self::Known(value) => Fact::Known(f(value)),
            Self::Absent => Fact::Absent,
            Self::Unreadable(reason) => Fact::Unreadable(reason),
        }
    }

    /// Borrows the value inside a known fact.
    pub fn as_ref(&self) -> Fact<&T> {
        match self {
            Self::Known(value) => Fact::Known(value),
            Self::Absent => Fact::Absent,
            Self::Unreadable(reason) => Fact::Unreadable(reason.clone()),
        }
    }
}

impl<T> From<Option<T>> for Fact<T> {
    /// An `Option` has no unreadable state, so `Some` is known and `None` is
    /// absent. The reverse conversion does not exist on purpose.
    fn from(option: Option<T>) -> Self {
        match option {
            Some(value) => Self::Known(value),
            None => Self::Absent,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unreadable() -> Fact<u32> {
        Fact::Unreadable("permission denied".to_string())
    }

    #[test]
    fn known_gives_the_value() {
        assert_eq!(Fact::Known(7).known(), Some(7));
    }

    #[test]
    fn known_is_none_for_absent_and_for_unreadable() {
        assert_eq!(Fact::<u32>::Absent.known(), None);
        assert_eq!(unreadable().known(), None);
    }

    #[test]
    fn unreadable_is_never_absent() {
        let fact = unreadable();
        assert!(!fact.is_absent());
        assert!(fact.is_unreadable());
        assert!(!fact.is_known());
    }

    #[test]
    fn absent_ok_accepts_absent_as_none() {
        assert_eq!(Fact::<u32>::Absent.absent_ok("lease"), Ok(None));
    }

    #[test]
    fn absent_ok_accepts_known_as_some() {
        assert_eq!(Fact::Known(3).absent_ok("lease"), Ok(Some(3)));
    }

    #[test]
    fn absent_ok_refuses_unreadable_instead_of_reading_it_as_absent() {
        let refusal = unreadable().absent_ok("lease on #5").unwrap_err();
        assert_eq!(
            refusal,
            Refusal::Unreadable {
                what: "lease on #5".to_string(),
                reason: "permission denied".to_string()
            }
        );
    }

    #[test]
    fn require_returns_the_known_value() {
        assert_eq!(Fact::Known(9).require("head"), Ok(9));
    }

    #[test]
    fn require_turns_absent_into_missing() {
        let refusal = Fact::<u32>::Absent.require("head").unwrap_err();
        assert_eq!(refusal, Refusal::Missing { what: "head".to_string() });
    }

    #[test]
    fn require_turns_unreadable_into_unreadable_not_missing() {
        let refusal = unreadable().require("head").unwrap_err();
        assert!(matches!(refusal, Refusal::Unreadable { .. }), "got {refusal:?}");
    }

    #[test]
    fn map_changes_known_and_keeps_the_other_states() {
        assert_eq!(Fact::Known(2).map(|n| n * 10), Fact::Known(20));
        assert_eq!(Fact::<u32>::Absent.map(|n| n * 10), Fact::Absent);
        assert_eq!(unreadable().map(|n| n * 10), unreadable());
    }

    #[test]
    fn as_ref_keeps_the_state() {
        assert_eq!(Fact::Known(4).as_ref(), Fact::Known(&4));
        assert!(Fact::<u32>::Absent.as_ref().is_absent());
        assert!(unreadable().as_ref().is_unreadable());
    }

    #[test]
    fn from_result_separates_a_failed_read_from_an_empty_one() {
        let known: Fact<u32> = Fact::from_result(Ok::<_, String>(Some(1)));
        let absent: Fact<u32> = Fact::from_result(Ok::<_, String>(None));
        let failed: Fact<u32> = Fact::from_result(Err("timeout".to_string()));
        assert_eq!(known, Fact::Known(1));
        assert_eq!(absent, Fact::Absent);
        assert_eq!(failed, Fact::Unreadable("timeout".to_string()));
    }

    #[test]
    fn an_option_converts_to_known_or_absent_only() {
        assert_eq!(Fact::from(Some(5)), Fact::Known(5));
        assert_eq!(Fact::<u32>::from(None), Fact::Absent);
    }
}
