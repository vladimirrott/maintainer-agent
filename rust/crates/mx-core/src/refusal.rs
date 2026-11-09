use thiserror::Error;

/// Success, or a clean skip.
pub const EXIT_OK: i32 = 0;
/// A refusal or failure: the program declined and says why.
pub const EXIT_FAIL: i32 = 1;
/// Bad usage, or a missing tree, profile or task.
pub const EXIT_USAGE: i32 = 64;
/// A transient condition (`EX_TEMPFAIL`). The next timer tick is the fix.
pub const EXIT_TEMPFAIL: i32 = 75;
/// A configuration refusal (`EX_CONFIG`): the run is not allowed here.
pub const EXIT_CONFIG: i32 = 78;

/// Every way a magent program declines to go on.
///
/// The classes come from the behaviour contracts of `maintainer-merge` (exit 1
/// for every refusal, 64 for usage and profile load) and `lib/run.sh` (0, 1,
/// 64, 75 and 78). [`Refusal::exit_code`] has no catch-all arm, so adding a
/// variant without choosing its exit code does not compile.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum Refusal {
    // ----- run.sh: a clean skip (0) -----
    /// The cadence gate found the last run too recent.
    #[error("{task} ran {age_hours} h ago and needs {min_hours} h between runs; skipping")]
    CadenceNotDue { task: String, age_hours: u64, min_hours: u64 },

    // ----- usage, missing input and profile load (64) -----
    /// The command line is wrong.
    #[error("usage: {message}")]
    Usage { message: String },
    /// A directory or file the program locates its tree by is missing.
    #[error("the tree is incomplete: {what}")]
    TreeIncomplete { what: String },
    /// The named profile has no `profile.env`.
    #[error("no profile '{profile}'")]
    ProfileNotFound { profile: String },
    /// The profile or its defaults did not load.
    #[error("the profile did not load: {reason}")]
    ProfileLoadFailed { reason: String },
    /// The task is not one the profile declares.
    #[error("unknown task '{task}'")]
    UnknownTask { task: String },
    /// The profile names a backend that does not exist.
    #[error("no backend '{backend}'")]
    BackendNotFound { backend: String },

    // ----- transient, the next timer tick is the fix (75) -----
    /// Another run held the lock past the wait.
    #[error("{what} was locked for over {waited_secs}s, so this run never started")]
    LockTimeout { what: String, waited_secs: u64 },
    /// `gh` could not reach GitHub in any of its tries.
    #[error("gh could not reach GitHub in {tries} tries, so the identity was never verified")]
    GhUnreachable { tries: u32 },
    /// The pinned token could not be resolved to an account.
    #[error("the pinned token could not be resolved to an account: {reason}")]
    TokenUnresolved { reason: String },
    /// The backend stopped on a reason that heals by itself, before any report.
    #[error("the {backend} backend stopped on {reason}")]
    BackendStopped { backend: String, reason: String },

    // ----- the run is not allowed here (78) -----
    /// A run started from inside another run.
    #[error("already inside the run '{run_id}'; refusing to start another")]
    NestedRun { run_id: String },
    /// The backend has no per-command deny list, so POST=off cannot be enforced.
    #[error("backend '{backend}' cannot enforce POST=off")]
    BackendCannotRehearse { backend: String },
    /// POST=off needs a rehearsal wall and none is rendered.
    #[error("POST=off but backend '{backend}' has no rehearsal wall rendered for '{profile}'")]
    RehearsalWallMissing { profile: String, backend: String },
    /// The backend may run only some tasks, and this is not one.
    #[error("backend '{backend}' may only run: {allowed} (refused '{task}')")]
    TaskNotAllowed { backend: String, task: String, allowed: String },

    // ----- run.sh: identity and run-time refusals (1) -----
    /// GitHub rejected the stored token (HTTP 401).
    #[error("GitHub rejected the stored token for {account} (HTTP 401)")]
    TokenRejected { account: String },
    /// `gh` is signed in as someone other than the profile's account.
    #[error("gh is authenticated as '{actual}', not {expected}")]
    IdentityMismatch { expected: String, actual: String },
    /// No token could be pinned for the account.
    #[error("could not pin a token for {account}, so the run's identity is not guaranteed")]
    TokenNotPinned { account: String },
    /// The backend cannot run on this machine.
    #[error("backend {backend} is unusable: {reason}")]
    BackendUnusable { backend: String, reason: String },
    /// The review checkout is missing and cannot be provisioned.
    #[error("no usable review checkout at {path}: {reason}")]
    CheckoutUnavailable { path: String, reason: String },
    /// `maintainer start` failed or gave no run id.
    #[error("refreshing the checkout failed: {reason}")]
    RefreshFailed { reason: String },
    /// The doctrine file the prompt needs is missing.
    #[error("{file} is missing; refusing to run without the doctrine")]
    DoctrineMissing { file: String },
    /// The run wrote no report, or `finish` refused the one it wrote.
    #[error("{run_id} has no usable report: {reason}")]
    ReportUnusable { run_id: String, reason: String },

    // ----- maintainer-merge and shared: facts, arguments (1) -----
    /// A required fact is absent.
    #[error("{what} is missing")]
    Missing { what: String },
    /// A fact could not be read, so the program does not guess.
    #[error("could not read {what}: {reason}")]
    Unreadable { what: String, reason: String },
    /// The pull request argument is not a positive integer.
    #[error("pull request must be a positive integer, not '{given}'")]
    InvalidPrNumber { given: String },
    /// The suite name on the command line is not a suite of this profile.
    #[error("no suite '{name}'")]
    UnknownSuite { name: String },
    /// An unattended run may not do this.
    #[error("an unattended run may not {action}")]
    NotForUnattendedRun { action: String },
    /// Another verify or merge of the same pull request holds the lock.
    #[error("{what} is already running in this state directory")]
    AlreadyRunning { what: String },

    // ----- maintainer-merge: receipts (1) -----
    /// There is no verification receipt for the pull request.
    #[error("no verification receipt for #{pr}")]
    ReceiptMissing { pr: u64 },
    /// The receipt is unreadable, unsigned, tampered with, or for something else.
    #[error("the receipt for #{pr} is not valid: {reason}")]
    ReceiptInvalid { pr: u64, reason: String },
    /// The receipt no longer describes the pull request.
    #[error("the receipt for #{pr} is stale: {reason}")]
    ReceiptStale { pr: u64, reason: String },
    /// The head moved after it was read.
    #[error("#{pr} is at {actual}, not {expected}; it moved while it was being read")]
    HeadMoved { pr: u64, expected: String, actual: String },

    // ----- maintainer-merge: verification (1) -----
    /// No suite covers every changed production path.
    #[error("suite coverage: {reason}")]
    SuiteCoverage { reason: String },
    /// There is no container runtime to verify in.
    #[error("no container runtime; install podman or docker")]
    NoContainerRuntime,
    /// The extracted tree has symlinks that point outside it.
    #[error("the tree for #{pr} has symlinks pointing outside itself")]
    TreeEscape { pr: u64 },
    /// The unmutated run did not pass, or was killed, so nothing was proved.
    #[error("the unmutated run for #{pr} did not pass: {reason}")]
    CleanRunFailed { pr: u64, reason: String },
    /// The mutation did not apply, changed nothing, or landed outside production code.
    #[error("the mutation for #{pr} proves nothing: {reason}")]
    MutationInvalid { pr: u64, reason: String },
    /// The test still passes with the guard removed.
    #[error("the guard does not bite: '{filter}' still passes with the mutation applied (#{pr})")]
    GuardDoesNotBite { pr: u64, filter: String },
    /// The test filter ran nothing, so a pass proves nothing.
    #[error("'{filter}' produced no evidence it ran anything (#{pr})")]
    EvidenceVacuous { pr: u64, filter: String },
    /// A dependency bump could not be verified as a pure bump.
    #[error("#{pr} is not a verified dependency bump: {reason}")]
    DependencyUnverified { pr: u64, reason: String },

    // ----- maintainer-merge: merge conditions (1) -----
    /// Another actor holds the lease on the pull request.
    #[error("another actor has leased #{pr}: {holders}")]
    Leased { pr: u64, holders: String },
    /// The review decision is not APPROVED.
    #[error("#{pr} reviewDecision is '{decision}', not APPROVED")]
    NotApproved { pr: u64, decision: String },
    /// The account has no approval of the current head.
    #[error("{account} has no standing approval of #{pr} at {head}")]
    NoStandingApproval { pr: u64, account: String, head: String },
    /// GitHub reports a merge state that may not merge.
    #[error("#{pr} mergeStateStatus is '{state}'; only CLEAN and HAS_HOOKS may merge")]
    MergeStateBlocked { pr: u64, state: String },
    /// The checks are failing, pending, cancelled, empty or all skipped.
    #[error("the checks on #{pr} are not green: {reason}")]
    ChecksNotGreen { pr: u64, reason: String },
    /// An issue the pull request closes carries a claim that this merge would override.
    #[error("#{pr} closes #{issue}: {reason}")]
    ClaimConflict { pr: u64, issue: u64, reason: String },
    /// GitHub refused the merge or the branch update, or it was not confirmed.
    #[error("GitHub did not complete the change to #{pr}: {reason}")]
    MergeRefused { pr: u64, reason: String },
}

