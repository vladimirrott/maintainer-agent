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
