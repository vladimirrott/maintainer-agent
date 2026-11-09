//! Ports to the outside world, their fakes, and the one real adapter.
//!
//! Every program in magent talks to the world through six traits:
//! [`Gh`], [`Git`], [`Containers`], [`Clock`], [`Fs`] and [`Proc`]. Decision
//! code depends on the traits only, so a test replaces the world with a fake
//! that records every call as a typed [`Effect`] in an [`EffectLog`].
//!
//! # The one real adapter
//!
//! [`RealProc`] runs a program given as an argument vector, with no shell. It
//! resolves the program against an explicit search path, clears the
//! environment and passes only named variables plus `PATH` and `LC_ALL=C`,
//! bounds the run with a timeout, kills the whole process group when the
//! timeout expires, and reports a signal death as exit code `128 + signal`.
//!
//! This crate is the only place that may call `std::process::Command::new`.
//! `clippy.toml` bans the call workspace-wide, and `RealProc` holds the single
//! `#[allow]` with its reason.
//!
//! # Rules for the programs built on this crate
//!
//! - A fake with no scripted answer for a call panics. A stub that answers
//!   nothing makes a guard skip in silence, so the fake refuses instead.
//! - A secret travels in the environment of a call, never in its argument
//!   vector. [`Secret`] and [`ProcSpec`] print redacted in `Debug`.
//! - Rust ignores `SIGPIPE`, so a program that writes to a closed pipe gets an
//!   error where a shell script would have died quietly. Restoring the default
//!   `SIGPIPE` action is the job of each binary's `main`, not of this crate.

mod clock;
mod containers;
mod effect;
mod fs;
mod gh;
mod git;
mod proc;
mod real_proc;
mod script;
mod secret;

pub use clock::{Clock, ClockEffect, FakeClock};
pub use containers::{
    ContainerEffect, ContainerError, ContainerSpec, Containers, FakeContainers, Mount,
};
pub use effect::{Effect, EffectLog};
pub use fs::{FakeFs, Fs, FsEffect, FsError};
pub use gh::{CheckCounts, FakeGh, Gh, GhEffect, GhError, PrFacts};
pub use git::{FakeGit, Git, GitEffect, GitError};
pub use proc::{FakeProc, Proc, ProcEffect, ProcError, ProcExit, ProcOutput, ProcSpec};
pub use real_proc::RealProc;
pub use script::Script;
pub use secret::Secret;

use std::sync::{Mutex, MutexGuard, PoisonError};

/// Locks a mutex and keeps going if a panicking test poisoned it. The data is
/// a record of calls, and a test that panicked mid-call still wants to read it.
pub(crate) fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}
