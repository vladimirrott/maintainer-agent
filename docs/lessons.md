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
