# What deploying this taught, and what each lesson became

Every entry is a defect that reached a working system, the measurement that
found it, and the guard that now stops it. Nothing here is advice; each one cost
something.

## 1. "The file is there" is not "the system runs"

Four separate bugs, one shape.

- `run.sh` resolved profiles as `$(dirname $0)/..`, right in the repository and
  wrong once installed beside them. The unit exited **64** and the timer logged
  nothing.
- The same for `lib/backends`, found only because the first fix's test started
  the script instead of listing files.
- A clean install left `run-instance.sh` unexecutable, because `chmod` ran
  before the platform dispatch that copies it.
- `cmd_verify` shipped having never been executed once.

I had "verified" the deployment by checking that files existed. Every one of
these survives that check.

**Guard:** `maintainer doctor` runs each entry point rather than stat-ing it,
and the test suite installs into a scratch home and asserts executability.

## 2. `cp -r src dst` copies *into* `dst` when `dst` exists

A second install nested `profiles/profiles/` and `backends/backends/`. The
render step then wrote the new deny wall into the nested copy, and the live
agent carried **40 rules while the repository had 72**. Silent, and it survived
a full test run because the tests read the repository, not the deployment.

**Guard:** destinations are removed before copying, and a test installs twice
and compares the deployed rule count against the repository's.

## 3. Calibrate a checker before believing it

The first tracker sweep flagged **37 of 37** open issues. That is not a finding
about the tracker, it is a broken checker: it matched URLs as file paths and
truncated `.json` to `.js` through a bad alternation order. After restricting to
backticked paths and splitting repo-relative from prose basename from
upstream-dependency, five candidates remained and one was real.

A flag rate near 0% or near 100% is a bug in the check.

**Guard:** `sysknife-issue-audit`'s first section is about the auditor, not the
tracker.

## 4. A probe can measure its own bad pattern

Investigating whether deny rules survive `bypassPermissions`, the first probe
showed four of four commands succeeding, which reads as "containment is a
fiction". It was not. `Bash(touch /tmp/denied-probe:*)` never matched
`touch /tmp/denied-probe-a`, because the matcher is token-based rather than
string-prefix. A differential probe with a control then showed deny working
exactly as documented.

I was one step from reporting a broken security wall on the strength of a broken
probe.

**Guard:** always run a control alongside the case, and read ground truth from
the filesystem rather than from the agent's own summary.

## 5. A check must not match its own source

The leak check searched the repository for a home path and found one: its own
source line. Same shape as the `--force` check that read the comments explaining
why `--force` is absent, and the merge-gate count that read prose describing the
gate as a second implementation.

**Guard:** assemble the needle at runtime (`needle="entro""pia"`), exclude the
checking file, and strip comments before matching on code.

## 6. A deny list is spelling-specific, so it is not a boundary

Measured: `/usr/bin/touch /tmp/mt-y` succeeded against a rule denying
`touch /tmp/mt-y`. Absolute paths, `git -C`, and compound commands all present a
different string to the matcher.

Enumeration cannot be complete. A denylist reliably stops a *cooperative* agent
reaching a destructive verb by accident or persuasion, which is the realistic
failure; it does not contain a hostile one.

**Guard:** absolute-path forms are denied too (40 rules became 72), the README
states the bound instead of implying there is none, and where a backend supports
**default-deny with an allowlist** (opencode) that posture is used instead,
because an unlisted spelling then falls through to deny rather than to allow.

## 7. Rootless podman can reuse a namespace it cannot establish

`newuidmap` is setuid, so `NoNewPrivileges` and `RestrictSUIDSGID` stop podman
creating a user namespace. Measured: cold plus full hardening failed **10/10**;
warm plus full hardening succeeded, because podman reused the pause process.

Relying on that accidentally would mean container verification silently vanishes
after a reboot, and a merge gate that quietly stops verifying still merges.

**Guard:** an unhardened warm-up unit running one fixed command establishes the
namespace; the maintainer unit is ordered after it and stays hardened. Verified
from cold 3/3 with the ordering, failing without.

## 8. Enabling or restarting a timer fires its missed slots at once

`Persistent=true` treats "never run" as a missed slot. Editing a cadence and
restarting launched a run on top of an interactive session that was mid-review,
and two agents posting to the same pull requests is a real duplicate-comment
risk.

**Guard:** the installer writes `~/.local/share/systemd/timers/stamp-<unit>`
before enabling, and `doctor` reports any timer whose next run is suspiciously
close to now.

## 9. The GitHub identity can change under a long-running session

`gh`'s active account flipped to a different account twice in one session,
rewriting `user:` in `~/.config/gh/hosts.yml`. A 403 is the lucky outcome; a
review posted under the wrong identity is the unlucky one.

**Guard:** `run.sh` switches, reads the login back, and exits with a desktop
alert if it is not the configured account. Mutation-proved in three directions,
including a broken `gh` returning nothing.

## 10. Never put a GitHub comment body in a double-quoted shell string

Bash executed the backticked SHA, so it vanished from a posted comment and the
sentence lost its subject. The post still reported success; only stderr said
`083d582: command not found`.

**Guard:** quoted heredoc and `--body-file`, always. Read back the first lines
of anything posted.

## 11. A dry run cannot see a glob that matches nothing

`./install.sh --timers` globbed `$root/systemd/*.timer`. This repository has
never had a `systemd/` directory; the units live under `platform/linux`. With
`nullglob` off the loop ran once on the literal pattern, and
`systemctl --user enable --now '*.timer'` aborted the install under `set -e`
having enabled nothing.

`--dry-run` printed `would: systemctl --user enable --now *.timer` and exited 0,
because a dry run prints commands instead of running them. The documented Linux
install path was broken and every dry run said it was fine. It only worked here
because the timers had been enabled by hand months earlier.

**Guard:** the suite runs the real installer against a stub `systemctl` and
counts what it enabled against the number of `.timer` files in the tree. Point
the glob back at `$root/systemd` and the suite goes red.

## 12. A prompt that names a renamed command gets a verdict anyway

The preamble told every unattended run, in bold, to call
`sysknife-maint screen <pr>` before building a pull request. That command was
renamed to `maintainer screen` and `sysknife-maint` no longer exists anywhere on
`PATH`. The screen is the control that stops contributor code executing on a
machine holding SSH keys.

