use crate::{Effect, EffectLog, ProcOutput, Script, lock};
use mx_core::NonEmpty;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Duration;
use thiserror::Error;

/// A bind mount.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Mount {
    pub host: PathBuf,
    pub container: PathBuf,
    pub read_only: bool,
}

/// What to run in a container. No secret belongs here: the container runs code
/// from a pull request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContainerSpec {
    pub image: String,
    pub argv: NonEmpty<String>,
    pub env: Vec<(String, String)>,
    pub mounts: Vec<Mount>,
    /// A memory limit in the runtime's own syntax, such as `6g`.
    pub memory: Option<String>,
    /// Whether the container gets a network. Off unless a caller turns it on.
    pub network: bool,
    pub timeout: Duration,
}

/// A container call failed.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ContainerError {
    /// Neither podman nor docker is installed.
    #[error("no container runtime; install podman or docker")]
    NoRuntime,
    /// The runtime ran and failed.
    #[error("the container runtime failed: {0}")]
    Failed(String),
}

/// A container runtime.
pub trait Containers {
    /// The runtime in use, for example `podman`.
    fn runtime(&self) -> Result<String, ContainerError>;

    /// Runs a command in a container and returns how it ended.
    fn run(&self, spec: &ContainerSpec) -> Result<ProcOutput, ContainerError>;
}

/// One call to a [`Containers`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ContainerEffect {
    Runtime,
    Run(ContainerSpec),
}

/// A scripted [`Containers`] that records its calls.
#[derive(Debug)]
pub struct FakeContainers {
    log: EffectLog,
    runtime: Mutex<Script<Result<String, ContainerError>>>,
    run: Mutex<Script<Result<ProcOutput, ContainerError>>>,
}

impl FakeContainers {
    /// A fake with no scripted answers.
    #[must_use]
    pub fn new(log: &EffectLog) -> Self {
        Self { log: log.clone(), runtime: Mutex::default(), run: Mutex::default() }
    }

    /// Scripts the answers to `runtime`.
    pub fn script_runtime(&self, script: Script<Result<String, ContainerError>>) {
        *lock(&self.runtime) = script;
    }

    /// Scripts the answers to `run`.
    pub fn script_run(&self, script: Script<Result<ProcOutput, ContainerError>>) {
        *lock(&self.run) = script;
    }
}

impl Containers for FakeContainers {
    fn runtime(&self) -> Result<String, ContainerError> {
        self.log.push(Effect::Containers(ContainerEffect::Runtime));
        lock(&self.runtime).next("Containers::runtime")
    }

    fn run(&self, spec: &ContainerSpec) -> Result<ProcOutput, ContainerError> {
        self.log.push(Effect::Containers(ContainerEffect::Run(spec.clone())));
        lock(&self.run).next("Containers::run")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ProcExit;

    fn spec() -> ContainerSpec {
        ContainerSpec {
            image: "rust:1".to_string(),
            argv: NonEmpty::new("cargo".to_string(), ["test".to_string()]),
            env: vec![("CARGO_BUILD_JOBS".to_string(), "4".to_string())],
            mounts: vec![Mount {
                host: PathBuf::from("/work"),
                container: PathBuf::from("/src"),
                read_only: true,
            }],
            memory: Some("6g".to_string()),
            network: false,
            timeout: Duration::from_mins(1),
        }
    }

    #[test]
    fn a_missing_runtime_is_a_named_error() {
        let log = EffectLog::new();
        let containers = FakeContainers::new(&log);
        containers.script_runtime(Script::always(Err(ContainerError::NoRuntime)));
        assert_eq!(containers.runtime(), Err(ContainerError::NoRuntime));
    }

    #[test]
    fn a_run_returns_its_scripted_output_and_records_the_whole_spec() {
        let log = EffectLog::new();
        let containers = FakeContainers::new(&log);
        containers.script_run(Script::always(Ok(ProcOutput {
            exit: ProcExit::Code(0),
            stdout: b"ok".to_vec(),
            stderr: Vec::new(),
        })));
        let out = containers.run(&spec()).unwrap();
        assert_eq!(out.exit, ProcExit::Code(0));
        assert_eq!(log.entries(), vec![Effect::Containers(ContainerEffect::Run(spec()))]);
    }
}
