use crate::{Proc, ProcError, ProcExit, ProcOutput, ProcSpec, lock};
use std::ffi::{OsStr, OsString};
use std::io::{ErrorKind, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

/// How long the readers get to reach end of file after the kill.
const KILL_GRACE: Duration = Duration::from_millis(500);
/// Where the `kill` utility lives, in the order tried.
const KILL_TOOLS: [&str; 2] = ["/bin/kill", "/usr/bin/kill"];
/// Reported when a status carries neither an exit code nor a signal.
const UNKNOWN_EXIT: i32 = 255;

/// Runs programs for real.
///
/// - The program is an argument vector. No shell reads it.
/// - The program name is resolved against the adapter's own search path:
///   relative and empty entries are skipped, and a name with a slash must be
///   an absolute path.
/// - The child starts with an empty environment. It gets the variables the
///   adapter was built with, then the call's own, then `PATH` (the search
///   path) and `LC_ALL=C`, which a call cannot override.
/// - The child leads its own process group. When the timeout expires the
///   whole group gets `SIGKILL`, so `sh -c 'sleep 30 &'` leaves nothing behind.
/// - A child that dies of signal `n` reports exit code `128 + n`.
/// - Standard output and standard error are captured separately.
///
/// The process-group kill runs the `kill` utility. Rust's standard library has
/// no safe call for it, and this workspace forbids `unsafe`. If the utility is
/// missing, a timed-out call returns [`ProcError::KillFailed`] after killing
/// the program itself.
///
/// A program that exits but leaves a child holding its output pipes open still
/// counts as running until the timeout: the call waits for the pipes to close.
#[derive(Debug, Clone)]
pub struct RealProc {
    search_path: OsString,
    base_env: Vec<(String, String)>,
    kill_tools: Vec<PathBuf>,
}

impl RealProc {
    /// An adapter that resolves programs against `search_path` and passes
    /// `base_env` to every child.
    pub fn new(search_path: impl Into<OsString>, base_env: Vec<(String, String)>) -> Self {
        Self {
            search_path: search_path.into(),
            base_env,
            kill_tools: KILL_TOOLS.iter().map(PathBuf::from).collect(),
        }
    }

    /// An adapter whose base environment is the variables named in `allow` that
    /// the current process has. A name the process lacks, or whose value is not
    /// UTF-8, is left out. This is the one place that reads the environment.
    pub fn from_process_env(search_path: impl Into<OsString>, allow: &[&str]) -> Self {
        let base_env = allow
            .iter()
            .filter_map(|name| std::env::var(name).ok().map(|value| ((*name).to_string(), value)))
            .collect();
        Self::new(search_path, base_env)
    }

    /// Uses `tool` instead of the system `kill` for the process-group kill.
    #[must_use]
    pub fn with_group_kill_tool(mut self, tool: impl Into<PathBuf>) -> Self {
        self.kill_tools = vec![tool.into()];
        self
    }
}

impl Proc for RealProc {
    fn run(&self, spec: &ProcSpec) -> Result<ProcOutput, ProcError> {
        let name = spec.argv.first();
        let program = resolve(&self.search_path, name)?;

        let mut command = new_command(&program);
        command.arg0(name).args(&spec.argv.as_slice()[1..]).env_clear();
        for (key, value) in self.base_env.iter().chain(&spec.env) {
            command.env(key, value);
        }
        command.env("PATH", &self.search_path).env("LC_ALL", "C");
        if let Some(dir) = &spec.cwd {
            command.current_dir(dir);
        }
        command
            .process_group(0)
            .stdin(if spec.stdin.is_some() { Stdio::piped() } else { Stdio::null() })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());

        let deadline = Instant::now() + spec.timeout;
        let mut child = command.spawn().map_err(|error| ProcError::Spawn {
            program: name.clone(),
            reason: error.to_string(),
        })?;
        let pid = child.id();
        let io_error =
            |reason: &str| ProcError::Io { program: name.clone(), reason: reason.to_string() };

        if let (Some(bytes), Some(mut pipe)) = (&spec.stdin, child.stdin.take()) {
            let bytes = bytes.clone();
            // A child that never reads its input closes the pipe on exit and
            // the write fails. That is the child's answer, not an error here.
            drop(thread::spawn(move || drop(pipe.write_all(&bytes))));
        }
        let (Some(stdout), Some(stderr)) = (child.stdout.take(), child.stderr.take()) else {
            let _ = child.kill();
            let _ = child.wait();
            return Err(io_error("the output pipes were not created"));
        };
        let out = Capture::start(stdout);
        let err = Capture::start(stderr);

        let mut status: Option<ExitStatus> = None;
        let mut wait_failure: Option<std::io::Error> = None;
        let exited = wait_until(deadline, || match child.try_wait() {
            Ok(Some(done)) => {
                status = Some(done);
                true
            }
            Ok(None) => false,
            Err(error) => {
                wait_failure = Some(error);
                true
            }
        });
        if let Some(error) = wait_failure {
            let _ = kill_group(&self.kill_tools, pid);
            let _ = child.kill();
            let _ = child.wait();
            return Err(io_error(&format!("waiting failed: {error}")));
        }
        let drained = exited && wait_until(deadline, || out.is_done() && err.is_done());

        if let (Some(done), true) = (status, drained) {
            let stdout =
                out.finish().map_err(|error| io_error(&format!("reading stdout: {error}")))?;
            let stderr =
                err.finish().map_err(|error| io_error(&format!("reading stderr: {error}")))?;
            return Ok(ProcOutput { exit: ProcExit::Code(exit_code(done)), stdout, stderr });
        }

        // The deadline passed. Kill the group, then the program itself in case
        // the group kill could not run, then reap it.
        let group = kill_group(&self.kill_tools, pid);
        let _ = child.kill();
        let _ = child.wait();
        wait_until(Instant::now() + KILL_GRACE, || out.is_done() && err.is_done());
        match group {
            Err(reason) => Err(ProcError::KillFailed { program: name.clone(), reason }),
            Ok(false) if status.is_none() => Err(ProcError::KillFailed {
                program: name.clone(),
                reason: "the kill utility reported failure while the program was still running"
                    .to_string(),
            }),
            Ok(_) => Ok(ProcOutput {
                exit: ProcExit::TimedOut,
                stdout: out.snapshot(),
                stderr: err.snapshot(),
            }),
        }
    }
}

