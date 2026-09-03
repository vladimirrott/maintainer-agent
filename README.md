# maintainer-agent

An unattended maintainer for an open-source repository. It runs Claude Code (or
Codex) on a systemd timer to review pull requests, file and place issues, audit
the tracker, and harden CI, and it posts the results to GitHub for real.

It currently maintains [`lacs-project/sysknife`](https://github.com/lacs-project/sysknife).

## Why this exists, and where it differs from the usual advice

The prevailing 2026 position on agentic maintenance is that an agent should
flag, suggest and summarise, while a human owns the merge. Tools like
[PR-Agent](https://github.com/The-PR-Agent/pr-agent) and
[pr-review-agent](https://github.com/agentuse/pr-review-agent) are built that
way, and the argument behind it is sound: an agent that cannot see every gate
has no business deciding a merge.

This project takes the argument seriously rather than ignoring it, and answers
it by making the gates visible. The agent does not merge. It verifies, reports,
and hands a ready-to-merge verdict to a human, and the one thing it is never
allowed to do is publish. What makes that safe is not good intentions in a
prompt; it is a deny list the model cannot argue with.

## Containment, layer by layer

Stated precisely, because a vague claim here is worse than none.

**1. The backend deny list.** Under the Claude backend, `--settings` carries
about forty deny rules that outrank `--permission-mode bypassPermissions`. The
agent runs with no approval prompts and still cannot reach `git push`,
`git tag`, `gh pr merge`, `gh release`, `cargo publish`, `npm publish`,
`gh workflow run`, `curl`, `wget`, or any read of `~/.ssh`, `~/.config/gh`,
`~/.aws`, `~/.gnupg`, `~/.netrc` or a credentials file. `tests/run-tests.sh`
pins every one of those and is mutation-proved: delete a rule and the suite goes
red naming it.

**2. The identity gate.** `run.sh` switches `gh` to the configured account,
reads the login back, and refuses to start if it is anything else. This is not
belt-and-braces. On this machine `gh`'s active account has been observed
flipping on its own, rewriting `user:` in `~/.config/gh/hosts.yml`. Unattended,
a 403 is the *good* outcome: a merge fails loudly, but a review comment would
post successfully under the wrong identity.

**3. The screen.** `maintainer screen <pr>` decides whether a pull request may
be built on this host at all. `cargo test` compiles and runs contributor code,
and `build.rs` runs it at *compile* time, so building an unscreened fork PR is
remote code execution with this machine's keys on disk. It returns
DO NOT EXECUTE for any diff touching `.rs`, `.sh`, `.py`, `.js`, `.ts`, a
dependency or a workflow, which is most of them. Unattended runs have no
fallback and must review by reading.

**4. podman, interactively only.** Anything that must actually run untrusted
code goes in a container with `--network=none`. Rootless podman works here; it
breaks under every systemd hardening directive tried, so the timers cannot use
it.

**What is NOT containment.** Mount isolation is unavailable on this host and the
directives for it were removed rather than left in looking protective. On
systemd 255 / Ubuntu 24.04, `ProtectHome`, `BindPaths` and `InaccessiblePaths`
are silently ignored for *user* units, and `bwrap` fails with
`setting up uid map: Permission denied`, both because
`kernel.apparmor_restrict_unprivileged_userns` is 1. A directive that no-ops is
worse than none: it reads as a guarantee.

## Backends

| | Claude Code | Codex |
|---|---|---|
| Verified against | 2.1.257 | codex-cli 0.149.1 |
| Invocation | `claude -p --settings … --permission-mode bypassPermissions` | `codex exec --sandbox workspace-write -C …` |
| Per-command deny list | **yes**, and it outranks bypass | **no** |
| Write confinement | filesystem-wide, rules-based | working tree, sandbox-based |

Codex expresses a sandbox *mode*, not a rule set, so it cannot say "everything
except `git push`, `gh pr merge` and `cargo publish`". Run publishing-capable
tasks on Claude. Codex is for read-and-report passes and second opinions, where
the blast radius is a comment. The test suite pins that warning so the default
cannot drift silently.

## Install

```sh
./install.sh              # deploy files, leave timers alone
./install.sh --timers     # deploy and enable
./install.sh --dry-run    # print what would change
```

The installer writes a timer stamp before enabling. A fresh `Persistent=true`
timer treats "never run" as a missed slot and fires a catch-up run the instant
it is enabled, landing a job on top of whatever a human is doing.

## Tasks

| Task | Cadence | Does |
|---|---|---|
| `review` | twice daily, 09:13 and 21:13 | reviews every open PR, verifies claims, reports ready-to-merge |
| `issues` | every 2 days | files issues, places them, prepares TWiR submissions |
| `ci` | every 3 days | audits one CI gate in depth |
| `audit` | every 5 days | sweeps every open issue for validity, accuracy, placement, labels |

Each task is one prompt in `profiles/<name>/prompts/`, paired with a skill the
agent loads at runtime.

## The audit trail

Every run appends to `~/.local/state/sysknife-maint/`: `index.md` lists them,
`runs/` holds the reports, `logs/` the transcripts, `state/` the
since-last-run snapshots. `finish` refuses an empty report, so a run that did
nothing cannot pass silently.

Baselines promote only on success. `start` writes `pending-<task>.json` and
`finish` promotes it to `last-<task>.json` after the report checks pass, so an
aborted run cannot make the next one skip unreviewed changes.

## Operational traps, each one paid for

- **Never edit `run.sh` while a run is in flight.** Bash reads a script by byte
  offset. An edit mid-run killed a job with `unexpected EOF` after seventeen
  minutes of real work, having already posted three comments. The body is
  wrapped in `main() { … }; main "$@"` so it is parsed whole before executing.
- **`systemd-analyze verify` checks syntax, not startability.**
  `ProtectKernelModules=yes` passed it and failed at runtime with
  `218/CAPABILITIES`, no log and no notification. Probe a unit with
  `ExecStart=/bin/true` before trusting it.
- **Restarting a timer fires its missed slots immediately** under
  `Persistent=true`. Editing a cadence and restarting launched a run against a
  tree a human was mid-way through reviewing.
- **Never pass a GitHub comment body through a double-quoted shell string.**
  Bash executes the backticks. A SHA vanished from a posted comment and the
  sentence lost its subject; the post still reported success. Use a quoted
  heredoc and `--body-file`.
- **A missing optional tool can turn a gate green.** Absent `cargo-nextest`,
  the target repo's `ci-local.sh` records `SKIPPED` and still ends `PASS`.
  Read summaries, not exit codes.

## Tests

```sh
./tests/run-tests.sh
```

Offline: no network, no GitHub, no model call. Every case tests a *refusal*,
because that is where this agent's safety lives. The suite is mutation-proved;
removing one deny rule turns it red naming that rule.