The 2026-09-03 review report reads `sysknife-maint screen 348 -> DO NOT EXECUTE`.
Either the agent ran the real command and copied the prompt's dead name into the
report, or it ran nothing and wrote a plausible verdict. The audit trail could
not distinguish those, which is the deeper defect.

**Guard, two of them.** `profile.env` declares `REQUIRED_COMMANDS` and
`KNOWN_NAMES`; a test extracts every hyphenated backticked name from the
*assembled* prompt of every task and fails on anything undeclared, and fails
again on a declaration no prompt uses so the list cannot be padded quiet.
`maintainer-doctor` checks each required command resolves. Separately, the
Claude backend now runs with `--output-format stream-json` and writes every
command the agent actually ran to a `.commands` file beside the log. A report is
a claim; the transcript is the record.

## 13. `local a=X b=${!a}` expands before it assigns

The cadence gate opened with

```sh
local var="MIN_HOURS_$task" min="${!var:-0}"
```

`local` is a builtin, so bash expands every one of its arguments before the
builtin assigns any of them. `${!var}` therefore resolved against an unset name
and bash printed `var: invalid indirect expansion`. Without `set -e` the
function fell straight through, and every task ran regardless of its interval.

The test that caught it was the one asserting a two-hour-old task gets skipped.
The two tests either side of it passed, for the wrong reason.

**Guard:** the gate is asserted in three directions, including the negative one,
and the fix is two statements rather than one.

## 14. A leading slash in a `Read` rule points somewhere else entirely

`Read(//home/you/.ssh/**)` looks like a typo for `Read(/home/you/.ssh/**)`. It
is not. Claude Code resolves a single leading slash against the settings file's
own directory; only `//` means the filesystem root, and `~/` means the home
directory.

Measured with a control: `Read(/tmp/x/dbl.txt)` let the file through, while the
`//` and `~/` forms both denied it. Normalising the double slash away, which is
exactly what a tidy-up commit does, would have disabled all seven credential
rules at once and left the count unchanged.

**Guard:** the wall is generated in the `~/` form, a test asserts that form
survives, and the generator refuses to write a wall containing no `Read(~/`
rule at all.

## 15. Prose can claim a cadence that no code enforces

`install-launchd.sh` said the every-N-days cadence was "enforced by the
since-last-run state". Nothing enforced it. `maintainer start` computes what
changed since the last run and puts it in the prompt; it never declines to run.
launchd cannot express a multi-day interval, so on macOS the five-day tracker
audit would have run every single day, and the README repeated the claim.

**Guard:** `MIN_HOURS_<task>` in `profile.env`, enforced in `run.sh` on every
platform, with the skip printed and the override named. Every scheduler now
fires daily and the gate decides, which also removes cron's day-of-month
stepping firing on the 31st and again on the 1st.

## 16. A preview is not free if it opens a file

`--show-prompt` was added so a maintainer can read the exact prompt before
trusting the agent. It skips the identity gate, the lock and the refresh, and it
writes no report. It still opened a log file, because the log path was resolved
before the branch that decides whether this is a real run.

The suite calls it once per task in several places. One test run left **22 empty
logs in the live audit trail**, dated as if runs had happened. An audit trail
that records runs which did not happen is as wrong as one that misses runs which
did.

**Guard:** a preview logs to `/dev/null`, the suite exports its own
`MAINTAINER_STATE_DIR`, and a test runs `--show-prompt` against an empty state
directory and asserts nothing was created. Put the log back and it goes red.

## 17. A graceful fallback can hide the thing it falls back from

The Claude backend runs `--output-format stream-json` through
`scripts/transcript.py`, and falls back to plain text when the filter is
missing, so a parser problem can never cost a run its output. Sound reasoning.

`install.sh` copied `render-settings.py` by name and never copied
`transcript.py`. The deployed agent therefore took the fallback on every run.
Runs kept succeeding, reports kept appearing, and the `.commands` file that
lesson 12 exists to produce was never written once. The only visible symptom was
a file that was not there.

Found by running `backend_run` directly against a two-line prompt rather than by
reading the code, which is lesson 1 in a new costume: the file existed in the
repository, the tests read the repository, and the deployment had neither.

**Guard:** `install.sh` deploys `scripts/*.py` as a glob rather than by name, a
test asserts every shipped script reaches the deployed tree, and the fallback
now writes a line into the log saying the transcript is unavailable. A fallback
that stays quiet is a fallback nobody will notice taking.

## 18. Scaffolding a second profile is the only test of the scaffolding

`new-profile.sh` passed seven tests: it substitutes every placeholder, refuses
when one survives, writes one timer per task, refuses to overwrite, and produces
a profile that assembles a prompt naming its own repository. Then I pointed it
at this repository, and three defects fell out in five minutes.

- **`maintainer status` mixed two profiles.** It read the profile name and the
  `POST` setting from the deployed `profile.env`, and took the repository path,
  the state directory and the task list from module-level defaults. The second
  profile's header sat above the first profile's repository and run history. An
  adopter would have read another project's runs as their own.
- **The scaffolder wrote an absolute home path** into `profile.env`, a file
  meant to be committed. This repository's own leak check went red on the first
  scaffold. For an adopter it would have published their username.
- **The closing instructions named a command that no longer existed**, telling
  the adopter to call `run.sh` by its deployed path after `maintainer run` had
  replaced it. Lesson 12 in the documentation this time rather than in a prompt.

None of the seven passing tests could see any of it, because each one asks
whether the script did what it was written to do. Only using the output as an
adopter asks whether what it was written to do is enough.

**Guard:** every setting resolves from the deployed profile with the environment
taking precedence, paths under `$HOME` are written relative, the prompt
declaration check runs for every profile rather than the first one, and a test
asserts the closing instructions name a command that exists.

## 19. Eight defects the agent found by reviewing its own repository

Issue #8 said pointing the agent at this repository was the only honest test of
the onboarding. One rehearsal run, 487 tool calls, `POST=off` so it published
nothing. Every finding below was reproduced by hand before it was believed.