/// The only place in the workspace that constructs a `Command`.
#[allow(
    clippy::disallowed_methods,
    reason = "RealProc is the single adapter that starts processes; every other crate goes through the Proc trait"
)]
fn new_command(program: &Path) -> Command {
    Command::new(program)
}

/// Sends `SIGKILL` to the process group led by `pid`.
///
/// `Ok(true)` means the utility reported success, `Ok(false)` that it ran and
/// reported failure (the group may already be gone), and `Err` that it could not
/// run at all.
fn kill_group(tools: &[PathBuf], pid: u32) -> Result<bool, String> {
    let tool = tools
        .iter()
        .find(|tool| tool.is_file())
        .ok_or_else(|| format!("no kill utility found among {tools:?}"))?;
    let status = new_command(tool)
        .args(["-s", "KILL", "--"])
        .arg(format!("-{pid}"))
        .env_clear()
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map_err(|error| format!("{}: {error}", tool.display()))?;
    Ok(status.success())
}

/// `128 + signal` for a signal death, the exit code otherwise.
fn exit_code(status: ExitStatus) -> i32 {
    status.code().or_else(|| status.signal().map(|signal| 128 + signal)).unwrap_or(UNKNOWN_EXIT)
}

/// Polls `ready` with a short, growing pause until it is true or `deadline`
/// passes. `ready` is checked once more at the deadline, so a call that
/// finishes on the last instant still counts.
fn wait_until(deadline: Instant, mut ready: impl FnMut() -> bool) -> bool {
    let mut pause = Duration::from_millis(1);
    loop {
        if ready() {
            return true;
        }
        let now = Instant::now();
        if now >= deadline {
            return false;
        }
        thread::sleep(pause.min(deadline - now));
        pause = (pause * 2).min(Duration::from_millis(20));
    }
}

/// Finds the executable for `program`.
fn resolve(search_path: &OsStr, program: &str) -> Result<PathBuf, ProcError> {
    if program.contains('/') {
        let path = Path::new(program);
        if !path.is_absolute() {
            return Err(ProcError::RelativeProgram { program: program.to_string() });
        }
        return match fs_mode(path) {
            Some(mode) if mode & 0o111 != 0 => Ok(path.to_path_buf()),
            Some(_) => Err(ProcError::NotExecutable { program: program.to_string() }),
            None => Err(ProcError::NotFound { program: program.to_string() }),
        };
    }
    let mut found_but_not_executable = false;
    for dir in std::env::split_paths(search_path) {
        if !dir.is_absolute() {
            continue;
        }
        let candidate = dir.join(program);
        match fs_mode(&candidate) {
            Some(mode) if mode & 0o111 != 0 => return Ok(candidate),
            Some(_) => found_but_not_executable = true,
            None => {}
        }
    }
    if found_but_not_executable {
        Err(ProcError::NotExecutable { program: program.to_string() })
    } else {
        Err(ProcError::NotFound { program: program.to_string() })
    }
}

