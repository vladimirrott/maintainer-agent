# Changelog

Every entry names what changed and, where it was a defect, the measurement that
found it. [`docs/lessons.md`](docs/lessons.md) carries the long form.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project uses [semantic versioning](https://semver.org/spec/v2.0.0.html).
While the major version is 0, a change that removes a capability moves the
middle digit.

## [Unreleased]

## [0.1.0] - 2026-09-03

First tagged version. It has maintained
[`lacs-project/sysknife`](https://github.com/lacs-project/sysknife) unattended
since 2026-09-02 and this repository since 2026-09-03.

### Added

- An orchestrator (`lib/run.sh`) that runs one maintenance pass and leaves an
  auditable trail: a report per run, a transcript of every command the agent
  ran, and a since-last-run baseline promoted only on success.
- Four backends: Claude Code (default), opencode, Codex and Cursor, each stating
  what it can and cannot contain. Only Claude and opencode can enforce a
  rehearsal, and `run.sh` refuses to hand `POST=off` to one that cannot.
- **A merge gate.** `maintainer-merge` is the only path to a merge and refuses
  without a receipt that somebody watched a guard go red, at a head whose
  production code matches. It also requires an approving review, zero failing
  and zero pending checks, a non-empty check list, a `CLEAN` or `HAS_HOOKS`
  merge state, and the owning GitHub account.
- **A rehearsal mode.** `POST=off` does the whole pass and reaches nobody: the
  deny wall gains every GitHub write verb, the prompt says so, and the tools the
  agent may call honour it. A scaffolded profile starts here.
- **A generated deny wall.** 32 verbs per profile, each spelled from every
  directory it could be run from, including the one it is installed in.
- `maintainer screen`, which decides whether a pull request may be executed on
  the host at all, and fails closed on anything it cannot classify.
- Profiles: `./new-profile.sh` scaffolds one for another repository, and nothing
  under `bin/` or `lib/` names a repository or an account.
- Scheduling on systemd, launchd, Windows Task Scheduler and cron, with the
  cadence held in `profile.env` rather than in the scheduler, because launchd
  cannot express one.
- `maintainer status`, `maintainer run`, `maintainer-doctor`,
  `maintainer-repo prune` and `maintainer-repo release-check`.
- 277 offline tests, 7 adversarial eval scenarios per profile, and a claim check
  that recounts every number in the README from the tree.

### Security

- The deny wall covers the directory each tool is actually installed in. Before
  that, `maintainer-merge receipt` was protected by a single bare-name rule
  while the binary lived in `~/.local/bin`, so writing the full path forged a
  receipt. `cargo publish` and `npm publish` had no absolute-path rule at all,
  and on Apple Silicon the gap would have let a `POST=off` rehearsal post,
  because Homebrew installs `gh` to `/opt/homebrew/bin`.
- A profile name can no longer reach `bash -c` unquoted.
- `MAINTAINER_FORCE` no longer travels into the agent's environment, and a run
  refuses to start inside another run.
- `maintainer-repo prune` and `maintainer-merge merge` honour `POST=off`. Both
  write from inside a script, where no deny rule can see them.

[Unreleased]: https://github.com/vladimirrott/maintainer-agent/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/vladimirrott/maintainer-agent/releases/tag/v0.1.0