**The wall enumerated three directories and missed the ones that mattered.**
`/bin`, `/usr/bin`, `/usr/local/bin`. On this machine `cargo` is in
`~/.cargo/bin`, `npm` under `~/.local/lib/nodejs/…/bin`, `maintainer-merge` in
`~/.local/bin`. So `cargo publish` and `npm publish` had no absolute-path rule,
and `maintainer-merge receipt` was protected by exactly one bare-name rule
guarding a binary that lives where the wall does not look. Writing the full path
forged a receipt, which is the one thing the merge gate exists to prevent.
Measured after the fix: the agent reports the command "never ran" and no receipt
file appears. On Apple Silicon the same gap would have made `POST=off` post,
because Homebrew puts `gh` in `/opt/homebrew/bin`.

**The `bare` list had no stated criterion**, so verbs were sorted into it by
guesswork and got one spelling each. `gh repo delete`, `gh repo edit`,
`gh secret` and `gh pr create` were all in it, and the preamble promises the
agent cannot delete anything, change repository settings, or open a pull request
elsewhere. There is one list now.

**A profile name reached `bash -c` unquoted.** `MAINTAINER_PROFILE` set to
`pwn"; touch /tmp/INJECTED; :"`, with a matching directory, ran the `touch`.
`path.exists()` guarded nothing, because whoever sets the variable can create
the directory. Arbitrary shell inside a subprocess, where no deny rule is
evaluated.

**`POST=off` never reached the tools.** `run.sh` set `POST` and did not export
it, and `maintainer-repo prune` pushes branch deletions from inside a script,
which no Bash deny rule can see. A rehearsal on a repository with merged
branches would have deleted them remotely while reporting it reached nobody.

**The eval gate was red for every profile except the first.** The corpus was
already per-profile; the scenario-to-rule map was global, so `magent` inherited
an assertion about sysknife's TWiR label. The hook never saw it because git runs
hooks with the ambient environment and the hook took the default profile. The
map now lives in `profiles/<name>/evals.json`, and a scenario with no entry
fails: retiring one takes an explicit `"n/a"` with a reason.

**A second profile's containment was unguarded.** Deleting a rule from
`profiles/magent/deny.json` left all three gates green, because the suite named
`profiles/sysknife` in seventeen places.

**The helper named one repository in output every profile reads.** The run
header said `sysknife-maint`, the closing line named `sysknife-maint finish`
after that command was renamed away, and a profile with no `SKILL_<task>` was
told to load `sysknife-review`, a skill written for another project's gates.
Inventing a skill name is worse than admitting there is none.

**`finish` threw away the report that found all of this.** The check for the
placeholder sentinel searched the whole file, and the report quoted the sentinel
while writing up a finding about it. A finished 262-line report was rejected as
"no report", the baseline never promoted, and a critical alert fired. Same shape
as §5, in the guard that decides whether a run is auditable. It anchors to line
one now, which is where `start` writes it.

The through-line: **code written when there was one profile generalised its
corpus without generalising its assertions**, and a wall written from an FHS
mental model never asked where the binaries were. Neither is visible to a suite
that passes.

## 20. A published number must be derivable the same way twice

Making the deny wall adapt to the machine fixed a real hole and broke a claim.
The generator resolves each verb with `which`, so the rule total depends on what
is installed where it runs. `check_claims.sh` read **998**, then **1030** on the
same tree an hour later, because installing the maintainer commands added a
directory to spell verbs from. The commit was refused by the gate that holds the
README to the tree, which is the gate working.

The fix is not a looser check. The README now pins the **verb** count, which is
what a person writes into `deny.json`, and prints the rule count as an
observation of this machine. A test separately asserts that every verb is denied
at the directory `which` actually finds it in, which is the property that
matters and does not move.

**Guard:** claim the input, observe the output, and test the invariant that
connects them.

## 21. The second run found what the first one's fixes introduced

Running the agent against its own repository a second time, on the commit that
fixed the first eight findings, produced nine more. Three came from that commit;
the rest had been there longer and nothing had looked.

**A rehearsal could still merge.** `maintainer-repo prune` was taught to honour
`POST=off`, and `maintainer-merge` was not: `gh pr merge --squash
--delete-branch` runs inside the script, where no deny rule sees it. The
reasoning that fixed `prune` was written into the commit message and not applied
to the file next to it.

**`MAINTAINER_FORCE=1` reached the agent's environment**, so every `run.sh` the
agent invoked skipped its cadence gate. A reproduction that should have printed
`skipped` started a real pass against another repository's checkout instead.
Nothing forbade the nesting either: a rehearsal could launch a full run of a
posting profile, and that it stayed a rehearsal was luck, because
`MAINTAINER_POST` happened to be inherited too. Runs now export
`MAINTAINER_IN_RUN` and refuse to start inside another, and the override is
unset the moment it is consumed.

**The suite inherited the run's environment and reported two vacuous passes.**
Invoked from inside a run it gave 236 passed / 6 failed, with the identity-gate
cases never reaching the identity gate. Worse, `a task past its minimum interval
proceeds` and `MAINTAINER_FORCE overrides the gate` both PASSED because force
was on. A suite whose answer depends on who called it is not a measurement; it
clears every `MAINTAINER_*` variable before measuring anything now.

**`check_claims.sh` read the suite's output and not its status**, so a red suite
surfaced as `README says 242 tests, the tree has 236`. It sent a reader to the
README instead of to six failures, and only noticed at all by arithmetic
accident.

**The `"n/a"` hatch could retire the whole eval suite.** Omission was guarded and
declaration was not: marking all seven scenarios not-applicable left the gate
reporting seven passed. Five assert doctrine from `lib/preamble-core.md`, which
every profile receives, so they are not a profile's to retire. Only
`05-reserved-issue` is.

**The context block answered a question nobody asked.** `main <before> -> <after>`
reports what a run's own fetch pulled in, and reads `(already current)` when a
commit was made on this machine rather than fetched. `snapshot()` had always
written `main_sha` and `delta()` never read it, so the field that answers "what
have I not reviewed" was written and unused. A run was told the tree was current
while an entire unreviewed commit sat in front of it, and the prompt told it to
trust that line.

**Three guards had no test at all**: prune's rehearsal check, the profile-name
refusal, and the merge gate's. Each was mutated with all three gates left green.

**The template taught the retired format**, and the receipt guard in
`render-settings.py` was keyed on `which("maintainer-merge")`, which returns
None on a first install: the check meant to keep the merge receipt unforgeable
was inert exactly when the wall is first written.

I also destroyed this work once with `git checkout .` and had to redo it, which
is the trap the mutation-harness entry in this file already describes. Commit
before running an experiment that touches the tree, including the experiments
that verify the commit.


