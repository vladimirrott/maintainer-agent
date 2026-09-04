# Contributing

Thanks for looking. This is a small, opinionated tool: an agent that maintains a
repository unattended, whose value is the set of things it refuses to do. That
shapes what a useful contribution looks like here.

## Where to start

- **Issues labelled `untested`** are guards that ship without a test that could
  fail. Each one is a self-contained job with a clear finish line, and writing
  the mutation teaches you the codebase faster than reading it.
- **`docs/lessons.md`** is forty defects that reached a working system,
  each with the measurement that found it. It is the fastest way to understand
  why anything here is shaped the way it is, and several entries end in work
  that is still open.
- **Run it against your own repository.** `./new-profile.sh`, `POST=off`, read
  the report. Everything it gets wrong on a project that is not this one is
  worth an issue, and that is the feedback this project has least of.

Small, precise changes are easier to review than large ones, and a change that
narrows what the agent may do is easier to accept than one that widens it.

## What happens to your pull request

CI runs the same gates you can run locally, on every push including from a fork.
A maintainer reads the diff, checks the numbers in it against the tree, and
mutation-proves any guard it adds. Expect the review to name one blocking item
and separate it from the optional ones. If a later pass finds something an
earlier one should have, you will be told plainly rather than quietly.

Anything you contribute is under the MIT licence in `LICENSE`, same as the rest.

## The gates

The gates run in three places, and they are the same gates: a pre-commit hook
before a commit exists, GitHub Actions on every push and pull request, and your
own shell whenever you want. Nothing is gated only on a maintainer's laptop.

## Setup

```sh
git config core.hooksPath .githooks   # once
./install.sh --dry-run                # see what a deploy would touch
./install.sh                          # deploy; --uninstall takes it back out
```

Required: `bash`, `python3`, `git`, `gh`. For a real run you also need one
backend on `PATH` (`claude`, `opencode`, `codex` or `cursor-agent`) and `podman`
for container verification and for the PowerShell parse check.

Read the prompt before you trust the agent:

```sh
./lib/run.sh --show-prompt sysknife review | less   # from a checkout
maintainer run --show-prompt review                 # once installed
```

That is the same assembly a real run uses, not a reconstruction of it. It
touches no state and marks its context block as a preview.

## Before every commit

The hook runs all four. Run them yourself first; they take seconds.

```sh
bash -n <every script>        # the hook does this over `git ls-files`
./tests/run-tests.sh          # offline, no network, no model call
./evals/run-evals.sh          # the governing rules still exist
./scripts/check_claims.sh     # README numbers recounted from the tree
```

If `check_claims.sh` fails because you added a test, the fix is to update the
number in `README.md`, not to relax the check.

**The suite must pass with nothing installed.** This is the property CI tests
and the one that is easy to lose:

```sh
env -i HOME="$(mktemp -d)" PATH=/usr/bin:/bin TERM=dumb bash ./tests/run-tests.sh
```

Three `status` cases once passed locally and failed the first time CI ran them,
because they asserted against whatever profile happened to be deployed on the
author's machine and whatever timers happened to be registered. A test that
reads your deployment is measuring you.

## What a change here has to prove

This project's whole value is refusals, so a change that touches one must show
the refusal still fires **and** that the check could fail.

1. Add the assertion.
2. Break the thing it guards. Watch it go red, and read the message: it must
   name the file or rule that broke.
3. Restore. Watch it go green.

Put the mutation and its output in the commit message. Three checks in this
suite were written wrong first and passed for the wrong reason:

- a single `grep` alternation over several credential paths, which let a lost
  rule hide behind one that still matched;
- a search for a string that appeared in the searching file itself, which
  reported a leak that was only its own source line;
- a `--force` check that read the comments explaining why `--force` is absent.

A green suite is not evidence. A suite you have watched fail is.

## Layout

```
new-profile.sh          scaffold a profile for another repository
install.sh              deploy, enable timers, uninstall
bin/maintainer          status, refresh, diff, screen, report (the bookkeeping)
bin/maintainer-merge    the merge gate; the only path to a merge
bin/maintainer-repo     prune merged branches; say whether a release is owed
bin/maintainer-doctor   check the install by running it
lib/run.sh              orchestrator, platform-independent
lib/preamble-core.md    the doctrine, shared by every profile, injected first
lib/prose-style.md      injected into every prompt unless PROSE_STYLE=raw
lib/backends/*.sh       claude | opencode | codex | cursor
scripts/render-settings.py  generates the deny walls from a profile's deny.json
scripts/transcript.py   turns stream-json into a log and a list of commands run
profiles/_template/     what new-profile.sh copies
profiles/<name>/        everything site-specific: paths, account, prompts, deny.json
platform/{linux,macos,windows,posix}/   scheduling only
evals/scenarios/*.md    adversarial situations with a required behaviour
docs/maintainer-doctrine.md       why the refusals are the ones they are
```

The core is bash on every platform. Only scheduling forks. Two implementations
of a security gate drift, and the gate is the product; a test asserts there is
exactly one executable implementation of the merge gate.

## Adding a profile

```sh
./new-profile.sh widget acme/widget ~/src/widget acmebot "Ada Lovelace"
```

No code change should be needed. If one is, that is a bug, and it was one until
recently: `bin/maintainer` held a skill map keyed to one repository's names, and
four unit files had to be written by hand.

Three rules for anything added here:

- **Nothing under `bin/` or `lib/` may name a repository.** The task list, the
  skill each task loads, the cadences, the deny wall and the state directory all
  come from `profile.env`. A test asserts the task list is read from the
  environment rather than hardcoded.
- **A new profile starts at `POST=off`.** It does the whole pass and reaches
  nobody. Anything that would let a first run post is a defect.
- **Doctrine goes in `lib/preamble-core.md`, not in a profile.** One copy, so it
  cannot drift between repositories. A run assembled without it refuses to start.

## Changing the deny wall

Edit `profiles/<name>/deny.json` and add the verb **once**.
`scripts/render-settings.py` spells it from every directory it could be run
from: the static ones, the usual user-local ones in `~/`, `$HOME/` and expanded
form, and wherever `which` finds the binary on the machine generating the wall.
That last part is not decoration. The wall listed three FHS directories until a
run found that `cargo` lives in `~/.cargo/bin`, `npm` under
`~/.local/lib/nodejs/…/bin` and `maintainer-merge` in `~/.local/bin`, so the two
publishing verbs had no absolute-path rule and the receipt was forgeable by
writing the full path.

Three things in the generated output look like mistakes and are not:

- `Read(~/…)` is the only form that denies. A single leading slash anchors to
  the settings file's own directory, so `Read(/home/you/.ssh/**)` protects
  nothing. Measured with a control.
- The same credential path is denied to `cat` three different ways, because the
  matcher keys on the command as written.
- The rule count differs between machines, which is why the README pins the
  **verb** count and prints the rule count as an observation.

## Adding a backend

Implement `backend_name`, `backend_check` and `backend_run` in
`lib/backends/<name>.sh`. If the backend cannot express a per-command deny list,
also implement `backend_allowed_tasks` returning only the tasks it is fit for;
`run.sh` enforces it and exits 78 otherwise. Say what the containment actually
is in a comment at the top, and add a test that pins the claim. `cursor.sh` is
the worked example of a weak backend done honestly.

Implement `backend_rehearsal` only if the backend can actually be handed a
config that blocks every GitHub write verb. `run.sh` refuses `POST=off` on a
backend that does not declare it, because a rehearsal that silently posts is
worse than no rehearsal.
