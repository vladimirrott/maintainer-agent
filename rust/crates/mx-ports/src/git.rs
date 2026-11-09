use crate::{Effect, EffectLog, Script, lock};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use thiserror::Error;

/// A `git` call failed.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
#[error("git {command} failed: {reason}")]
pub struct GitError {
    pub command: String,
    pub reason: String,
}

/// The git operations the programs need.
///
/// A failed `diff_names` is an `Err`, never an empty list. An empty list means
/// "nothing changed", and a staleness check that read a git error as "nothing
/// changed" would call a stale receipt fresh.
pub trait Git {
    /// The commit a revision names.
    fn rev_parse(&self, repo: &Path, rev: &str) -> Result<String, GitError>;

    /// Fetches `refspec` from `remote`.
    fn fetch(&self, repo: &Path, remote: &str, refspec: &str) -> Result<(), GitError>;

    /// The paths that differ between two revisions.
    fn diff_names(&self, repo: &Path, from: &str, to: &str) -> Result<Vec<String>, GitError>;

    /// Clones `origin` into `dest`.
    fn clone_repo(&self, origin: &str, dest: &Path) -> Result<(), GitError>;
}

/// One call to a [`Git`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GitEffect {
    RevParse { repo: PathBuf, rev: String },
    Fetch { repo: PathBuf, remote: String, refspec: String },
    DiffNames { repo: PathBuf, from: String, to: String },
    Clone { origin: String, dest: PathBuf },
}

/// A scripted [`Git`] that records its calls.
#[derive(Debug)]
pub struct FakeGit {
    log: EffectLog,
    rev_parse: Mutex<Script<Result<String, GitError>>>,
    fetch: Mutex<Script<Result<(), GitError>>>,
    diff_names: Mutex<Script<Result<Vec<String>, GitError>>>,
    clone_repo: Mutex<Script<Result<(), GitError>>>,
}

impl FakeGit {
    /// A fake with no scripted answers.
    #[must_use]
    pub fn new(log: &EffectLog) -> Self {
        Self {
            log: log.clone(),
            rev_parse: Mutex::default(),
            fetch: Mutex::default(),
            diff_names: Mutex::default(),
            clone_repo: Mutex::default(),
        }
    }

    /// Scripts the answers to `rev_parse`.
    pub fn script_rev_parse(&self, script: Script<Result<String, GitError>>) {
        *lock(&self.rev_parse) = script;
    }

    /// Scripts the answers to `fetch`.
    pub fn script_fetch(&self, script: Script<Result<(), GitError>>) {
        *lock(&self.fetch) = script;
    }

    /// Scripts the answers to `diff_names`.
    pub fn script_diff_names(&self, script: Script<Result<Vec<String>, GitError>>) {
        *lock(&self.diff_names) = script;
    }

    /// Scripts the answers to `clone_repo`.
    pub fn script_clone(&self, script: Script<Result<(), GitError>>) {
        *lock(&self.clone_repo) = script;
    }
}

impl Git for FakeGit {
    fn rev_parse(&self, repo: &Path, rev: &str) -> Result<String, GitError> {
        self.log.push(Effect::Git(GitEffect::RevParse {
            repo: repo.to_path_buf(),
            rev: rev.to_string(),
        }));
        lock(&self.rev_parse).next("Git::rev_parse")
    }

    fn fetch(&self, repo: &Path, remote: &str, refspec: &str) -> Result<(), GitError> {
        self.log.push(Effect::Git(GitEffect::Fetch {
            repo: repo.to_path_buf(),
            remote: remote.to_string(),
            refspec: refspec.to_string(),
        }));
        lock(&self.fetch).next("Git::fetch")
    }

    fn diff_names(&self, repo: &Path, from: &str, to: &str) -> Result<Vec<String>, GitError> {
        self.log.push(Effect::Git(GitEffect::DiffNames {
            repo: repo.to_path_buf(),
            from: from.to_string(),
            to: to.to_string(),
        }));
        lock(&self.diff_names).next("Git::diff_names")
    }

    fn clone_repo(&self, origin: &str, dest: &Path) -> Result<(), GitError> {
        self.log.push(Effect::Git(GitEffect::Clone {
            origin: origin.to_string(),
            dest: dest.to_path_buf(),
        }));
        lock(&self.clone_repo).next("Git::clone_repo")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn failure() -> GitError {
        GitError { command: "diff".to_string(), reason: "bad object".to_string() }
    }

    #[test]
    fn scripted_answers_come_back_and_every_call_is_recorded() {
        let log = EffectLog::new();
        let git = FakeGit::new(&log);
        git.script_rev_parse(Script::always(Ok("abc123".to_string())));
        git.script_fetch(Script::always(Ok(())));
        git.script_diff_names(Script::always(Ok(vec!["src/lib.rs".to_string()])));
        git.script_clone(Script::always(Ok(())));
        let repo = Path::new("/repo");
        assert_eq!(git.rev_parse(repo, "HEAD").unwrap(), "abc123");
        git.fetch(repo, "origin", "refs/pull/7/head:mm-7").unwrap();
        assert_eq!(git.diff_names(repo, "aaa", "bbb").unwrap(), vec!["src/lib.rs".to_string()]);
        git.clone_repo("git@example:o/r.git", Path::new("/dest")).unwrap();
        assert_eq!(log.len(), 4);
        assert_eq!(
            log.entries()[1],
            Effect::Git(GitEffect::Fetch {
                repo: PathBuf::from("/repo"),
                remote: "origin".to_string(),
                refspec: "refs/pull/7/head:mm-7".to_string()
            })
        );
    }

    #[test]
    fn a_failing_diff_is_an_error_and_not_an_empty_list() {
        let log = EffectLog::new();
        let git = FakeGit::new(&log);
        git.script_diff_names(Script::always(Err(failure())));
        assert_eq!(git.diff_names(Path::new("/r"), "a", "b"), Err(failure()));
    }

    #[test]
    fn a_call_is_recorded_even_when_it_has_no_script() {
        let log = EffectLog::new();
        let git = FakeGit::new(&log);
        let caught = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _ = git.rev_parse(Path::new("/r"), "HEAD");
        }));
        assert!(caught.is_err(), "an unscripted call must panic");
        assert_eq!(log.len(), 1);
    }
}
