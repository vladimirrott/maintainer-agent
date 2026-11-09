use crate::{Effect, EffectLog, Script, lock};
use mx_core::NonEmpty;
use std::fmt;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Duration;
use thiserror::Error;

/// A program to run: an argument vector, never a shell string.
///
/// The environment of the call goes in `env`, not in `argv`: a secret in argv
/// shows in `/proc` to every process of the same user. `Debug` prints the
/// names of the variables and not their values.
#[derive(Clone, PartialEq, Eq)]
pub struct ProcSpec {
    /// The program and its arguments. The first item is the program.
    pub argv: NonEmpty<String>,
    /// Variables for this call, on top of the adapter's own environment.
    /// `PATH` and `LC_ALL` belong to the adapter and are ignored here.
    pub env: Vec<(String, String)>,
    /// The working directory, or the caller's own when `None`.
    pub cwd: Option<PathBuf>,
    /// Bytes for the child's standard input. `None` gives it an empty input.
    pub stdin: Option<Vec<u8>>,
    /// How long the whole call may take. There is no unbounded call.
    pub timeout: Duration,
}

impl ProcSpec {
    /// A call with an argument vector and a timeout.
    #[must_use]
    pub fn new(argv: NonEmpty<String>, timeout: Duration) -> Self {
        Self { argv, env: Vec::new(), cwd: None, stdin: None, timeout }
    }

    /// A call from a program name and its arguments.
    #[must_use]
    pub fn command<S: Into<String>>(
        program: &str,
        args: impl IntoIterator<Item = S>,
        timeout: Duration,
    ) -> Self {
        Self::new(NonEmpty::new(program.to_string(), args.into_iter().map(Into::into)), timeout)
    }

    /// Adds a variable for this call.
    #[must_use]
    pub fn env(mut self, name: impl Into<String>, value: impl Into<String>) -> Self {
        self.env.push((name.into(), value.into()));
        self
    }

    /// Sets the working directory.
    #[must_use]
    pub fn cwd(mut self, dir: impl Into<PathBuf>) -> Self {
        self.cwd = Some(dir.into());
        self
    }

    /// Sets the bytes the child reads from standard input.
    #[must_use]
    pub fn stdin(mut self, bytes: impl Into<Vec<u8>>) -> Self {
        self.stdin = Some(bytes.into());
        self
    }
}

impl fmt::Debug for ProcSpec {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let names: Vec<&str> = self.env.iter().map(|(name, _)| name.as_str()).collect();
        f.debug_struct("ProcSpec")
            .field("argv", &self.argv)
            .field("env_names", &names)
            .field("cwd", &self.cwd)
            .field("stdin_bytes", &self.stdin.as_ref().map(Vec::len))
            .field("timeout", &self.timeout)
            .finish()
    }
}

/// How a call ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProcExit {
    /// The program exited. A death by signal `n` reads as `128 + n`, the way a
    /// shell reports it, so `kill -9` is 137.
    Code(i32),
    /// The call did not finish within its timeout and was killed.
    TimedOut,
}

impl ProcExit {
    /// True only for exit code 0. A timeout is never a success.
    #[must_use]
    pub fn success(self) -> bool {
        self == Self::Code(0)
    }
}

/// What a finished call left behind. On a timeout the output is what the child
/// wrote before it was killed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProcOutput {
    pub exit: ProcExit,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

/// A call that could not be made or could not be finished cleanly.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ProcError {
    /// No executable of that name on the search path.
    #[error("{program}: not found on the search path")]
    NotFound { program: String },
    /// A file of that name exists on the search path but is not executable.
    #[error("{program}: found but not executable")]
    NotExecutable { program: String },
    /// A program name with a slash must be an absolute path.
    #[error("{program}: a program with a slash must be an absolute path")]
    RelativeProgram { program: String },
    /// The operating system refused to start it.
    #[error("{program}: could not start: {reason}")]
    Spawn { program: String, reason: String },
    /// Waiting for it or reading its output failed.
    #[error("{program}: {reason}")]
    Io { program: String, reason: String },
    /// The timeout fired and the process group could not be killed. The
    /// program itself was killed, but its children may still run.
    #[error("{program}: timed out and the process group could not be killed: {reason}")]
    KillFailed { program: String, reason: String },
}

/// Runs programs.
pub trait Proc {
    /// Runs the call and waits for it, or for its timeout.
    fn run(&self, spec: &ProcSpec) -> Result<ProcOutput, ProcError>;
}

/// One call to a [`Proc`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProcEffect {
    Run(ProcSpec),
}

/// An argument vector and the answers scripted for it.
type Rule = (Vec<String>, Script<Result<ProcOutput, ProcError>>);

/// A scripted [`Proc`]: answers by exact argument vector and records its calls.
#[derive(Debug)]
pub struct FakeProc {
    log: EffectLog,
    rules: Mutex<Vec<Rule>>,
}