/// The permission bits of a regular file, following symlinks.
fn fs_mode(path: &Path) -> Option<u32> {
    let metadata = std::fs::metadata(path).ok()?;
    metadata.is_file().then(|| metadata.permissions().mode())
}

/// Collects one output stream on its own thread.
struct Capture {
    buffer: Arc<Mutex<Vec<u8>>>,
    done: Arc<AtomicBool>,
    reader: JoinHandle<std::io::Result<()>>,
}

impl Capture {
    fn start<R: Read + Send + 'static>(mut source: R) -> Self {
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let done = Arc::new(AtomicBool::new(false));
        let (shared_buffer, shared_done) = (Arc::clone(&buffer), Arc::clone(&done));
        let reader = thread::spawn(move || {
            let mut chunk = [0_u8; 8192];
            let result = loop {
                match source.read(&mut chunk) {
                    Ok(0) => break Ok(()),
                    Ok(count) => lock(&shared_buffer).extend_from_slice(&chunk[..count]),
                    Err(error) if error.kind() == ErrorKind::Interrupted => {}
                    Err(error) => break Err(error),
                }
            };
            shared_done.store(true, Ordering::Release);
            result
        });
        Self { buffer, done, reader }
    }

    fn is_done(&self) -> bool {
        self.done.load(Ordering::Acquire)
    }

    /// What has been read so far.
    fn snapshot(&self) -> Vec<u8> {
        lock(&self.buffer).clone()
    }

    /// The whole stream, once the reader has finished.
    fn finish(self) -> std::io::Result<Vec<u8>> {
        self.reader.join().map_err(|_| std::io::Error::other("the reader thread panicked"))??;
        Ok(std::mem::take(&mut *lock(&self.buffer)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::{BTreeMap, BTreeSet};
    use std::sync::atomic::AtomicU32;
    use std::sync::mpsc;

    const SEARCH_PATH: &str = "/usr/bin:/bin";
    const LONG: Duration = Duration::from_secs(30);
    /// No test may wait longer than this for one call. A timeout kill that
    /// stops working would otherwise hang the run for as long as the child lives.
    const BOUND: Duration = Duration::from_secs(10);

    fn proc() -> RealProc {
        RealProc::new(SEARCH_PATH, Vec::new())
    }

    fn call(program: &str, args: &[&str]) -> ProcSpec {
        ProcSpec::command(program, args.iter().copied(), LONG)
    }

    /// Runs the call on its own thread and fails the test if it does not return
    /// within `BOUND`.
    fn run_bounded(proc: RealProc, spec: ProcSpec) -> Result<ProcOutput, ProcError> {
        let (sender, receiver) = mpsc::channel();
        drop(thread::spawn(move || drop(sender.send(proc.run(&spec)))));
        receiver.recv_timeout(BOUND).unwrap_or_else(|_| {
            panic!("RealProc did not return within {BOUND:?}: the timeout kill does not work")
        })
    }

    fn text(bytes: &[u8]) -> String {
        String::from_utf8(bytes.to_vec()).unwrap()
    }

    /// The `NAME=value` lines of a `printenv` run, as a map.
    fn env_of_child(proc: &RealProc, spec: &ProcSpec) -> BTreeMap<String, String> {
        let out = proc.run(spec).unwrap();
        assert_eq!(out.exit, ProcExit::Code(0));
        text(&out.stdout)
            .lines()
            .filter_map(|line| line.split_once('='))
            .map(|(name, value)| (name.to_string(), value.to_string()))
            .collect()
    }

    /// A directory under the system temp dir that is removed on drop.
    struct TempDir(PathBuf);

    impl TempDir {
        fn new(tag: &str) -> Self {
            static COUNTER: AtomicU32 = AtomicU32::new(0);
            let unique = COUNTER.fetch_add(1, Ordering::Relaxed);
            let dir = std::env::temp_dir()
                .join(format!("mx-ports-{tag}-{}-{unique}", std::process::id()));
            std::fs::create_dir_all(&dir).unwrap();
            Self(dir.canonicalize().unwrap())
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            drop(std::fs::remove_dir_all(&self.0));
        }
    }

    /// The path of a system binary such as `true`, wherever this machine keeps it.
    fn system_binary(name: &str) -> PathBuf {
        ["/usr/bin", "/bin"]
            .iter()
            .map(|dir| Path::new(dir).join(name))
            .find(|path| path.is_file())
            .unwrap_or_else(|| panic!("no {name} binary on this machine"))
    }

    #[cfg(target_os = "linux")]
    fn is_alive(pid: u32) -> bool {
        match std::fs::read_to_string(format!("/proc/{pid}/stat")) {
            Err(_) => false,
            Ok(stat) => stat
                .rsplit_once(')')
                .and_then(|(_, rest)| rest.trim_start().chars().next())
                .is_some_and(|state| state != 'Z' && state != 'X'),
        }
    }

    #[test]
    fn true_exits_zero() {
        let out = proc().run(&call("true", &[])).unwrap();
        assert_eq!(out.exit, ProcExit::Code(0));
        assert!(out.exit.success());
    }

    #[test]
    fn false_exits_one() {
        let out = proc().run(&call("false", &[])).unwrap();
        assert_eq!(out.exit, ProcExit::Code(1));
        assert!(!out.exit.success());
    }

    #[test]
    fn a_child_that_kills_itself_with_sigkill_reports_137() {
        let out = proc().run(&call("sh", &["-c", "kill -9 $$"])).unwrap();
        assert_eq!(out.exit, ProcExit::Code(137));
    }

    #[test]
    fn a_child_that_dies_of_sigterm_reports_143() {
        let out = proc().run(&call("sh", &["-c", "kill -TERM $$"])).unwrap();
        assert_eq!(out.exit, ProcExit::Code(143));
    }

    #[test]
    fn an_ordinary_exit_code_passes_through() {
        let out = proc().run(&call("sh", &["-c", "exit 42"])).unwrap();
        assert_eq!(out.exit, ProcExit::Code(42));
    }

    #[test]
    fn a_child_that_outlives_its_timeout_is_killed_and_reported_as_timed_out() {
        let spec = ProcSpec::command("sleep", ["30"], Duration::from_secs(1));
        let started = Instant::now();
        let out = run_bounded(proc(), spec).unwrap();
        let elapsed = started.elapsed();
        assert_eq!(out.exit, ProcExit::TimedOut);
        assert!(!out.exit.success());
        assert!(
            elapsed >= Duration::from_secs(1),
            "returned after {elapsed:?}, before the timeout"
        );
        assert!(elapsed < BOUND, "returned after {elapsed:?}");
        println!("sleep 30 with a 1 s timeout returned after {elapsed:?}");
    }

    #[test]
    fn output_written_before_the_timeout_is_kept() {
        let spec = ProcSpec::command("sh", ["-c", "echo before; sleep 30"], Duration::from_secs(1));
        let out = run_bounded(proc(), spec).unwrap();
        assert_eq!(out.exit, ProcExit::TimedOut);
        assert_eq!(text(&out.stdout), "before\n");
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn a_timeout_kills_the_whole_process_group_and_not_only_the_program() {
        let spec =
            ProcSpec::command("sh", ["-c", "sleep 30 & echo $!; wait"], Duration::from_secs(1));
        let out = run_bounded(proc(), spec).unwrap();
        assert_eq!(out.exit, ProcExit::TimedOut);
        let grandchild: u32 =
            text(&out.stdout).trim().parse().expect("the shell prints its child's pid");
        let deadline = Instant::now() + Duration::from_secs(3);
        let gone = wait_until(deadline, || !is_alive(grandchild));
        assert!(gone, "the grandchild {grandchild} survived the timeout");
    }

    #[test]
    fn pipes_held_open_past_the_timeout_count_as_a_timeout() {
        let spec = ProcSpec::command("sh", ["-c", "sleep 30 & echo done"], Duration::from_secs(1));
        let out = run_bounded(proc(), spec).unwrap();
        assert_eq!(out.exit, ProcExit::TimedOut);
        assert_eq!(text(&out.stdout), "done\n");
    }

    #[test]
    fn a_missing_kill_utility_is_reported_and_the_program_is_still_killed() {
        let spec = ProcSpec::command("sleep", ["30"], Duration::from_secs(1));
        let broken = proc().with_group_kill_tool("/nonexistent/kill");
        let error = run_bounded(broken, spec).unwrap_err();
        assert!(matches!(error, ProcError::KillFailed { .. }), "got {error:?}");
    }

    #[test]
    fn the_child_sees_only_path_and_lc_all_when_nothing_is_allowed() {
        let ambient: Vec<String> = std::env::vars_os()
            .filter_map(|(name, _)| name.into_string().ok())
            .filter(|name| name != "PATH" && name != "LC_ALL")
            .collect();
        assert!(
            !ambient.is_empty(),
            "the test process has no other variable, so this proves nothing"
        );
        let seen = env_of_child(&proc(), &call("printenv", &[]));
        let names: BTreeSet<&str> = seen.keys().map(String::as_str).collect();
        assert_eq!(
            names,
            BTreeSet::from(["LC_ALL", "PATH"]),
            "the child saw more than PATH and LC_ALL"
        );
        for name in &ambient {
            assert!(!seen.contains_key(name), "{name} reached the child");
        }
        println!("{} ambient variables checked, none reached the child", ambient.len());
    }

    #[test]
    fn a_variable_in_the_base_environment_reaches_the_child() {
        let proc = RealProc::new(
            SEARCH_PATH,
            vec![("MX_PLANTED".to_string(), "planted-value".to_string())],
        );
        let out = proc.run(&call("printenv", &["MX_PLANTED"])).unwrap();
        assert_eq!(out.exit, ProcExit::Code(0));
        assert_eq!(text(&out.stdout), "planted-value\n");
        let other = proc.run(&call("printenv", &["MX_NOT_PLANTED"])).unwrap();
        assert_eq!(other.exit, ProcExit::Code(1), "an unplanted variable appeared in the child");
    }

    #[test]
    fn from_process_env_copies_only_the_allowed_names_the_process_has() {
        let (name, value) = std::env::vars_os()
            .filter_map(|(name, value)| Some((name.into_string().ok()?, value.into_string().ok()?)))
            .find(|(name, _)| name != "PATH" && name != "LC_ALL")
            .expect("the test process has no variable to allow");
        let proc =
            RealProc::from_process_env(SEARCH_PATH, &[name.as_str(), "MX_NO_SUCH_VARIABLE_1"]);
        let seen = env_of_child(&proc, &call("printenv", &[]));
        assert_eq!(seen.get(&name), Some(&value));
        assert!(!seen.contains_key("MX_NO_SUCH_VARIABLE_1"));
        assert_eq!(seen.len(), 3, "expected the allowed name, PATH and LC_ALL, got {seen:?}");
    }

    #[test]
    fn a_calls_own_variables_reach_the_child_and_beat_the_base_environment() {
        let proc = RealProc::new(SEARCH_PATH, vec![("MX_SHARED".to_string(), "base".to_string())]);
        let spec = call("printenv", &[]).env("MX_SHARED", "call").env("MX_CALL_ONLY", "1");
        let seen = env_of_child(&proc, &spec);
        assert_eq!(seen.get("MX_SHARED").map(String::as_str), Some("call"));
        assert_eq!(seen.get("MX_CALL_ONLY").map(String::as_str), Some("1"));
    }

    #[test]
    fn path_and_lc_all_belong_to_the_adapter_and_a_call_cannot_override_them() {
        let spec = call("printenv", &[]).env("LC_ALL", "de_DE.UTF-8").env("PATH", "/nonexistent");
        let seen = env_of_child(&proc(), &spec);
        assert_eq!(seen.get("LC_ALL").map(String::as_str), Some("C"));
        assert_eq!(seen.get("PATH").map(String::as_str), Some(SEARCH_PATH));
    }

    #[test]
    fn standard_output_and_standard_error_are_captured_separately() {
        let out = proc().run(&call("sh", &["-c", "echo to-out; echo to-err >&2"])).unwrap();
        assert_eq!(text(&out.stdout), "to-out\n");
        assert_eq!(text(&out.stderr), "to-err\n");
    }

    #[test]
    fn standard_input_reaches_the_child() {
        let out = proc().run(&call("cat", &[]).stdin("typed input")).unwrap();
        assert_eq!(text(&out.stdout), "typed input");
    }

    #[test]
    fn a_child_with_no_input_reads_end_of_file_at_once() {
        let out = run_bounded(proc(), call("cat", &[])).unwrap();
        assert_eq!(out.exit, ProcExit::Code(0));
        assert!(out.stdout.is_empty());
    }

    #[test]
    fn the_working_directory_is_applied() {
        let dir = TempDir::new("cwd");
        let out = proc().run(&call("pwd", &[]).cwd(dir.path())).unwrap();
        assert_eq!(text(&out.stdout).trim_end(), dir.path().to_str().unwrap());
    }

    #[test]
    fn arguments_are_passed_as_given_and_no_shell_reads_them() {
        let out = proc().run(&call("printf", &["%s\n", "a b", "$HOME", ";", "*"])).unwrap();
        assert_eq!(text(&out.stdout), "a b\n$HOME\n;\n*\n");
    }

    #[test]
    fn a_program_is_found_in_the_first_search_path_directory_that_holds_it() {
        let first = TempDir::new("first");
        let second = TempDir::new("second");
        std::os::unix::fs::symlink(system_binary("false"), first.path().join("mx-tool")).unwrap();
        std::os::unix::fs::symlink(system_binary("true"), second.path().join("mx-tool")).unwrap();
        let search = std::env::join_paths([first.path(), second.path()]).unwrap();
        let out = RealProc::new(search, Vec::new()).run(&call("mx-tool", &[])).unwrap();
        assert_eq!(out.exit, ProcExit::Code(1), "the second directory won over the first");
    }

    #[test]
    fn a_non_executable_file_is_skipped_for_a_later_executable_one() {
        let first = TempDir::new("plain");
        let second = TempDir::new("exec");
        std::fs::write(first.path().join("mx-tool"), "not a program").unwrap();
        std::os::unix::fs::symlink(system_binary("true"), second.path().join("mx-tool")).unwrap();
        let search = std::env::join_paths([first.path(), second.path()]).unwrap();
        let out = RealProc::new(search, Vec::new()).run(&call("mx-tool", &[])).unwrap();
        assert_eq!(out.exit, ProcExit::Code(0));
    }

    #[test]
    fn a_file_that_is_not_executable_is_named_as_such() {
        let dir = TempDir::new("plain-only");
        std::fs::write(dir.path().join("mx-tool"), "not a program").unwrap();
        let error = RealProc::new(dir.path(), Vec::new()).run(&call("mx-tool", &[])).unwrap_err();
        assert_eq!(error, ProcError::NotExecutable { program: "mx-tool".to_string() });
    }

    #[test]
    fn a_program_that_is_nowhere_on_the_path_is_not_found() {
        let error = proc().run(&call("mx-no-such-program", &[])).unwrap_err();
        assert_eq!(error, ProcError::NotFound { program: "mx-no-such-program".to_string() });
    }

    #[test]
    fn relative_and_empty_search_path_entries_are_skipped() {
        // A relative entry that reaches the directory holding `true` from the
        // test's working directory. A search that honoured it would find the
        // program, so the test cannot pass by the entry pointing nowhere.
        let holder = system_binary("true").parent().unwrap().to_path_buf();
        let depth = std::env::current_dir().unwrap().components().count() - 1;
        let mut relative = PathBuf::new();
        for _ in 0..depth {
            relative.push("..");
        }
        relative.push(holder.strip_prefix("/").unwrap());
        assert!(relative.join("true").is_file(), "{relative:?} does not reach true");
        for search in [relative.into_os_string(), OsString::new(), OsString::from(":")] {
            let error =
                RealProc::new(search.clone(), Vec::new()).run(&call("true", &[])).unwrap_err();
            assert_eq!(
                error,
                ProcError::NotFound { program: "true".to_string() },
                "path {search:?}"
            );
        }
    }

    #[test]
    fn a_program_name_with_a_slash_must_be_absolute() {
        let error = proc().run(&call("./true", &[])).unwrap_err();
        assert_eq!(error, ProcError::RelativeProgram { program: "./true".to_string() });
        let absolute = system_binary("true");
        let out = proc().run(&call(absolute.to_str().unwrap(), &[])).unwrap();
        assert_eq!(out.exit, ProcExit::Code(0));
    }

    #[test]
    fn the_child_sees_the_name_it_was_called_by_as_its_argv_zero() {
        let out = proc().run(&call("sh", &["-c", "printf %s \"$0\"", "named-zero"])).unwrap();
        assert_eq!(text(&out.stdout), "named-zero");
    }
}