## 22. shellcheck found a condition the merge gate had been ignoring for weeks

Adding CI meant running shellcheck for the first time, which produced nine
warnings. Seven were dead variables and fragile loops. One was not.

    bin/maintainer-merge:162
    state="$(gh pr view "$pr" --json mergeStateStatus --jq .mergeStateStatus)"
    ^---^ SC2034: state appears unused

The gate made the API call, took the answer, and never read it. So a pull
request that was **BEHIND** its base merged happily: its checks were green
against a tree that is not the one being merged, which is precisely the failure
this gate exists to prevent. `DIRTY` and `BLOCKED` passed too.

An unused variable is usually tidy-up. This one was a missing condition, and a
linter found it because a linter reads what the author meant to use rather than
what the author remembers writing.

**Guard:** only `CLEAN` and `HAS_HOOKS` may merge, with five tests driving the
gate through each status. Deleting the check turns four of them red.


## 23. The first CI run found three tests that were measuring my laptop

Adding GitHub Actions was meant to give contributors the same gates. Its first
run went red on three cases that had been green here for a day:

    FAIL  status does not report task
    FAIL  status does not report review
    FAIL  status does not show when the next run is

`maintainer status` was correct on the runner. It said there was no deployment
and no scheduler, because there was neither. The tests asserted against whatever
profile happened to be installed in my home directory and whatever timers
happened to be registered, so they measured the machine rather than the code.
Locally they could not fail; anywhere else they could not pass.

**Guard:** those cases now build a profile, a state directory, a report and a
stubbed `systemctl` inside the suite's scratch directory, and the whole suite is
expected to pass under

    env -i HOME="$(mktemp -d)" PATH=/usr/bin:/bin bash ./tests/run-tests.sh

which it does. CI is the only place that check was ever going to come from,
which is an argument for CI that has nothing to do with contributors.

## 24. The claim check read a number out of a commit SHA

`scripts/check_claims.sh` held the README's figures to the tree by grepping for
`[0-9]+ (offline )?tests` and taking **the first match**. A new example in the
README read

    maintainer-merge verify 365 7c6ed388 tests/e2e/story-metadata.test.sh

and the checker found `388 tests` inside the commit SHA, then refused the commit
because the tree has 313. The number it complained about had never been written
by anyone.

Two defects in one line, and the second is worse. Taking the first match means a
**second, stale copy of a figure further down the file is never checked at all**:
the check would have passed happily with the correct number at the top and a
wrong one below it.

**Guard:** the number may not be the tail of a longer token, every occurrence is
collected rather than the first, and figures that disagree with each other fail
before either is compared to the tree. Adding a second, conflicting mention
turns it red naming both.

This is the third time a check in this repository has passed or failed for a
reason unrelated to what it was checking. The other two are in §5.


## 25. The receipt-invalidation check named one project's directories

`maintainer-merge` decided whether production code had moved under a receipt by
diffing against a fixed list: `crates/*/src/*`, `apps/*/src/*`, `packaging/*`,
`.github/*`, `*/Cargo.toml`, `Cargo.lock`. Those are sysknife's directories.

On **any other repository they match almost nothing**. Measured on this one: of
the files in the last three commits, exactly one was on the list. A pull request
could earn a receipt at one head, push a rewritten `bin/maintainer-merge` at the
next, and the gate would report

    head moved …, no production diff; receipt still applies

That is a merge against a receipt describing a tree that is gone, which is the
single failure the receipt exists to prevent. Same shape as the Rust-only
`verify` in §22: a central guarantee that silently only worked for the project
it was written against.

`maintainer-repo release-check` had the same list and therefore reported "docs
and tests only" for a release containing fourteen changed production files.

**Guard:** `PROD_GLOBS` comes from the profile, there is no default, and a
profile that declares none is refused a merge. Guessing which paths are
production is how the original bug worked. Two tests drive a real repository:
a docs-only move keeps the receipt, a rewrite of `bin/` kills it.

Restoring the hardcoded list turns both red. It also turned twelve older tests
red, because they had never declared production paths and the gate now refuses
without them, which is the fail-closed behaviour finding under-specified tests.

## 26. A guard that refuses the repository's own layout

The gate refused every symlink in the extracted tree, on the grounds that
`sed -i` follows one off the host. Run against a real pull request it refused
`docs/images/social-preview.png -> ../../assets/social-preview.png`: a link that
had been on `main` for months, that the pull request did not touch, and that
resolves two directories away from where it sits. The message blamed the
contributor for the repository's layout.

The exploit is real and was reproduced end to end, but the property that matters
is whether the link leaves the tree, and the mutation step had already been
narrowed to `find -type f`, which never matches a symlink at all. Now the scan
reports only links whose target resolves outside the extracted root, and the two
tests that covered it were `grep -q 'ships symlink' bin/maintainer-merge`, which
passes for any file containing that phrase. They drive the function.

**Measure the property, not the shape.** A guard written against the shape of an
attack refuses the shape wherever it appears, including in the tree it is
supposed to protect.

## 27. The container runtime wrote the evidence

podman prints `time="..." level=warning msg="Error validating CNI config file
..."` on every run on this machine, onto the same stderr the container uses. That
one line did two things to the receipt for a live pull request. It was the first
line matching the failure grep, so `observed_failure` recorded a CNI warning
where the proof belongs. And it is bytes, so the shell suite's `suite_ran` check,
whose whole job is to refuse a receipt for a run that executed nothing, counted
it as evidence that something ran.

A missing optional function did the same thing louder: `suite_podman_args:
command not found`, ten times, inflating `units_run` from 2 to 10.

**A log read as evidence must contain only the thing being measured.** The
runtime now runs at `--log-level=error`, the extractor drops logfmt lines, and
when nothing matches the failure pattern it falls back to the last line printed
rather than recording an empty string.

## 28. The warning that had never once printed

`release-check` reads the CHANGELOG's Unreleased section and warns when it is
empty, because the verdict then rests on file counts alone. The extraction was
`sed -n '/^## \[Unreleased\]/,/^## \[[0-9]/p'`, and sed prints both delimiters.
An empty section therefore came back as two heading lines, `[ -z "$unrel" ]` was
false, and the warning had never printed in the life of the tool.