impl FakeProc {
    /// A fake that answers no call.
    #[must_use]
    pub fn new(log: &EffectLog) -> Self {
        Self { log: log.clone(), rules: Mutex::new(Vec::new()) }
    }

    /// Scripts the answers for calls whose argument vector is exactly `argv`.
    pub fn script(&self, argv: &[&str], answers: Script<Result<ProcOutput, ProcError>>) {
        let key = argv.iter().map(|part| (*part).to_string()).collect();
        lock(&self.rules).push((key, answers));
    }

    /// An output that exited with `code` and printed `stdout`.
    #[must_use]
    pub fn exited(code: i32, stdout: &str) -> ProcOutput {
        ProcOutput {
            exit: ProcExit::Code(code),
            stdout: stdout.as_bytes().to_vec(),
            stderr: Vec::new(),
        }
    }
}

impl Proc for FakeProc {
    fn run(&self, spec: &ProcSpec) -> Result<ProcOutput, ProcError> {
        self.log.push(Effect::Proc(ProcEffect::Run(spec.clone())));
        let mut rules = lock(&self.rules);
        let argv = spec.argv.as_slice();
        for (key, answers) in rules.iter_mut() {
            if key.as_slice() == argv {
                return answers.next(&format!("Proc::run {argv:?}"));
            }
        }
        panic!(
            "unscripted call: no rule matches Proc::run {argv:?}; script it before the code under test runs"
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SECOND: Duration = Duration::from_secs(1);

    #[test]
    fn debug_prints_variable_names_and_never_their_values() {
        let spec = ProcSpec::command("gh", ["api", "user"], SECOND)
            .env("GH_TOKEN", "ghp_value_that_must_not_leak");
        let text = format!("{spec:?}");
        assert!(text.contains("GH_TOKEN"), "{text}");
        assert!(!text.contains("must_not_leak"), "{text}");
    }

    #[test]
    fn command_puts_the_program_first_and_keeps_argument_order() {
        let spec = ProcSpec::command("git", ["-C", "/repo", "status"], SECOND);
        assert_eq!(spec.argv.as_slice(), ["git", "-C", "/repo", "status"]);
        assert_eq!(spec.timeout, SECOND);
    }

    #[test]
    fn builders_set_env_cwd_and_stdin() {
        let spec = ProcSpec::command("cat", Vec::<String>::new(), SECOND)
            .env("A", "1")
            .cwd("/work")
            .stdin("hi");
        assert_eq!(spec.env, vec![("A".to_string(), "1".to_string())]);
        assert_eq!(spec.cwd, Some(PathBuf::from("/work")));
        assert_eq!(spec.stdin, Some(b"hi".to_vec()));
    }

    #[test]
    fn only_exit_code_zero_is_success() {
        assert!(ProcExit::Code(0).success());
        assert!(!ProcExit::Code(1).success());
        assert!(!ProcExit::TimedOut.success());
    }

    #[test]
    fn the_fake_answers_by_exact_argv_and_records_the_spec() {
        let log = EffectLog::new();
        let proc = FakeProc::new(&log);
        proc.script(
            &["gh", "api", "user"],
            Script::always(Ok(FakeProc::exited(0, "vladimirrott\n"))),
        );
        let spec = ProcSpec::command("gh", ["api", "user"], SECOND);
        let out = proc.run(&spec).unwrap();
        assert_eq!(out.stdout, b"vladimirrott\n");
        assert_eq!(log.entries(), vec![Effect::Proc(ProcEffect::Run(spec))]);
    }

    #[test]
    fn the_fake_does_not_match_a_prefix_of_the_argv() {
        let log = EffectLog::new();
        let proc = FakeProc::new(&log);
        proc.script(&["gh", "api"], Script::always(Ok(FakeProc::exited(0, ""))));
        let caught = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _ = proc.run(&ProcSpec::command("gh", ["api", "user"], SECOND));
        }));
        assert!(caught.is_err(), "a longer argv must not match a shorter rule");
    }

    #[test]
    #[should_panic(expected = "unscripted call: no rule matches Proc::run")]
    fn an_unscripted_call_panics_and_names_the_argv() {
        let log = EffectLog::new();
        let proc = FakeProc::new(&log);
        let _ = proc.run(&ProcSpec::command("git", ["status"], SECOND));
    }

    #[test]
    fn a_timeout_and_a_spawn_error_are_scriptable() {
        let log = EffectLog::new();
        let proc = FakeProc::new(&log);
        proc.script(
            &["sleep", "30"],
            Script::sequence([
                Ok(ProcOutput { exit: ProcExit::TimedOut, stdout: Vec::new(), stderr: Vec::new() }),
                Err(ProcError::NotFound { program: "sleep".to_string() }),
            ]),
        );
        let spec = ProcSpec::command("sleep", ["30"], SECOND);
        assert_eq!(proc.run(&spec).unwrap().exit, ProcExit::TimedOut);
        assert!(matches!(proc.run(&spec), Err(ProcError::NotFound { .. })));
    }
}