impl Refusal {
    /// The process exit code for this refusal.
    ///
    /// The `match` lists every variant and has no `_` arm. A new variant fails
    /// to compile here until it is given a code.
    #[must_use]
    pub fn exit_code(&self) -> i32 {
        match self {
            Self::CadenceNotDue { .. } => EXIT_OK,

            Self::Usage { .. }
            | Self::TreeIncomplete { .. }
            | Self::ProfileNotFound { .. }
            | Self::ProfileLoadFailed { .. }
            | Self::UnknownTask { .. }
            | Self::BackendNotFound { .. } => EXIT_USAGE,

            Self::LockTimeout { .. }
            | Self::GhUnreachable { .. }
            | Self::TokenUnresolved { .. }
            | Self::BackendStopped { .. } => EXIT_TEMPFAIL,

            Self::NestedRun { .. }
            | Self::BackendCannotRehearse { .. }
            | Self::RehearsalWallMissing { .. }
            | Self::TaskNotAllowed { .. } => EXIT_CONFIG,

            Self::TokenRejected { .. }
            | Self::IdentityMismatch { .. }
            | Self::TokenNotPinned { .. }
            | Self::BackendUnusable { .. }
            | Self::CheckoutUnavailable { .. }
            | Self::RefreshFailed { .. }
            | Self::DoctrineMissing { .. }
            | Self::ReportUnusable { .. }
            | Self::Missing { .. }
            | Self::Unreadable { .. }
            | Self::InvalidPrNumber { .. }
            | Self::UnknownSuite { .. }
            | Self::NotForUnattendedRun { .. }
            | Self::AlreadyRunning { .. }
            | Self::ReceiptMissing { .. }
            | Self::ReceiptInvalid { .. }
            | Self::ReceiptStale { .. }
            | Self::HeadMoved { .. }
            | Self::SuiteCoverage { .. }
            | Self::NoContainerRuntime
            | Self::TreeEscape { .. }
            | Self::CleanRunFailed { .. }
            | Self::MutationInvalid { .. }
            | Self::GuardDoesNotBite { .. }
            | Self::EvidenceVacuous { .. }
            | Self::DependencyUnverified { .. }
            | Self::Leased { .. }
            | Self::NotApproved { .. }
            | Self::NoStandingApproval { .. }
            | Self::MergeStateBlocked { .. }
            | Self::ChecksNotGreen { .. }
            | Self::ClaimConflict { .. }
            | Self::MergeRefused { .. } => EXIT_FAIL,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Who may produce a refusal. A merge-gate refusal exits 1 or 64 only.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    enum Scope {
        Run,
        Merge,
        Shared,
    }

    /// The position of a variant in `table()`. The `match` has no `_` arm, so a
    /// new variant fails to compile here until it has a row in the table.
    fn rank(refusal: &Refusal) -> usize {
        match refusal {
            Refusal::CadenceNotDue { .. } => 0,
            Refusal::Usage { .. } => 1,
            Refusal::TreeIncomplete { .. } => 2,
            Refusal::ProfileNotFound { .. } => 3,
            Refusal::ProfileLoadFailed { .. } => 4,
            Refusal::UnknownTask { .. } => 5,
            Refusal::BackendNotFound { .. } => 6,
            Refusal::LockTimeout { .. } => 7,
            Refusal::GhUnreachable { .. } => 8,
            Refusal::TokenUnresolved { .. } => 9,
            Refusal::BackendStopped { .. } => 10,
            Refusal::NestedRun { .. } => 11,
            Refusal::BackendCannotRehearse { .. } => 12,
            Refusal::RehearsalWallMissing { .. } => 13,
            Refusal::TaskNotAllowed { .. } => 14,
            Refusal::TokenRejected { .. } => 15,
            Refusal::IdentityMismatch { .. } => 16,
            Refusal::TokenNotPinned { .. } => 17,
            Refusal::BackendUnusable { .. } => 18,
            Refusal::CheckoutUnavailable { .. } => 19,
            Refusal::RefreshFailed { .. } => 20,
            Refusal::DoctrineMissing { .. } => 21,
            Refusal::ReportUnusable { .. } => 22,
            Refusal::Missing { .. } => 23,
            Refusal::Unreadable { .. } => 24,
            Refusal::InvalidPrNumber { .. } => 25,
            Refusal::UnknownSuite { .. } => 26,
            Refusal::NotForUnattendedRun { .. } => 27,
            Refusal::AlreadyRunning { .. } => 28,
            Refusal::ReceiptMissing { .. } => 29,
            Refusal::ReceiptInvalid { .. } => 30,
            Refusal::ReceiptStale { .. } => 31,
            Refusal::HeadMoved { .. } => 32,
            Refusal::SuiteCoverage { .. } => 33,
            Refusal::NoContainerRuntime => 34,
            Refusal::TreeEscape { .. } => 35,
            Refusal::CleanRunFailed { .. } => 36,
            Refusal::MutationInvalid { .. } => 37,
            Refusal::GuardDoesNotBite { .. } => 38,
            Refusal::EvidenceVacuous { .. } => 39,
            Refusal::DependencyUnverified { .. } => 40,
            Refusal::Leased { .. } => 41,
            Refusal::NotApproved { .. } => 42,
            Refusal::NoStandingApproval { .. } => 43,
            Refusal::MergeStateBlocked { .. } => 44,
            Refusal::ChecksNotGreen { .. } => 45,
            Refusal::ClaimConflict { .. } => 46,
            Refusal::MergeRefused { .. } => 47,
        }
    }

    /// One row per variant, in declaration order: the sample, its exit code, and
    /// who may produce it. Changing a code in `exit_code` makes a row fail.
    #[allow(clippy::too_many_lines, reason = "the table is data: one row per refusal class")]
    fn table() -> Vec<(Refusal, i32, Scope)> {
        vec![
            (
                Refusal::CadenceNotDue { task: "review".to_string(), age_hours: 2, min_hours: 6 },
                EXIT_OK,
                Scope::Run,
            ),
            (
                Refusal::Usage { message: "maintainer-merge verify <pr> <sha>".to_string() },
                EXIT_USAGE,
                Scope::Shared,
            ),
            (
                Refusal::TreeIncomplete { what: "no profiles/ directory".to_string() },
                EXIT_USAGE,
                Scope::Run,
            ),
            (Refusal::ProfileNotFound { profile: "magent".to_string() }, EXIT_USAGE, Scope::Run),
            (
                Refusal::ProfileLoadFailed { reason: "profile.env did not source".to_string() },
                EXIT_USAGE,
                Scope::Shared,
            ),
            (Refusal::UnknownTask { task: "nap".to_string() }, EXIT_USAGE, Scope::Run),
            (Refusal::BackendNotFound { backend: "nothing".to_string() }, EXIT_USAGE, Scope::Run),
            (
                Refusal::LockTimeout { what: "run.lock".to_string(), waited_secs: 3600 },
                EXIT_TEMPFAIL,
                Scope::Run,
            ),
            (Refusal::GhUnreachable { tries: 3 }, EXIT_TEMPFAIL, Scope::Run),
            (
                Refusal::TokenUnresolved { reason: "gh exited 4".to_string() },
                EXIT_TEMPFAIL,
                Scope::Run,
            ),
            (
                Refusal::BackendStopped {
                    backend: "claude".to_string(),
                    reason: "a rate limit".to_string(),
                },
                EXIT_TEMPFAIL,
                Scope::Run,
            ),
            (Refusal::NestedRun { run_id: "review-1".to_string() }, EXIT_CONFIG, Scope::Run),
            (
                Refusal::BackendCannotRehearse { backend: "codex".to_string() },
                EXIT_CONFIG,
                Scope::Run,
            ),
            (
                Refusal::RehearsalWallMissing {
                    profile: "magent".to_string(),
                    backend: "claude".to_string(),
                },
                EXIT_CONFIG,
                Scope::Run,
            ),
            (
                Refusal::TaskNotAllowed {
                    backend: "cursor".to_string(),
                    task: "review".to_string(),
                    allowed: "readonly".to_string(),
                },
                EXIT_CONFIG,
                Scope::Run,
            ),
            (Refusal::TokenRejected { account: "vladimirrott".to_string() }, EXIT_FAIL, Scope::Run),
            (
                Refusal::IdentityMismatch {
                    expected: "vladimirrott".to_string(),
                    actual: "someone".to_string(),
                },
                EXIT_FAIL,
                Scope::Shared,
            ),
            (
                Refusal::TokenNotPinned { account: "vladimirrott".to_string() },
                EXIT_FAIL,
                Scope::Run,
            ),
            (
                Refusal::BackendUnusable {
                    backend: "claude".to_string(),
                    reason: "not installed".to_string(),
                },
                EXIT_FAIL,
                Scope::Run,
            ),
            (
                Refusal::CheckoutUnavailable {
                    path: "/srv/repo".to_string(),
                    reason: "clone failed".to_string(),
                },
                EXIT_FAIL,
                Scope::Run,
            ),
            (Refusal::RefreshFailed { reason: "no run id".to_string() }, EXIT_FAIL, Scope::Run),
            (
                Refusal::DoctrineMissing { file: "preamble-core.md".to_string() },
                EXIT_FAIL,
                Scope::Run,
            ),
            (
                Refusal::ReportUnusable {
                    run_id: "review-1".to_string(),
                    reason: "finish refused it".to_string(),
                },
                EXIT_FAIL,
                Scope::Run,
            ),
            (Refusal::Missing { what: "the receipt key".to_string() }, EXIT_FAIL, Scope::Shared),
            (
                Refusal::Unreadable {
                    what: "the lease on #5".to_string(),
                    reason: "permission denied".to_string(),
                },
                EXIT_FAIL,
                Scope::Shared,
            ),
            (Refusal::InvalidPrNumber { given: "../x".to_string() }, EXIT_FAIL, Scope::Merge),
            (Refusal::UnknownSuite { name: "nope".to_string() }, EXIT_FAIL, Scope::Merge),
            (
                Refusal::NotForUnattendedRun { action: "assert a receipt".to_string() },
                EXIT_FAIL,
                Scope::Merge,
            ),
            (
                Refusal::AlreadyRunning { what: "a verify of #7".to_string() },
                EXIT_FAIL,
                Scope::Merge,
            ),
            (Refusal::ReceiptMissing { pr: 7 }, EXIT_FAIL, Scope::Merge),
            (
                Refusal::ReceiptInvalid {
                    pr: 7,
                    reason: "the signature does not match".to_string(),
                },
                EXIT_FAIL,
                Scope::Merge,
            ),
            (
                Refusal::ReceiptStale { pr: 7, reason: "production code changed".to_string() },
                EXIT_FAIL,
                Scope::Merge,
            ),
            (
                Refusal::HeadMoved {
                    pr: 7,
                    expected: "aaaaaaaa".to_string(),
                    actual: "bbbbbbbb".to_string(),
                },
                EXIT_FAIL,
                Scope::Merge,
            ),
            (
                Refusal::SuiteCoverage { reason: "no suite covers src/lib.rs".to_string() },
                EXIT_FAIL,
                Scope::Merge,
            ),
            (Refusal::NoContainerRuntime, EXIT_FAIL, Scope::Merge),
            (Refusal::TreeEscape { pr: 7 }, EXIT_FAIL, Scope::Merge),
            (
                Refusal::CleanRunFailed { pr: 7, reason: "exit 101".to_string() },
                EXIT_FAIL,
                Scope::Merge,
            ),
            (
                Refusal::MutationInvalid {
                    pr: 7,
                    reason: "the mutation changed nothing".to_string(),
                },
                EXIT_FAIL,
                Scope::Merge,
            ),
            (
                Refusal::GuardDoesNotBite { pr: 7, filter: "guard_test".to_string() },
                EXIT_FAIL,
                Scope::Merge,
            ),
            (
                Refusal::EvidenceVacuous { pr: 7, filter: "guard_test".to_string() },
                EXIT_FAIL,
                Scope::Merge,
            ),
            (
                Refusal::DependencyUnverified {
                    pr: 7,
                    reason: "the pin comment is not true".to_string(),
                },
                EXIT_FAIL,
                Scope::Merge,
            ),
            (Refusal::Leased { pr: 7, holders: "someone".to_string() }, EXIT_FAIL, Scope::Merge),
            (
                Refusal::NotApproved { pr: 7, decision: "REVIEW_REQUIRED".to_string() },
                EXIT_FAIL,
                Scope::Merge,
            ),
            (
                Refusal::NoStandingApproval {
                    pr: 7,
                    account: "vladimirrott".to_string(),
                    head: "aaaaaaaa".to_string(),
                },
                EXIT_FAIL,
                Scope::Merge,
            ),
            (
                Refusal::MergeStateBlocked { pr: 7, state: "BEHIND".to_string() },
                EXIT_FAIL,
                Scope::Merge,
            ),
            (
                Refusal::ChecksNotGreen { pr: 7, reason: "2 pending".to_string() },
                EXIT_FAIL,
                Scope::Merge,
            ),
            (
                Refusal::ClaimConflict {
                    pr: 7,
                    issue: 3,
                    reason: "it carries the claim label".to_string(),
                },
                EXIT_FAIL,
                Scope::Merge,
            ),
            (
                Refusal::MergeRefused {
                    pr: 7,
                    reason: "expected_head_sha did not match".to_string(),
                },
                EXIT_FAIL,
                Scope::Merge,
            ),
        ]
    }

    #[test]
    fn exit_codes_match_the_contract_table() {
        let rows = table();
        assert!(rows.len() >= 40, "the table holds only {} rows", rows.len());
        for (refusal, expected, _) in &rows {
            assert_eq!(refusal.exit_code(), *expected, "wrong exit code for {refusal:?}");
        }
        println!("checked {} refusal classes", rows.len());
    }

    #[test]
    fn the_table_holds_every_variant_exactly_once_in_declaration_order() {
        for (index, (refusal, _, _)) in table().iter().enumerate() {
            assert_eq!(rank(refusal), index, "{refusal:?} is out of place in the table");
        }
        let last = rank(&Refusal::MergeRefused { pr: 0, reason: String::new() });
        assert_eq!(table().len(), last + 1, "a variant has no row in the table");
    }

    #[test]
    fn only_the_codes_the_contracts_name_are_used() {
        for (refusal, code, _) in table() {
            assert!(
                [EXIT_OK, EXIT_FAIL, EXIT_USAGE, EXIT_TEMPFAIL, EXIT_CONFIG].contains(&code),
                "{refusal:?} exits with {code}"
            );
        }
        assert_eq!(
            (EXIT_OK, EXIT_FAIL, EXIT_USAGE, EXIT_TEMPFAIL, EXIT_CONFIG),
            (0, 1, 64, 75, 78)
        );
    }

    #[test]
    fn merge_refusals_exit_with_1_or_64_only() {
        let mut checked = 0;
        for (refusal, code, scope) in table() {
            if scope != Scope::Run {
                assert!([EXIT_FAIL, EXIT_USAGE].contains(&code), "{refusal:?} exits with {code}");
                checked += 1;
            }
        }
        assert!(checked >= 20, "only {checked} merge-gate classes were checked");
    }

    #[test]
    fn a_gh_that_cannot_reach_github_is_transient_and_a_rejected_token_is_not() {
        assert_eq!(Refusal::GhUnreachable { tries: 3 }.exit_code(), EXIT_TEMPFAIL);
        assert_eq!(Refusal::TokenRejected { account: "a".to_string() }.exit_code(), EXIT_FAIL);
    }

    #[test]
    fn every_message_names_its_fields_and_avoids_dashes() {
        for (refusal, _, _) in table() {
            let text = refusal.to_string();
            assert!(!text.is_empty(), "{refusal:?} has an empty message");
            assert!(!text.contains(['\u{2014}', '\u{2013}']), "{text}");
        }
        let text =
            Refusal::GuardDoesNotBite { pr: 7, filter: "guard_test".to_string() }.to_string();
        assert!(text.contains("guard_test") && text.contains("#7"), "{text}");
    }

    #[test]
    fn a_refusal_is_a_std_error() {
        fn takes_error<E: std::error::Error>(_: &E) {}
        takes_error(&Refusal::NoContainerRuntime);
    }
}