It was found by using it: cutting this project's own 0.2.0, the check reported
`removed-capability wording: 0 occurrence(s)` and `digit: last` for a release
whose Removed section has six entries, and said nothing about having read an
empty section. The two tests covering this were greps for a phrase in the source
of `bin/maintainer-repo`, so both passed throughout.

**A guard whose input is never empty in the author's tests is a guard that has
never run.** Build the empty case as a fixture, not as an assertion about the
source.

## 29. Run your own suite somewhere that is not your laptop

The offline suite was green here and had been for weeks. Run inside
`python:3.12` it reported eight failures, and only one of them was about the
container:

- Five said `jq: command not found`. The merge gate shelled out to `jq` in three
  places and nothing else in the project needs it. The refusal that followed
  read `#7 has  failing check(s)`, with a blank where the number goes: it failed
  closed and named the wrong thing. The counts are `python3` now, which the gate
  already requires everywhere.
- Two came from one bug in `bin/maintainer`. `_next_runs` called `systemctl` by
  name with no guard, so `maintainer status` printed three lines and died with
  an uncaught `FileNotFoundError` on any host without systemd. This project
  documents four schedulers and three of them are not systemd.
- One was real: the shell verify suite needs a container runtime, and there is
  none inside a container.

That last one had been written as a failure, so the suite could never be green
on a machine without podman. Writing it as a pass would be worse: entry 24 in
this file is a missing optional dependency that turned a gate green over seven
real errors. It is a third count now, `SKIP`, printed in the summary, and CI
fails when it is not zero.

Two cases also made the suite's own size machine-dependent, which matters
because `check_claims.sh` compares that number to the README. One reported a
PASS for a PowerShell parse it had skipped, and one emitted a single failure
line where the branch it replaced ran two cases. Host and container now agree
on 396.

**A suite that has only ever run in one place is measuring that place.**

## 30. The health check read the other project's health

`maintainer-doctor` asked systemd for `maintainer@*` and counted what came back.
Run as `MAINTAINER_PROFILE=magent` it counted sysknife's four timers and printed
`4 systemd timer(s) registered, ok`, while magent's two timer files sat disabled
and had never fired once.

This is the third time this shape has appeared here. `bin/maintainer` defaulted
`MAINTAINER_PROFILE` to a hardcoded `"sysknife"`, so a second profile printed its
own header above the first profile's run history. The merge gate's `PROD_GLOBS`
were one project's directories, so on any other repository the production-diff
rule compared nothing. Now the doctor.

`systemctl list-timers` shows loaded units, so a disabled timer is *absent* from
it rather than listed as off. That is why the wrong glob read as healthy rather
than as a contradiction: the four that answered were real, they were simply
somebody else's. Counting the unit *files* separately is what distinguishes "no
timer installed" from "installed and never enabled", and those need different
fixes from the reader.

**Anything that takes a profile must ask for that profile by name, every time.**
A per-profile tool with a wildcard query is a tool that reports on whoever
answers first.

## 31. Three checks in one day matched their own documentation

Each of these was a text search over a file that also *describes* what it
searches for.

- `grep -q 'secrets\.' ci.yml` enforces "CI reads no repository secret". Writing
  the words `secrets.GITHUB_TOKEN` in the comment that explains the policy made
  the check fail.
- `grep -nE '\bjq\b' bin/maintainer-merge` enforces "the gate needs no jq". The
  paragraph explaining why jq was removed matched it.
- `grep -q 'skipped' suite.log` enforces "CI must run every case". The name of
  the test that proves skips are counted, `and the summary line names the
  skipped count`, matched it, so a run with zero skips failed CI for containing
  the word.

All three passed their own tests, because their tests fed them the failing
input and never the *documented* input.

**A grep-based check has to say what part of the file is in scope.** Strip
comments, anchor on a line shape, or read a structured field. A bare search over
a file that talks about itself will eventually match the sentence explaining it.

## 32. The number was true and useless

A full review of a Rust workspace was recorded as `[tokens in=48 out=17365]`.
Forty-eight input tokens for a run that read a repository.

`input_tokens` is real, and in an agent run it is nearly nothing. The volume
lives in two other fields: `cache_creation_input_tokens`, charged above input,
and `cache_read_input_tokens`, charged below it. The same run's real shape was
`in=108 cache_write=412k cache_read=9.85M`. Logging one of the three and calling
it "in" was worse than logging nothing, because a reader treats it as a
measurement.

Three more things the usage record gets wrong if taken naively, all of them
documented and none of them guessable:

- `usage` **excludes subagent tokens**. `total_cost_usd` and `modelUsage`
  include them, so the per-model map is the honest total the moment anything
  nests.
- `total_cost_usd` is a **client-side estimate** from a price table bundled with
  the CLI, not billing truth. Every surface that prints it has to say so.
- A **failed** run carries usage too, and a crashed one may carry it zeroed. A
  run that spent four dollars and then died must not be filed as having spent
  nothing.

And the tempting shortcut is wrong twice over. `tiktoken` is OpenAI's tokenizer;
it undercounts Claude by 15-20% on prose and by 1.57x to 2.08x on code, and
Anthropic publishes none. But counting is the wrong move regardless: the exact
billed figures are already in the stream, and re-deriving them from the text
would replace a fact with an estimate.

**Before summing a field, find out what the other fields are.** A partial
measurement wearing a total's name outlives the person who wrote it.

## 33. Speaking only to complain

The agent had one voice: `notify-send` on failure, carrying the raw shell error.
What reached the desktop was a message written in the vocabulary of the thing
that broke, two thirds of it an absolute path, with no next step. A successful
run said nothing at all, so every popup this project ever produced was bad news.

Both halves were the same mistake. The notification was built from what was
convenient to pass along rather than from what a person needs at the moment they
glance at a corner of the screen: what ran, whether it worked, what to do,
and what it cost.

The failure path now translates the errors it recognises into a sentence and a
fix, and passes anything else through unchanged, because a wrong translation is
worse than an untranslated string. The success path sends a three-line digest
built only from things the run measured: its own report length, its own command
record, and the usage the model reported. An earlier sketch parsed the report's
prose for "3 PRs reviewed", which is the agent's claim about itself with a
summary's authority.

**A notification is a user interface.** It gets the same scrutiny as any other,
and the first question is what the reader does next.

## 34. Two real findings, two wrong consequences

