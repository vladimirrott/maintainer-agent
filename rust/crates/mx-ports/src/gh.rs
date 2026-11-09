use crate::{Effect, EffectLog, Script, Secret, lock};
use mx_core::{Fact, NonEmpty};
use std::sync::Mutex;
use thiserror::Error;

/// A `gh` call failed. The classes matter: a rejected token is a refusal and an
/// unreachable GitHub is a retry.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum GhError {
    /// GitHub rejected the credentials (HTTP 401).
    #[error("GitHub rejected the credentials (HTTP 401)")]
    Unauthorized,
    /// `gh` could not reach GitHub.
    #[error("gh could not reach GitHub: {0}")]
    Unreachable(String),
    /// `gh` ran and failed for another reason.
    #[error("gh failed: {0}")]
    Failed(String),
}

/// What GitHub says about one pull request. Each field is a [`Fact`] because
/// each can fail to read on its own.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrFacts {
    pub number: u64,
    pub head_sha: Fact<String>,
    pub review_decision: Fact<String>,
    pub merge_state: Fact<String>,
    /// The changed paths. An empty list is not an answer, so it cannot be built.
    pub changed_paths: Fact<NonEmpty<String>>,
}

/// The check counts for a pull request, as `gh pr checks` buckets them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CheckCounts {
    pub pass: u32,
    pub skip: u32,
    pub fail: u32,
    pub pending: u32,
    pub cancel: u32,
    pub total: u32,
}

/// The `gh` operations the identity pin and the merge gate need.
pub trait Gh {
    /// Makes `account` the active `gh` account.
    fn auth_switch(&self, account: &str) -> Result<(), GhError>;

    /// The login `gh` is authenticated as.
    fn login(&self) -> Result<String, GhError>;

    /// The token stored for `account`.
    fn auth_token(&self, account: &str) -> Result<Secret, GhError>;

    /// What GitHub says about a pull request.
    fn pr(&self, number: u64) -> Result<PrFacts, GhError>;

    /// The check counts for a pull request.
    fn pr_checks(&self, number: u64) -> Result<CheckCounts, GhError>;

    /// Merges a pull request only if its head is still `head_sha`. There is no
    /// merge without the head it was verified at.
    fn merge(&self, number: u64, head_sha: &str) -> Result<(), GhError>;
}

/// One call to a [`Gh`]. A token is never recorded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GhEffect {
    AuthSwitch { account: String },
    Login,
    AuthToken { account: String },
    Pr { number: u64 },
    PrChecks { number: u64 },
    Merge { number: u64, head_sha: String },
}

/// A scripted [`Gh`] that records its calls.
#[derive(Debug)]
pub struct FakeGh {
    log: EffectLog,
    auth_switch: Mutex<Script<Result<(), GhError>>>,
    login: Mutex<Script<Result<String, GhError>>>,
    auth_token: Mutex<Script<Result<Secret, GhError>>>,
    pr: Mutex<Script<Result<PrFacts, GhError>>>,
    pr_checks: Mutex<Script<Result<CheckCounts, GhError>>>,
    merge: Mutex<Script<Result<(), GhError>>>,
}

impl FakeGh {
    /// A fake with no scripted answers.
    #[must_use]
    pub fn new(log: &EffectLog) -> Self {
        Self {
            log: log.clone(),
            auth_switch: Mutex::default(),
            login: Mutex::default(),
            auth_token: Mutex::default(),
            pr: Mutex::default(),
            pr_checks: Mutex::default(),
            merge: Mutex::default(),
        }
    }

    /// Scripts the answers to `auth_switch`.
    pub fn script_auth_switch(&self, script: Script<Result<(), GhError>>) {
        *lock(&self.auth_switch) = script;
    }

    /// Scripts the answers to `login`.
    pub fn script_login(&self, script: Script<Result<String, GhError>>) {
        *lock(&self.login) = script;
    }

    /// Scripts the answers to `auth_token`.
    pub fn script_auth_token(&self, script: Script<Result<Secret, GhError>>) {
        *lock(&self.auth_token) = script;
    }

    /// Scripts the answers to `pr`.
    pub fn script_pr(&self, script: Script<Result<PrFacts, GhError>>) {
        *lock(&self.pr) = script;
    }

    /// Scripts the answers to `pr_checks`.
    pub fn script_pr_checks(&self, script: Script<Result<CheckCounts, GhError>>) {
        *lock(&self.pr_checks) = script;
    }

    /// Scripts the answers to `merge`.
    pub fn script_merge(&self, script: Script<Result<(), GhError>>) {
        *lock(&self.merge) = script;
    }
}

impl Gh for FakeGh {
    fn auth_switch(&self, account: &str) -> Result<(), GhError> {
        self.log.push(Effect::Gh(GhEffect::AuthSwitch { account: account.to_string() }));
        lock(&self.auth_switch).next("Gh::auth_switch")
    }

