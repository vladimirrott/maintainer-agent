# Working on this

Private repository, one maintainer, no CI. The gate runs before a commit exists.

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

Edit `profiles/<name>/deny.json` and add the verb once.
`scripts/render-settings.py` spells it bare and under `/bin`, `/usr/bin` and
`/usr/local/bin`, because the matcher keys on the command as written and
`/usr/bin/touch` was measured evading a rule for `touch`.

Two things in the generated output look like typos and are not: `Read(~/...)` is
the only form that denies (a single leading slash anchors to the settings
directory, measured), and the same credential path is denied to `cat` three
different ways on purpose.

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
