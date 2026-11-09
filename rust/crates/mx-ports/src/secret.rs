use std::fmt;

/// A value that must not be printed: a token or a key.
///
/// `Debug` prints `Secret(<redacted>)`. There is no `Display`. The only way to
/// read the value is [`Secret::expose`], which makes each use visible in review.
#[derive(Clone, PartialEq, Eq)]
pub struct Secret(String);

impl Secret {
    /// Wraps a value.
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    /// The value. Pass it to a child through the environment, never through argv.
    #[must_use]
    pub fn expose(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Secret(<redacted>)")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn debug_never_shows_the_value() {
        let secret = Secret::new("ghp_supersecret");
        assert!(!format!("{secret:?}").contains("supersecret"));
        assert_eq!(format!("{secret:?}"), "Secret(<redacted>)");
    }

    #[test]
    fn expose_returns_the_value() {
        assert_eq!(Secret::new("abc").expose(), "abc");
    }
}
