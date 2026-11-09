# magent in Rust

A Cargo workspace for the programs that replace magent's shell scripts. Nothing is ported yet. This is the typed foundation and its gate.

- `crates/mx-core`: `Fact<T>`, `Refusal`, `NonEmpty<T>`. No I/O.
- `crates/mx-ports`: the `Gh`, `Git`, `Containers`, `Clock`, `Fs` and `Proc` traits, an in-memory fake for each, and `RealProc`, the one real adapter.

Run the gate from the repository root: `scripts/rust-gate.sh`. It runs `cargo fmt --all --check`, `cargo clippy --workspace --all-targets --locked -- -D warnings`, `cargo test --workspace --locked` (more than 15 tests must run), and a probe that adds a crate calling `Command::new` and demands clippy refuse it. CI runs the same script as the `rust` job.

Three rules:

1. Only `mx-ports` starts a process. `clippy.toml` bans `std::process::Command::new`, and `RealProc` holds the one `#[allow]`. Everything else asks a `Proc`.
2. `Refusal::exit_code` has no `_` arm. A new variant does not compile until it has an exit code, and a test fails when a code changes.
3. `Fact::Unreadable` never becomes `Fact::Absent`. A read that failed is not a read that found nothing.

A binary's `main` restores the default `SIGPIPE` action, because Rust ignores it.