Two sonnet subagents reviewed this project's work on the same afternoon. Both
found something real. Both attached it to a conclusion that was wrong, and both
conclusions were the part that would have been published.

The first reported a false pass in a release gate: strip the `version` field
from an internal path dependency and the check reports "14 internal dependency
pins checked" instead of 15, exit 0, no complaint. Reproduced exactly. Its
stated consequence was that this is "the bug the check's own comment says it
exists to catch", which would publish a crate depending on the wrong version.
Running `cargo publish --dry-run` settles it:

    error: all dependencies must have a version requirement specified when
    publishing. dependency `sysknife-core` does not specify a version

Cargo refuses. The finding survives, the severity does not, and the real defect
is a different one: the gate cannot tell "15 pins, all correct" from "14 pins,
all correct, and one that vanished from view".

The second reported a merge with no entry anywhere in the audit trail, and asked
whether an unlogged agent instance had done it. `lib/run.sh` opens its log file
before it does anything else, so a run that existed left a log even if it died
in the first second. There is no log within forty-five minutes of that merge.
The supporting evidence it cited, "hard config failures at 15:57 and 15:58",
turned out to be from the following day.

Neither agent was careless. Both were thorough enough to produce evidence I
could check, which is what made checking cheap. The failure mode is narrower
than "subagents are unreliable": the *finding* is where the work went, and the
*consequence* is written last, quickly, in the confident register of a summary.

**Verify the consequence separately from the finding, and with a different
command.** The write-up arrives in your own voice and reads like something you
already did.

## 35. The index was the one document that stayed quiet

Nine runs, audited against the repository they acted on. Six of the reports were
accurate on every checkable fact, and the two that also had a command record
were accurate at command level. Nothing was fabricated anywhere.

The problem was the runs with no report at all.

`logs/2026-09-03T07-52-review.log` is twenty-two lines: the task briefing, then
nothing. No report was written. In the hour after that log was opened, fifteen
comments went out under the account the agent uses. The trail cannot say whether
the agent posted them or a human did, because the account is shared and the
transcript was empty. Reading `index.md`, that run does not exist.

That is the shape. `logs/` knew, `runs/` knew, GitHub knew, and the one document
a reader actually consults said nothing, because absence was represented by
absence. A gap in an append-only index is indistinguishable from a quiet week.

Two smaller versions of the same thing sat beside it. A report reading
`baseline promotion test` was indexed like a genuine run, because the sentinel
check that exists for exactly this only covered the placeholder the tooling
writes, not one a developer types. And seven runs had no `.commands` file, so
"the transcript recorded nothing" read identically to "no transcript was ever
kept".

One property saved the audit, and it was undocumented: `lib/run.sh` opens its
log before it does anything else, so a run that existed left a log even if it
died in its first second. That is what established a merge with no index entry
had not come from any run, because the nearest log that day was forty-five
minutes away. A load-bearing invariant nobody had written down.

**An audit trail has to record absence explicitly.** Silence is not a value, and
every reader will fill it in with the most comfortable story.

## 36. The agent turned off its own scheduler, and the other project's

Six hours after the self-maintenance timers went on, the `magent` profile
reviewed this repository at `POST=off` and ran `./install.sh --uninstall`
against the real `HOME`. It was root-causing a genuinely failing uninstall test,
its analysis was correct, and it reported what it did honestly.

It also disabled all six timers, including the four that maintain a different
project entirely, and then died under `set -e` at the cron removal step before
removing a single file. Scheduler off, files present, nothing said. Three and a
half hours passed before anyone noticed, and only because someone asked an
unrelated question about the next scheduled run.

Three separate things had to be true at once.

**The rehearsal wall is about GitHub.** `POST=off` blocks every posting verb and
has nothing to say about `systemctl`, `install.sh`, or anything else on the
machine. It reads like a general safety mode and is a specific one.

**`--uninstall` was destructive with no confirmation.** A verb that stops every
profile on the host, available to anything that can run a shell, guarded by
nothing.

**It could not finish, and left the worst state.** `command -v crontab && [ -x
... ] && run ...` is an `&&` list, so a `crontab` that exists but cannot write
killed the script under `set -e` *after* the timers were off and *before* any
file was removed. Either finished state would have been survivable. The middle
one was silent.

`docs/plan.md` had named the risk in the abstract when those timers were
enabled: an agent that reviews its own repository can change the rules it is
reviewed under. Naming a risk is not mitigating it, and the concrete form was
not the one the sentence had in mind.

What worked, and is why this is a story about hours: the run left a `.commands`
record and a usage file, so its own actions were readable in minutes. The
transcript work from the same morning paid for itself the first time it was
needed.

**A destructive verb needs a guard that does not depend on who is calling it.**
An agent that can run a shell can run anything the shell can, and the deny list
enumerates what someone thought of.

## 37. The label was a promise nothing kept

A contributor commented "I am taking this" on sysknife#355. The maintainer
replied "it is yours", applied the `claimed` label, and said in the same comment
that the label "is what the other contributors read". Ten hours later a
different contributor opened a pull request closing that issue. The review
approved it, the merge gate merged it, and the person who claimed it had
nothing to show for a day's work.

Every part of that system worked as built. The label was applied. The reply was
warm and specific. The review checked the diff, traced it to a live path, and
mutation-proved both guards. The gate checked the review state, the board, the
merge state, the head, and the production diff. Not one of them knew the issue
had been promised to somebody.

The failure is a category error about what a label is for. `claimed` was
treated as documentation, a note for humans to read. It was actually a
commitment, and the sentence that made it one was published in the same breath:
other contributors read that label and stayed off the issue. A promise that only
some of your tooling can see is a promise you will break by accident.

It is in the merge gate now, beside the receipt and the production diff, because
that is the last place before the irreversible act and the only one that cannot
be talked past. A pull request closing an issue that carries the claim label,
whose author has never posted on it, is refused with both names in the message.

**Anything a project publishes as a commitment has to be enforced where the
commitment can be broken.** Not where it is convenient to check, and not by
asking a reviewer to remember.

## 38. The check said no and the operation said yes

Five contributors held `claimed` issues with no GitHub assignee. Before
assigning them I asked GitHub whether I could:

```
$ gh api repos/lacs-project/sysknife/assignees/Osheun
(404)
```

