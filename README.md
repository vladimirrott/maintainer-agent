# maintainer-agent

An unattended maintainer for an open-source repository. It runs Claude Code (or
Codex) on a systemd timer to review pull requests, file and place issues, audit
the tracker, and harden CI, and it posts the results to GitHub for real.

It currently maintains [`lacs-project/sysknife`](https://github.com/lacs-project/sysknife).

## This is a maintainer, not a PR bot

Reviewing diffs is the visible part of maintaining and not the part that ends
projects. [`docs/maintainer-doctrine.md`](docs/maintainer-doctrine.md) works
through three documented cases and what each one changes here:

- **xz-utils.** An isolated, burnt-out maintainer was socially engineered into
  granting commit rights, and the backdoor followed. So this agent makes **no
  trust decisions at all**: it never grants or recommends access, and it never
  relaxes a gate because someone asks, insists or repeats. Persistence raises
  suspicion rather than lowering the bar.
- **curl.** One security submission in five was AI slop that named real
  functions and contained nothing; the confirmed-vulnerability rate fell from
  over 15% to under 5% and the project closed a bounty it had run since 2019. An
  AI maintainer is one design mistake away from being that. So every number it
  publishes is recounted with a command, every path resolves against the tree,
  every guard is mutated before it is called a guard, and a run that found
  nothing posts nothing.
- **Everyone.** Most maintainer time goes to questions the documentation should
  have answered, and nearly 60% of maintainers have quit or considered it. The
  tasks target volume, not just diffs.

## Merging: a receipt, not a rule

The prevailing 2026 position is that agents should recommend and humans should
merge ([PR-Agent](https://github.com/The-PR-Agent/pr-agent),
[pr-review-agent](https://github.com/agentuse/pr-review-agent)), because an agent
that cannot see every gate should not decide. The reasoning is right; "never
merge" is a proxy for it. What actually makes a merge safe is evidence that a
guard fails when the change is removed, and a green board cannot show that. This
repository's recurring defect is a test that passes with the fix reverted.

So `gh pr merge` stays denied and `maintainer-merge` is the only path. It
refuses unless **all** of these hold:

| Condition | Why |
|---|---|
| a **verification receipt** exists for the PR | somebody mutated the guard and watched it go red |
| **no production or CI diff** since the head the receipt names | a rebase may move tests and docs; if it moved `crates/*/src`, `.github` or a manifest, the receipt describes a tree that is gone |
| `reviewDecision` is `APPROVED` | a force-push can dismiss it |
| zero failing **and zero pending** checks | pending is not green |
| the check list is **non-empty** | an empty board is a failure, not a pass |
| `gh api user` is the owning account | a write under the wrong identity is worse than a 403 |

```sh
maintainer-merge receipt 348 0e37a664 "dropped GetSystemState from the allowlist; drift test went red"
maintainer-merge merge 348
```

Every refusal path is tested, including both directions of the production-diff
rule against a real git repository.

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

**4. podman, including from the timers.** Anything that must actually run
untrusted code goes in a container with `--network=none`. Rootless podman cannot
*establish* a user namespace under this hardening, because `newuidmap` is setuid
and both `NoNewPrivileges` and `RestrictSUIDSGID` block it, but it can *reuse*
one. Measured here: cold plus full hardening failed 10 times out of 10; warm
plus full hardening succeeded. So `podman-userns-warmup.service`, deliberately
unhardened and running one fixed command with no model output, establishes the
namespace, and the maintainer unit is ordered after it and stays hardened.
Verified from cold three times with the warm-up and once without: 3/3 versus a
failure. Without that ordering, container verification would silently vanish
after a reboot, and a merge gate that quietly stops verifying still merges.

**What is NOT containment.** Mount isolation is unavailable on this host and the
directives for it were removed rather than left in looking protective. On
systemd 255 / Ubuntu 24.04, `ProtectHome`, `BindPaths` and `InaccessiblePaths`
are silently ignored for *user* units, and `bwrap` fails with
`setting up uid map: Permission denied`, both because
`kernel.apparmor_restrict_unprivileged_userns` is 1. A directive that no-ops is
worse than none: it reads as a guarantee.

## Backends

Three, and they are **not** interchangeable. The difference is containment, and
it is the reason there is a default.

| | Claude Code | Codex | Cursor |
|---|---|---|---|
| Verified against | 2.1.257 | codex-cli 0.149.1 | documented CLI |
| Invocation | `claude -p --settings … --permission-mode bypassPermissions` | `codex exec --sandbox workspace-write -C …` | `cursor-agent -p --output-format text` |
| Per-command deny list | **yes**, outranks bypass | no | no |
| Write confinement | rules-based, filesystem-wide | sandbox mode, working tree | **none in print mode** |
| May run posting tasks | yes | read-and-report only | **refused in code** |

**Claude is the default and the only backend trusted with a task that can post,
publish or merge.** Codex expresses a sandbox *mode* rather than a rule set, so
it cannot say "everything except `git push`, `gh pr merge` and `cargo publish`".
Cursor is weaker still: its own documentation states that in non-interactive
mode the agent has full write access, and `--force` turns proposals into writes,
so this backend never passes `--force` and declares `backend_allowed_tasks`.
`run.sh` reads that declaration and refuses a task the backend is not fit for,
exiting 78. A comment would have drifted; a refusal in code does not.

## Platforms

The core is bash and is not reimplemented per platform, because two
implementations of a security gate drift and the gate is the product. Only
scheduling forks.

| Platform | Scheduler | Notes |
|---|---|---|
| Linux | systemd user timers | `Persistent=true` catches up a missed run |
| macOS | launchd agents | **no** `Persistent` equivalent; a missed run does not catch up, and cadence longer than a day is enforced by the since-last-run state rather than by the schedule |
| Windows | Task Scheduler via `Install-Maintainer.ps1` | `-StartWhenAvailable` is the closest thing to `Persistent=true`; bash comes from Git Bash or WSL and the script locates it |

```sh
./install.sh --timers                       # Linux
./install.sh && platform/macos/install-launchd.sh   # macOS
./install.sh                                # Windows, then:
#   platform\windows\Install-Maintainer.ps1
```

The PowerShell is checked statically here (balanced blocks, real cmdlets, a
`param` block) because `pwsh` is not installed on the development machine. That
is a weaker check than parsing and is labelled as such in the suite.

## Evals

7 adversarial eval scenarios in `evals/scenarios/`, each one a situation with a
required behaviour, a "must not", and the file where the governing rule lives.
They are drawn from the doctrine: prompt injection, trust escalation in the
xz-utils shape, an AI-slop report, a merge with no proof, a reserved issue
offered to a regular, a publishing verb, and a real security finding.

```sh
./evals/run-evals.sh          # static: is the governing rule still present?
./evals/run-evals.sh --live   # ask the backend and read its answers
```

Static mode is free and runs in the pre-commit hook. It cannot tell you the
agent behaves correctly; it tells you the rule that governs the behaviour has
not been deleted, which is the regression that actually happens. It is
mutation-proved: reword a rule in the preamble and the matching scenario fails.
Live mode costs tokens, prints answers rather than scoring them, and is
deliberately not wired into any hook.

## Prose

Everything the agent publishes goes through a prose discipline: no em dashes, no
throat-clearing, no "not X, it's Y", active voice, no adverbs, and never a
sentence that sounds technical without a command behind it. It is an **opt-out**
(`MAINTAINER_PROSE_STYLE=raw`), and only that exact value disables it, so a typo
still writes well.

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
./tests/run-tests.sh        # 66 offline tests
./evals/run-evals.sh        # 7 eval scenarios
./scripts/check_claims.sh   # every number in this README, recounted
```

66 offline tests: no network, no GitHub, no model call. Every case tests a
*refusal*, because that is where this agent's safety lives. The suite is
mutation-proved; removing one of the 40 deny rules turns it red naming that
rule, and planting a home path turns the leak check red.

There is no CI. This is a private repository with one maintainer, so the gate
runs before the commit exists rather than after: `.githooks/pre-commit` runs
`bash -n` over every script, the test suite, the evals, and the claim check.
Install it with `git config core.hooksPath .githooks`.

`scripts/check_claims.sh` holds this README's numbers to the tree, the same way
the target repository holds its published test count to an evidence artifact. If
a figure here disagrees with reality the commit fails, and if the check can no
longer find a figure it fails too rather than passing over nothing.