    fn login(&self) -> Result<String, GhError> {
        self.log.push(Effect::Gh(GhEffect::Login));
        lock(&self.login).next("Gh::login")
    }

    fn auth_token(&self, account: &str) -> Result<Secret, GhError> {
        self.log.push(Effect::Gh(GhEffect::AuthToken { account: account.to_string() }));
        lock(&self.auth_token).next("Gh::auth_token")
    }

    fn pr(&self, number: u64) -> Result<PrFacts, GhError> {
        self.log.push(Effect::Gh(GhEffect::Pr { number }));
        lock(&self.pr).next("Gh::pr")
    }

    fn pr_checks(&self, number: u64) -> Result<CheckCounts, GhError> {
        self.log.push(Effect::Gh(GhEffect::PrChecks { number }));
        lock(&self.pr_checks).next("Gh::pr_checks")
    }

    fn merge(&self, number: u64, head_sha: &str) -> Result<(), GhError> {
        self.log.push(Effect::Gh(GhEffect::Merge { number, head_sha: head_sha.to_string() }));
        lock(&self.merge).next("Gh::merge")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_login_retry_sequence_plays_out_and_is_recorded() {
        let log = EffectLog::new();
        let gh = FakeGh::new(&log);
        gh.script_login(Script::sequence([
            Err(GhError::Unreachable("timeout".to_string())),
            Err(GhError::Unreachable("timeout".to_string())),
            Ok("vladimirrott".to_string()),
        ]));
        assert!(matches!(gh.login(), Err(GhError::Unreachable(_))));
        assert!(matches!(gh.login(), Err(GhError::Unreachable(_))));
        assert_eq!(gh.login().unwrap(), "vladimirrott");
        assert_eq!(log.entries(), vec![Effect::Gh(GhEffect::Login); 3]);
    }

    #[test]
    fn a_rejected_token_is_a_different_error_from_an_unreachable_github() {
        assert_ne!(GhError::Unauthorized, GhError::Unreachable("x".to_string()));
    }

    #[test]
    fn the_token_value_never_reaches_the_effect_log() {
        let log = EffectLog::new();
        let gh = FakeGh::new(&log);
        gh.script_auth_token(Script::always(Ok(Secret::new("ghp_value_that_must_not_leak"))));
        let token = gh.auth_token("vladimirrott").unwrap();
        assert_eq!(token.expose(), "ghp_value_that_must_not_leak");
        let recorded = format!("{:?}", log.entries());
        assert!(!recorded.contains("must_not_leak"), "{recorded}");
        assert!(recorded.contains("AuthToken"), "{recorded}");
    }

    #[test]
    fn merge_records_the_head_it_was_fenced_to() {
        let log = EffectLog::new();
        let gh = FakeGh::new(&log);
        gh.script_merge(Script::always(Ok(())));
        gh.merge(12, "0123456789abcdef0123456789abcdef01234567").unwrap();
        assert_eq!(
            log.entries(),
            vec![Effect::Gh(GhEffect::Merge {
                number: 12,
                head_sha: "0123456789abcdef0123456789abcdef01234567".to_string()
            })]
        );
    }

    #[test]
    fn pr_facts_keep_unreadable_fields_apart_from_absent_ones() {
        let log = EffectLog::new();
        let gh = FakeGh::new(&log);
        gh.script_pr(Script::always(Ok(PrFacts {
            number: 5,
            head_sha: Fact::Known("a".repeat(40)),
            review_decision: Fact::Absent,
            merge_state: Fact::Unreadable("gh timed out".to_string()),
            changed_paths: Fact::Known(NonEmpty::new("src/lib.rs".to_string(), [])),
        })));
        let facts = gh.pr(5).unwrap();
        assert!(facts.review_decision.is_absent());
        assert!(facts.merge_state.is_unreadable());
        assert_eq!(facts.changed_paths.known().unwrap().len(), 1);
    }

    #[test]
    fn calls_to_different_methods_are_recorded_in_call_order() {
        let log = EffectLog::new();
        let gh = FakeGh::new(&log);
        gh.script_auth_switch(Script::always(Ok(())));
        gh.script_pr_checks(Script::always(Ok(CheckCounts {
            pass: 3,
            skip: 1,
            fail: 0,
            pending: 0,
            cancel: 0,
            total: 4,
        })));
        gh.auth_switch("vladimirrott").unwrap();
        assert_eq!(gh.pr_checks(9).unwrap().total, 4);
        assert_eq!(
            log.entries(),
            vec![
                Effect::Gh(GhEffect::AuthSwitch { account: "vladimirrott".to_string() }),
                Effect::Gh(GhEffect::PrChecks { number: 9 }),
            ]
        );
    }
}
