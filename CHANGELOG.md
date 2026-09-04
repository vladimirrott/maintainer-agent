# Changelog

Every entry names what changed and, where it was a defect, the measurement that
found it. [`docs/lessons.md`](docs/lessons.md) carries the long form.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project uses [semantic versioning](https://semver.org/spec/v2.0.0.html).
While the major version is 0, a change that removes a capability moves the
middle digit.

## [Unreleased]

### Added

- **What a run cost, on every surface that mentions the run.** `maintainer
  digest <run-id>` prints it, `maintainer status` carries a `spend` column and a
  profile total, and a finished run now sends a desktop notification saying what
  it did and what it spent. Every figure is Claude Code's own reported usage, and
  every surface that prints the dollar amount says it is a client-side estimate
  from a bundled price table rather than a bill.
- **A notification for a run that SUCCEEDED.** Until now the agent spoke to its
  owner only to complain, which trains a person to read every popup as bad news.

### Fixed

- **A run recorded its input as `in=48`.** The usage line logged
  `input_tokens` alone, and in an agent run almost every input token is a cache
  read or a cache write, both of which are separate fields. The number was true
  and useless, and it read as a measurement. Cache creation, cache reads, the
  per-model breakdown and the turn count are all recorded now, in a
  machine-readable file beside the log, for failed runs as well as successful
  ones. Not counted with a tokenizer: `tiktoken` is OpenAI's, it undercounts
  Claude by 15-20% on prose and by more on code, and the exact figures are
  already in the stream.
- **Every scheduled run failed for the first hour after v0.2.0 was deployed.**
  `bin/maintainer` stopped defaulting to a hardcoded profile in that release and
  now refuses when two are deployed and none is named, which is right, but
  `lib/run.sh` called it without saying which profile it was running. It failed
  closed and alerted, which is the only reason this was an hour. The test that
  should have caught it replaces `maintainer` with a stub that ignores its
  environment.
- **The failure notification was a shell error.** It passed the raw message
  straight to `notify-send`, absolute path and all, with no next step. Known
  failures are translated into a sentence and a fix; anything unrecognised still
  goes through verbatim, because a wrong translation is worse than none.
- **The `OnFailure` alert left no trace.** It only called `notify-send`, so a
  failure at 03:00 left a popup that was gone by morning. It appends to
  `logs/alerts.log` too. It also moved out of the unit file, which refused the
  inline shell with `Unbalanced quoting, ignoring` while `systemd-analyze
  verify` reported that and exited 0.
- **The digest read the newest `*.commands` in the directory** rather than the
  one belonging to the run, so it printed another run's command count. Third
  instance of `docs/lessons.md` 30.

## [0.2.0] - 2026-09-04

The middle digit moves because six things that used to succeed now refuse. Every
one of them turned up by pointing this agent at a repository and reading what it
did.

Most of what is here came from two live pull requests on
[`lacs-project/sysknife`](https://github.com/lacs-project/sysknife). Both were
correct, both were mergeable, and neither could be merged: one touched only
shell scripts and one touched only prose, and the gate could verify neither.
Refusing to merge is the safe outcome, which is exactly why both gaps sat there
unnoticed.

### Removed

- **An unattended run can no longer assert a receipt.** `maintainer-merge
  receipt` records a sentence a human typed; `verify` records what it watched
  happen. A run may use only the second. `receipt` refuses inside a run, the
  deny wall spells the command, and `merge` refuses any receipt that is not
  `kind: observed` while a run is in progress. Only the third survives an agent
  editing its own environment.
- **An unsigned receipt no longer merges.** The receipt was a JSON file in the
  state directory whose only protection was a deny rule on one CLI verb, while
  the deny wall emits `Bash()` and `Read()` rules and nothing else. An agent
  holding an ordinary write tool could create it by hand with
  `"kind": "observed"`. Payloads are HMAC-signed by a key `install.sh` mints at
  mode 0600, and an edited receipt is refused by name.
- **A profile that declares no `PROD_GLOBS` no longer merges.** The list of
  production paths was hardcoded to one project's directories, so on every other
  repository it named paths that do not exist and every rebase looked harmless.
  There is no default: guessing which paths are production is how the bug
  worked.
- **`maintainer` no longer guesses a profile.** With two deployed and none
  named, it reported the wrong one, and `maintainer run review` would have
  started a real posting run against the wrong repository. It enumerates and
  refuses.
- **A task name containing a hyphen is refused.** `run.sh` builds `MODEL_$task`
  as a shell variable name and `cmd_finish` recovers the task from the run id,
  so a hyphen made the baseline silently never promote.
- **A tree whose symlinks leave it is refused verification.** The mutation step
  runs on the host, and `sed -i` through a tracked symlink writes the target's
  plaintext into a tree that is then mounted into the container. Reproduced end
  to end. The first version of this refused *every* symlink and so refused
  sysknife's own `docs/images/…` link, which had been on main for months.

### Added

- **An MCP server** (`bin/maintainer-mcp`), stdlib-only, over stdio. Six tools
  and three resources. Every mutation shells out to the real binary rather than
  reimplementing it, so the gate is the same gate. No `receipt`, no publish, no
  tag, no shell. `prune` is always a dry run.
- **Verification runs in a container**, hardened and probed:
  `--network=none --cap-drop=ALL --security-opt=no-new-privileges --read-only`,
  a `noexec,nosuid` tmpfs, pid, memory and CPU caps, and the runtime's own
  `--timeout`. GNU `timeout` kills the client, not the container, which left two
  containers spinning three minutes after the gate reported a refusal.
  `tests/containment-probe.sh` runs eleven adversarial payloads against it.
- **Verification suites per language** (`profiles/<name>/verify.d/*.sh`). Each
  answers four questions: which paths it covers, the image, the command, and how
  to tell that something ran. The `sysknife` profile ships `rust`, `shell` and
  `docs`. A profile with no suite covering the changed paths is refused rather
  than run under the wrong one.
- **A thinking budget per task**, measured rather than assumed, and
  `maintainer version` plus a drift warning in `maintainer status` when the
  checkout and the deployed tree disagree.
- `docs/user-stories.md`: forty situations a maintainer meets, each mapped to
  what this does today and what it does not.
- `docs/containment.md`, `docs/deploy/` and `examples/github-actions-review.yml`.
- Release, CodeQL, Scorecard and secret-scanning workflows, every action pinned
  by SHA with a script that checks each pin against the API.
- A mark made of the characters the tool is made of.
- **Verification suites for this repository itself** (`profiles/magent/verify.d/`).
  The profile had none, so the merge gate could not verify a pull request
  against the repository that contains the merge gate.
- **A third test outcome, `SKIP`.** A case this machine cannot run is counted
  and printed separately, and CI fails when the count is not zero. The suite's
  own size no longer depends on the machine: host and container both report
  396, which matters because `check_claims.sh` compares that number to the
  README.

### Fixed

- **The merge gate did not work from inside a run.** `lib/profile.sh` returned
  early on `MAINTAINER_SLUG` and `MAINTAINER_REPO` alone while
  `maintainer-merge` reads `MAINTAINER_ACCOUNT` under `set -u`, so every call
  from a run died on an unbound variable, and a run is the only way an agent
  ever calls it. The tests missed it by setting up a more complete environment
  than production provides.
- **The container runtime wrote the receipt.** podman logs
  `level=warning msg="Error validating CNI config file …"` onto the container's
  own stderr. It was the first line matching the failure grep, so a receipt
  recorded a CNI warning as its proof, and it is bytes, so the vacuity check
  that exists to refuse a receipt for a run that executed nothing counted it as
  evidence. A missing optional `suite_podman_args` did the same thing ten times
  over, taking `units_run` from 2 to 10.
- **The shellcheck sweep lived only in CI**, so a commit could pass every gate
  this project runs locally and a push would then report four SC1090s. It is
  `scripts/shellcheck-sweep.sh` now, called by both, and it exits 127 rather
  than 0 when shellcheck is missing.
- `install.sh --timers` globbed a directory that does not exist, so it installed
  nothing and said it had.
- `run-instance.sh` split the systemd instance name on the first hyphen, so a
  profile named after a hyphenated repository became profile `my`, task
  `repo-review`.
- The prompts named a command that had been renamed. A check now reads every
  assembled prompt for commands that do not exist.
- Live-mode evals died on an unbound `MAINTAINER_TASK` before reaching the
  model, so the only mode that measures behaviour had never run.
- A receipt's proof string was interpolated into JSON by a heredoc, so a proof
  containing a quote wrote a file the gate could not parse, and the refusal
  blamed the receipt rather than the quoting.
- **`profiles/magent` declared no thinking budget**, because the template grew
  `THINKING_<task>` after that profile had been generated from it. A missing
  budget is a default, not an error, so nothing said so: the agent maintaining
  the merge gate thought less about it than the agent maintaining the target
  repository did. Every profile is now required to declare a model and a budget
  for every task it runs.
- **`maintainer-doctor` reported another profile's timers as this one's.** The
  scheduler check globbed `maintainer@*`, so asked about `magent` it counted
  `sysknife`'s four timers and said "4 systemd timer(s) registered, ok" while
  `magent` had two timer files, both disabled, and had never fired. It names the
  profile now, and separates a timer that is missing from one that is installed
  and never enabled, because those need different fixes.
- **`maintainer status` died on any host without systemd.** `_next_runs` called
  `systemctl` by name with no guard, so it printed three lines and then an
  uncaught `FileNotFoundError`. Three of the four schedulers this project
  documents are not systemd. Every other spawn now names the missing binary
  instead of printing a traceback.
- **The merge gate needed `jq`**, in three places, and nothing else here does.
  Without it the counts came back empty and the refusal read
  `#7 has  failing check(s)`. It fails closed either way, and now it says which
  thing it could not read.
- The claim check read `388 tests` out of the SHA `7c6ed388`.
- `release-check`'s "the Unreleased section is empty" warning had never printed:
  sed prints both delimiters, so an empty section came back as two heading lines
  and the emptiness test was false. Found while cutting this release, which it
  scored as a patch. It also names which tree it read the CHANGELOG from, since
  every other number in that report comes from `origin/main`.
- The fork-bomb probe was `if [ -n "$out" ] || true`, which is true whatever
  happens: with `--pids-limit` deleted it still reported the bomb stopped. In
  the file that exists to catch exactly that.

### Security

- Commit subjects go through the same filter as pull request titles. A
  squash-merge subject is usually the pull request title, so the same
  attacker-controlled text was filtered when read from the PR list and passed
  through raw when read from the log.
- `maintainer-doctor` validates the profile name before it reaches `python3 -c`,
  which `bin/maintainer` already did and this did not.
- The receipt-signing key sits in every profile's credential deny list.


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

[Unreleased]: https://github.com/vladimirrott/maintainer-agent/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/vladimirrott/maintainer-agent/releases/tag/v0.2.0
[0.1.0]: https://github.com/vladimirrott/maintainer-agent/releases/tag/v0.1.0
