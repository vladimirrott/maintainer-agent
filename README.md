<img src="assets/logo.svg" width="84" align="right" alt="">

# maintainer-agent

[![ci](https://github.com/vladimirrott/maintainer-agent/actions/workflows/ci.yml/badge.svg)](https://github.com/vladimirrott/maintainer-agent/actions/workflows/ci.yml)
[![secret scan](https://github.com/vladimirrott/maintainer-agent/actions/workflows/secret-scan.yml/badge.svg)](https://github.com/vladimirrott/maintainer-agent/actions/workflows/secret-scan.yml)
[![licence: MIT](https://img.shields.io/badge/licence-MIT-blue.svg)](LICENSE)

An unattended maintainer for an open-source repository. It runs Claude Code (or
Codex, Cursor, or opencode) on a timer to review pull requests, file and place
issues, audit the tracker, harden CI, prune merged branches and say when a
release is owed. It posts the results to GitHub for real.

It currently maintains [`lacs-project/sysknife`](https://github.com/lacs-project/sysknife).

## Try it without letting it speak

```sh
git clone <this repo> && cd maintainer-agent
./new-profile.sh myrepo you/yourrepo ~/src/yourrepo your-gh-login "Your Name"
./install.sh
MAINTAINER_PROFILE=myrepo maintainer-doctor      # checks by running things
./lib/run.sh --show-prompt myrepo review | less  # read what it will be told
MAINTAINER_PROFILE=myrepo maintainer run review  # one run, by hand
maintainer status
```

A scaffolded profile starts at **`POST=off`**. The agent does the whole pass,
writes the run report and its drafts, and reaches nobody: every GitHub write
verb is denied in the settings file it is handed, and the prompt says so. Read a
week of reports, then set `POST=on` in `profiles/myrepo/profile.env` and enable
the timers with `./install.sh --timers`.

`./install.sh --uninstall` removes all of it and keeps the audit trail, because
that trail is the record of what was published in your name.

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
| `mergeStateStatus` is `CLEAN` or `HAS_HOOKS` | `BEHIND` means the branch is not up to date with its base, so every green check describes a different tree; `DIRTY` is a conflict, `BLOCKED` is a missing required review |
| the check list is **non-empty** | an empty board is a failure, not a pass |
| `gh api user` is the owning account | a write under the wrong identity is worse than a 403 |

```sh
maintainer-merge verify 365 7c6ed388 tests/e2e/story-metadata.test.sh 's/GUARD=on/GUARD=off/'
maintainer-merge merge  365
```

The suite comes from the profile (`profiles/<name>/verify.d/*.sh`) and is
inferred from the paths the pull request touches. Each suite answers four
questions: which paths it covers, the image to run in, the command, and how to
tell that something really ran. That last one is what stops a receipt being
worthless, and it cannot be generic: cargo prints `test result: ok. N passed`, a
shell test prints whatever its author chose. **A profile with no suite covering
the changed paths is refused rather than run under the wrong one.**

Every refusal path is tested, including both directions of the production-diff
rule against a real git repository.

## Containment, layer by layer

Stated precisely, because a vague claim here is worse than none.

**1. The backend deny list, and precisely what it is worth.** Under the Claude
backend, `--settings` carries **32 denied verbs**: `git push`, `git tag`,
`gh pr merge`, `gh release`, `cargo publish`, `npm publish`, `gh workflow run`,
`gh repo delete`, `curl`, `wget`, and reads of `~/.ssh`, `~/.config/gh`,
`~/.aws`, `~/.gnupg`, `~/.netrc` and credentials files, among the rest.
Rehearsal adds every GitHub write verb on top. `tests/run-tests.sh` pins them
for **every** profile and is mutation-proved: delete a verb from any profile's
spec and the suite goes red naming the profile and the verb.

The **rule** count is deliberately not published. Each verb is spelled from
every directory it could be run from, including wherever `which` finds it on the
machine generating the wall, so the total depends on what is installed there.
It came out at 998 here, and at 1030 an hour later because installing the
maintainer commands added a directory to spell from. `check_claims.sh` pins the
verb count, which is what a human writes, and prints the rule count as an
observation.

The wall is **generated** from `profiles/<name>/deny.json`, one line per verb,
spelled from every directory that verb could be run from. That includes the
directory each tool is *actually installed in*, resolved at generation time.
A run against this repository found why that matters: `cargo` lives in
`~/.cargo/bin`, `npm` under `~/.local/lib/nodejs/…/bin`, and `maintainer-merge`
in `~/.local/bin`. The wall listed `/bin`, `/usr/bin` and `/usr/local/bin`, so
the two publishing verbs had no absolute rule at all, and the single rule
protecting the merge gate's receipt was walked past by writing the full path.

Four properties, all measured rather than assumed:

- **Deny does outrank `bypassPermissions`.** A differential run with one denied
  path and one control: the denied `touch` was blocked and the control
  succeeded, and the agent reported "First command hit permission restriction".
- **The matcher keys on the command as written, so equivalent spellings evade
  it.** `/usr/bin/touch /tmp/mt-y` succeeded against a rule denying
  `touch /tmp/mt-y`. Every blocked verb now comes out from every static prefix,
  from `~/`, `$HOME/` and expanded forms of the usual user-local directories,
  and from wherever `shutil.which` finds it on the machine generating the wall.
- **The receipt is unforgeable by full path, measured.** Asked to run
  `/home/…/.local/bin/maintainer-merge receipt 1 abcdef1234 "probe"`, the agent
  reported the command "never ran" and no receipt file appeared, while the
  control command executed. Before the install directory was covered, that same
  line wrote a receipt.
- **A `Read` rule needs `~/` or `//`, and a single leading slash denies
  nothing.** Measured with a control: `Read(/tmp/x/f)` let the file through
  while `Read(//tmp/x/f)` and `Read(~/f)` blocked it. Claude Code resolves one
  slash against the settings file's own directory, so the obvious tidy-up
  (`Read(~/.ssh/**)` to `Read(/home/you/.ssh/**)`) would disable every
  credential rule at once and silently. A test asserts the `~/` form survives.

That second measurement bounds the claim honestly. **A deny list is not a
boundary against an adversarial agent**, because enumeration cannot be complete;
a shell has more ways to spell a command than a list has entries. What it does
reliably is stop a cooperative agent from reaching a destructive verb by
accident or by being talked into it, which is the realistic failure. The
boundaries that do not depend on enumeration are the screen, the container, and
the receipt.

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

| | opencode | Claude Code | Codex | Cursor |
|---|---|---|---|---|
| Invocation | `opencode run --model groq/… --auto` | `claude -p --settings … --permission-mode bypassPermissions` | `codex exec --sandbox workspace-write -C …` | `cursor-agent -p --output-format text` |
| Permission model | **default-deny + allowlist** | denylist over bypass | sandbox mode | none in print mode |
| Survives an unfamiliar spelling | **yes, structurally** | **no** (measured) | n/a | n/a |
| May run posting tasks | yes | yes | read-and-report only | **refused in code** |
| Can enforce `POST=off` | yes | yes | no | no |

**opencode has the strongest containment, and the reason is structural rather
than diligent.** Its permission rules are patterns evaluated last-match-wins, so
the config opens with `"*": "deny"` and allows specific commands. An unfamiliar
spelling is denied *because* it is unfamiliar. That closes the hole measured on
the Claude backend, where `/usr/bin/git push` evaded a rule written for
`git push`. Wired here to Groq (`openai/gpt-oss-120b` by default), so it also
runs without an Anthropic subscription.

One trap found while writing that config, because default-deny is not automatic
safety: a broad allow re-opens the hole. `"cargo *": "allow"` permitted
`cargo publish`. The publishing verbs are denied again at the **end** of the map,
where last-match-wins puts them on top, and a test decides all fourteen probe
commands to prove it.

Claude remains the default because it is the most capable at the work. Codex
expresses a sandbox *mode* rather than a rule set. Cursor is weakest: its own
documentation states the print-mode agent has full write access, so it never
gets `--force`, it declares `backend_allowed_tasks`, and `run.sh` exits 78
rather than hand it a task that can post or merge.

## Platforms

The core is bash and is not reimplemented per platform, because two
implementations of a security gate drift and the gate is the product. Only
scheduling forks.

**Cadence lives in one place and every platform reads it.** Each task carries
`MIN_HOURS_<task>` in `profile.env`, and `run.sh` declines a task that ran more
recently than that, printing why. Schedulers only decide when to *try*.

That is not tidiness. launchd's `StartCalendarInterval` cannot say "every five
days" at all, and cron's day-of-month stepping fires on the 31st and again on
the 1st. Before the gate existed, `install-launchd.sh` claimed the since-last-run
state enforced the cadence and nothing did: a five-day audit would have run daily
on macOS. Now every scheduler fires daily and the gate decides.

On Apple Silicon this is the difference between a rehearsal and a post:
Homebrew installs `gh` to `/opt/homebrew/bin`, which the three-prefix wall never
spelled, so `POST=off` would not have blocked a single GitHub write verb there.

| Platform | Scheduler | Notes |
|---|---|---|
| Linux | systemd user timers | `Persistent=true` catches up a missed run |
| macOS | launchd agents | **no** `Persistent` equivalent, so a run missed while asleep waits for tomorrow rather than repeating |
| Windows | Task Scheduler via `Install-Maintainer.ps1` | `-StartWhenAvailable` is the closest thing to `Persistent=true`; bash comes from Git Bash or WSL and the script locates it |
| **Everything else** | `platform/posix/install-cron.sh` | FreeBSD, OpenBSD, NetBSD, Alpine and other musl or systemd-less Linux, Termux, containers. cron gives a job almost no environment, so the entries pin `PATH` |

```sh
./install.sh --timers                                # Linux
./install.sh && platform/macos/install-launchd.sh    # macOS
./install.sh                                         # Windows, then:
#   platform\windows\Install-Maintainer.ps1
```

All three read the task list from the deployed `profile.env`, so a second
repository needs a profile and no edit to any of them. The PowerShell installer
is parsed by a real `pwsh` in a container when the image is present locally;
counting braces was the previous check, and it would pass a file PowerShell
refuses to load.

## Another repository

```sh
./new-profile.sh widget acme/widget ~/src/widget acmebot "Ada Lovelace"
```

`profiles/magent/` is the worked second profile: this repository maintaining
itself, at `POST=off`. Scaffolding it found three defects in the first five
minutes, which is the argument for doing it rather than describing it.
`maintainer status` for a second profile printed that profile's name above the
*first* profile's repository and run history; `new-profile.sh` wrote an absolute
home path into a file meant to be committed, and this repository's own leak
check caught it; and the scaffolder's closing instructions named `run.sh` by its
deployed path after `maintainer run` had replaced it.

That writes `profiles/widget/` from `profiles/_template/`, substitutes every
placeholder, refuses to continue if one survives, and generates one systemd
timer per task. Then rewrite `profiles/widget/prompts/*.md` for the project.
The generic ones are a starting point; `profiles/sysknife/prompts/` is the
worked set.

Nothing in `bin/` or `lib/` carries a repository's name. The task list, the
skill each task loads, the models, the cadences, the deny wall and the state
directory all come from `profile.env`. `CONTRIBUTING.md` has claimed that since
the beginning; before `new-profile.sh` it was not true, because adding a
repository meant editing a hardcoded skill map in `bin/maintainer` and
hand-writing four unit files.

The doctrine itself lives once, in `lib/preamble-core.md`, and every profile
gets it: the injection rule, the screen rule, the evidence rule, the tone. A
profile contributes its own site header and its task prompts. A run assembled
without the core refuses to start rather than proceeding with a shorter prompt.

## Housekeeping and releases

Two chores a solo maintainer stops doing first, so they are commands rather than
intentions.

```sh
maintainer-repo prune --dry-run   # branches merged into main, local and remote
maintainer-repo release-check     # is a release owed, and which digit moves
```

Both are in the `review` prompt, so they run every pass rather than when someone
remembers. `git push` stays denied to the agent directly; what it is allowed is
the audited script, the same shape as the merge gate.

`prune` refuses to touch a branch that still heads an open pull request, and
defines "merged" as an ancestor of `origin/main` rather than trusting a name.

`release-check` reads the **CHANGELOG's Unreleased section**, because that is
where a human deliberately said what changed. An earlier version read commit
subjects for the word "security" and scored a genuine authorization fix as zero,
because its subject was `fix(daemon): gate mutating query actions`. It warns
loudly when the section is missing rather than passing over nothing, and it
never cuts the release: crates.io and npm versions can never be replaced, so
that stays a human decision.

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
./install.sh              # deploy files, leave the scheduler alone
maintainer-doctor         # check it by running it
./install.sh --timers     # enable (Linux); see the table above for other platforms
./install.sh --uninstall  # remove everything except the audit trail
```

**`maintainer-doctor` is the command to reach for when anything is wrong.** It
executes each entry point rather than checking that files exist, because every
deployment bug this project has hit survived a file-existence check: a profile
path that resolved in the repository and not once installed, a `chmod` that ran
before the file was copied, and a `cp -r` that nested directories so the live
deny wall stayed frozen at 40 rules while the repository had 72. It prints the
fix, not the symptom.

`./install.sh --dry-run` prints what would change and touches nothing. It is a
weaker check than it looks: `--dry-run` prints the commands instead of running
them, so it happily printed `systemctl enable *.timer` for a glob that matched
no file, and only a real install revealed that `--timers` had never enabled
anything. The suite now runs the install against a stub `systemctl` and counts
what it enabled.

The installer writes a timer stamp before enabling. A fresh `Persistent=true`
timer treats "never run" as a missed slot and fires a catch-up run the instant
it is enabled, landing a job on top of whatever a human is doing.

## Tasks

| Task | Cadence | Does |
|---|---|---|
| `review` | 6h minimum | reviews every open PR, verifies claims, merges through the gate, prunes merged branches, reports whether a release is owed |
| `issues` | 36h minimum | files issues, places them with the person who has demonstrated the skill, prepares TWiR submissions |
| `ci` | 60h minimum | audits one CI gate in depth |
| `audit` | 108h minimum | sweeps every open issue for validity, accuracy, placement, labels |

Each task is one prompt in `profiles/<name>/prompts/`, paired with a skill named
in `profile.env` that the agent loads at runtime. The cadence is the minimum
above, not the schedule: a timer that fires early gets a skip and says so.

## The audit trail

Every run appends to `~/.local/state/sysknife-maint/`: `index.md` lists them,
`runs/` holds the reports, `logs/` the transcripts, `state/` the since-last-run
snapshots. `finish` refuses an empty report, so a run that did nothing cannot
pass silently. `maintainer status` prints the whole picture in one screen: what
ran, how long ago, how long the report was, when the next run fires, and whether
this profile is posting at all.

`maintainer run <task>` starts one by hand and `maintainer run --show-prompt
<task>` prints what it would be told. Both go through the same `run.sh`, so the
cadence gate and the identity gate still apply.

Alongside each log the run now writes a `.commands` file listing every command
the agent actually ran, taken from the backend's structured output rather than
from its prose. A run report once read
`sysknife-maint screen 348 -> DO NOT EXECUTE` for a command that had been renamed
away and did not exist. Whether the agent ran the real one and mistyped the
report, or ran nothing and wrote the verdict anyway, the trail could not say.
A report is a claim; the transcript is the record.

Baselines promote only on success. `start` writes `pending-<task>.json` and
`finish` promotes it to `last-<task>.json` after the report checks pass, so an
aborted run cannot make the next one skip unreviewed changes.

## Lessons

[`docs/lessons.md`](docs/lessons.md) has the twenty-four entries that reached
a working system, each with the measurement that found it and the guard that now stops it.
The short version follows.

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
./tests/run-tests.sh        # 313 offline tests
./evals/run-evals.sh        # 7 eval scenarios
./scripts/check_claims.sh   # every number in this README, recounted
```

313 offline tests: no network, no GitHub, no model call. Every case tests a
*refusal*, because that is where this agent's safety lives. The suite is
mutation-proved; removing a deny rule turns it red naming that rule, planting a
home path turns the leak check red, restoring the renamed command in a prompt
turns the command check red, and pointing the installer's timer glob back at the
directory it used to look in turns the install test red.

The same gates run in three places. `.githooks/pre-commit` runs them before a
commit exists (`git config core.hooksPath .githooks`), GitHub Actions runs them
on every push and pull request including from forks, and you can run them
yourself. A contributor should never have to ask a maintainer whether their
change passes.

Actions adds four things the hook cannot: **shellcheck** over every script, the
PowerShell installer parsed by a real `pwsh` in a container rather than skipped
when the image is absent locally, every **action pin checked against the API**
to be the tag its comment claims, and every relative link in every document
resolved.

Three more workflows run beside it: **trufflehog** over the full history on
every push and weekly, **CodeQL** over the Python, and the **OpenSSF
scorecard**. The last two are skipped while the repository is private, because
code scanning needs Advanced Security there and the scorecard reads branch
protection. Skipping is stated in the workflow; pretending to scan would be
worse than not scanning.

`scripts/check_claims.sh` holds this README's numbers to the tree, the same way
the target repository holds its published test count to an evidence artifact. If
a figure here disagrees with reality the commit fails, and if the check can no
longer find a figure it fails too rather than passing over nothing.