Five for five, the same answer. The conclusion was sitting there and it was
wrong: that GitHub structurally forbids assigning outside contributors, that the
label is the only mechanism available, and that the whole request was
impossible. I was one sentence from reporting it.

Then I tried the operation instead of the question:

```
$ gh api -X POST repos/lacs-project/sysknife/issues/336/assignees \
    -f 'assignees[]=Osheun'
{"assignees":["Osheun"]}
```

It works for anyone who has commented on the issue. `/assignees/{user}` answers
"is this a collaborator", which is a different question from "can this person be
assigned here", and the endpoint name does not say so.

Two more things fell out of doing it.

`maintainer claims` first measured staleness from the issue's `updatedAt`, so
assigning five claims reset all five to `0d, active` — including one eleven days
old. **The act of recording the claim blinded the check that watches it.** Idle
now comes from the claimant's own last comment, because anything the maintainer
touches moves `updatedAt`.

And `cmd_claims` shipped reporting "this profile declares no CLAIM_LABEL"
against a profile declaring it on line 74: `_profile_env` sources the file and
reads back a literal tuple of key names, and the new key was not in it. A key
the code reads and the tuple omits comes back empty, which is indistinguishable
from unset. There is a test now that cross-checks every key read against the
tuple.

**A capability check is a claim about the world; the operation is the world.**
When they are cheap and reversible, run the operation.

## 39. A release and an offer are the same sentence

`maintainer offers` shipped, and an hour later I used it on the tracker it was
built for. It reported `atanishka308  no: working on #272` about an issue I had
released from them twenty minutes earlier, and it held two released issues out
of the free pool.

The tool counted an offer as "a comment by the maintainer mentioning this
person on an open issue". A release is also a comment by the maintainer
mentioning that person on that open issue. Structurally they are identical:
same author, same mention, same thread, and in both cases the contributor has
not replied. No amount of care in the prose separates them, because the
difference is intent and intent is not a field.

So the release carries a marker, `<!-- maintainer: claim-released -->`,
invisible in the rendered comment and unambiguous to anything reading the
thread. The last maintainer comment mentioning a person decides their state on
that issue.

Two things this is really about.

**The tool was found wrong by being used, not by being tested.** Its own suite
was green and its cases were reasonable; none of them had a release in it,
because I had not yet made one when I wrote them.

**And the fix is a convention, not a heuristic.** The tempting version was to
match on the wording of a release, which works until somebody phrases one
differently, and fails silently when they do. A marker the writer must add is
worse ergonomics and cannot be wrong.

## 40. The test measured the laptop that wrote it

`v0.4.0` was tagged, pushed, and the release workflow failed on four cases the
local suite had reported green minutes earlier:

```
FAIL  magent has no cursor wall
FAIL  sysknife has no cursor wall
```

The test read `$HOME/.local/share/maintainer/profiles/<p>/cursor/cli-config.json`
— the **deployed** tree. That file exists on the machine that ran `./install.sh`
and on no CI runner. The suite was not measuring the repository; it was
measuring this laptop, and the repository happened to be nearby.

The deny-wall cases fifty lines above it get this right: they render into a
scratch directory with a fake home, because a wall read out of a deployment is a
wall somebody already installed. The new test read the artifact instead of
building it, which is the shorter path and the wrong one.

Two things worth keeping from it.

**The check is one line.** `HOME="$(mktemp -d)" ./tests/run-tests.sh` reproduces
a fresh machine exactly, catches the entire class, and takes seconds. It is a CI
step now, run before the ordinary one, so the failure names the cause rather
than appearing as an unrelated test going red.

**And the tag went out first.** The release workflow runs the gates on the tag,
which is the right design and it ran too late to stop me: I had already
announced the release. A gate that runs after the irreversible-looking step
protects the artifact and not the person. Nothing was published, because the
publish job is gated on those gates, and that is the part of the design that
worked.

## 41. Five warnings, one habit, nothing invented

`maintainer audit` on the first unattended run after it shipped:

```
! 2026-09-04T21-17-review    5 of 12 quoted command(s) are not in the record
      claimed, never run:  sed -n '322,324p' .github/workflows/ci.yml
      claimed, never run:  gh issue view 248 ... | grep -c 'claim-released'
```

Five of twelve is the flag rate of a broken checker, so the checker was the
first suspect. It was right. The transcript held `sed -n '318,345p'` and a
`for n in 248 272; do ... done`: the run had read a wider range and narrowed it
for the reader, and unrolled a loop into its two cases. Every fact in the report
came from output the run really saw. It ran a superset of what it quoted.

Nothing was fabricated, and the habit still costs something. A checker whose
warnings are almost always tidying is a checker people stop reading, and the one
real fabrication it would ever catch arrives in that same pile. The value of an
audit is its signal-to-noise, and the noise here was generated by the thing
being audited, for the reader's benefit.

The fix is in the doctrine rather than in the extractor. Loosening the matcher
to accept a narrowed range would also accept a narrowed range that was never
run, which is the case the tool exists for. So the rule is on the writer: quote
the command that ran, character for character, then explain which part of the
output matters.

**Prefer the strict checker and the stricter habit.** A tool taught to accept
approximations cannot tell you when one is wrong.

## 42. The doctrine pointed at a line nobody wrote

`preamble-core.md` has said this since the audit trail existed:

> Open the report with the version named in the first line of this prompt, so a
> reader six weeks from now knows which build wrote it.

No version was ever in the prompt. `run.sh` read `VERSION`, exported
`MAINTAINER_VERSION`, wrote it into the log, and assembled the prompt out of the
profile preamble, the doctrine, the prose rules and the task. The stamp reached
the logfile and never reached the model.

An instruction pointing at absent data does not fail; it gets satisfied from
somewhere else. The run at `2026-09-04T21-17-review` opened its report with

    `maintainer v0.3.0` (commit `10a7e79`).

while running v0.4.0 at `111592c`. The skill tells a run to read the last few
reports before starting, so the only version in reach was the previous run's,
and it carried it forward. Three consecutive reports now name a build that did
not write them.

A wrong stamp is worse than a missing one. A missing stamp makes you go and
look; a wrong stamp sends an audit to code that never ran, and it looks like
provenance while it does it.

The prompt now opens with a provenance line and one sentence naming where the
version must **not** come from, because the failure was not ignorance of the
rule. The run followed the rule. It filled the gap the rule left.

**Whenever doctrine says "the X named in Y", grep Y for X.** The assembled
prompt is the only Y that counts, and `--show-prompt` prints it.

## 43. The check that lied and the check that repeated it

`gh issue edit --add-assignee atanishka308` on #272:

```
failed to update https://github.com/lacs-project/sysknife/issues/272: 'atanishka308' not found
```

The account exists, has 236217646 for an id, and had commented on that issue
eleven minutes earlier. `gh issue edit` resolves a login through GraphQL against
the repository's assignable users first, and an outside contributor is not one.
The REST call assigned them on the next line:

```
$ gh api -X POST repos/lacs-project/sysknife/issues/272/assignees -f 'assignees[]=atanishka308'
["atanishka308"]
```

Lesson 33 recorded the same shape for `GET /assignees/{user}`, which 404s for
every outside contributor while the POST succeeds, and the doctrine carried the
working call from that day on. The sysknife task prompt kept prescribing
`gh issue edit --add-assignee` anyway. Two files disagreed, and the task prompt
is assembled last, so the losing instruction was the one closest to the work.

Worse than the failure: the label went on and the assignment did not, and the
comment posted alongside them said both had. A partial write with a confident
sentence over it is how a promise gets broken in public.

**Fixing the doctrine is half the fix.** Grep every prompt for the verb you just
retired, and order the calls so the reversible one goes second.

## 44. Thirteen runs that left no trace, and the audit walked past all of them

`maintainer audit --all` iterated `runs/*.md`. A run that dies before writing a
report leaves a log and no report, so the audit could not see it: the command
whose entire job is to say what happened enumerated only the runs that had
already said what happened.

The real trail held thirteen. Most were development invocations, and one was
not. On 2026-09-04 at 08:14 the alert fired:

```
ALERT sysknife-review: the run unit failed before it could report; systemd killed or refused it
```

Nothing downstream of that alert ever mentioned it again. `index.md` showed a
review at 08-04 and the next at 12-56, which is a normal-looking cadence.

This is lessons 22's shape at a different scale. Absence is not self-reporting.
A gap in an audit trail reads as a quiet period, and a quiet period is exactly
what a suppressed failure looks like.

`audit --all` now walks `logs/` as well and names every log with no report.
Auditing one run by name still audits that one run, because a sweep's findings
leaking into a single-run check is how a tool becomes noise.

## 45. The most important refusal had a test that never reached it

`tests/run-tests.sh` opened this block with a comment naming the stakes:

> The gate is the single most important refusal: a write under the wrong
> account stamps an employer-linked identity onto personal open-source work.

It then ran `lib/run.sh` under a stubbed `gh` and asserted `rc=1`. The gate sits
behind `backend_check`, and `profiles/*/settings.json` is generated at install
time rather than committed, so every invocation died here instead:

```
$ PATH="$sd:$PATH" HOME="$sd" bash lib/run.sh sysknife review
backend claude unusable: missing .../profiles/sysknife/settings.json
$ echo $?
1
```

`backend_check` returns 1. The identity gate returns 1. Both cases asserted 1,
so the test was green on an exit code produced eleven steps before the code it
was written to guard.

The tell had been sitting in the assertion the whole time:

```sh
printf '%s' "$out" | grep -q 'refusing to run' && printf '        (refusal message present)\n'
```

A conditional print, with no `else`. It printed nothing for the life of the
test, and nothing is what a passing test looks like.

Two rules come out of this, and the second is the one that generalises.

**Assert the message, not only the code.** An exit code is a number that any
layer can produce. The gate's own sentence can only come from the gate.

**A guard behind a precondition needs that precondition satisfied in the
test.** The wall is a build artifact, so the test has to render one. Anything
the installer creates is absent in a fresh checkout, which is the environment
CI and every new contributor start from.

## 46. One sentence for two emergencies

Both timers died on 2026-09-05, twelve hours apart in the schedule and five
minutes apart in reality:

```
09:15:28  sysknife-review   error connecting to api.github.com
09:20:28  magent-review     error connecting to api.github.com
```

What reached the desktop was neither of those lines:

```
ALERT: gh is authenticated as 'unknown', not vladimirrott; refusing to run
```

`gh api user --jq .login` returned nothing, `${gh_login:-unknown}` filled the
hole, and the sentence that came out described a revoked token. During a network
outage that sends you to the credential store, which is the one place the
problem was not.

The gate was right to refuse. It described the refusal wrongly, and an alert
nobody can act on correctly is most of an alert wasted.

The two cases also want different responses. An outage is transient, so the gate
retries it and exits 75, `EX_TEMPFAIL`, which reads as "ask again" in the
journal rather than as a refusal. A wrong account is not transient, so it is
refused on the first answer and never retried into: retrying that is waiting for
a different identity to appear, which is the thing this gate exists to prevent.

**An empty answer is not a wrong answer.** Where a default fills in for a value
you failed to read, check first whether you read anything at all.

The cost was one review cycle. PR #370 arrived at 08:30 and the 09:15 pass that
would have reviewed it never started, so a contributor waited for a maintainer
who had already been scheduled to show up.

## 47. Two clocks, one run, and an audit that saw two failures

`maintainer audit --all`, an hour after the orphan check shipped:

```
  2026-09-05T10-56-review    the report quotes no executed command
! 2026-09-05T10-47-review    started and never reported: Recount matches the published prose...
```

One run. `run.sh` names its log from `date +%Y-%m-%dT%H-%M` at line 130, before
it takes the lock. `maintainer start` mints the run id after the lock is
acquired, at line 345. That review waited nine minutes behind an issues sweep,
so the two clocks disagreed by nine minutes and the run's transcript and its
report ended up under different names.

Both audit findings were false, and they failed in opposite directions. The
report looked unverifiable because its `.commands` file was empty. The log
looked like a dead run because no report carried its name. Neither was true, and
a reader would have chased both.

What makes this worth writing down is that nothing was wrong until something was
slow. Every run for weeks took the lock immediately, both names agreed, and the
mismatch was invisible. Contention is what made the two clocks readable, and
contention is rare, which is exactly why the bug survived.

**A name minted before a wait is a different name from one minted after it.**
The log is renamed to the run id as soon as that id exists, keeping what the
pre-lock log recorded, including the wait.

And the tool found it. `maintainer audit --all` gained the orphan check at
10:28 and reported this at 11:00, against its own sibling.
