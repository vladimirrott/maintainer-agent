# Working on this

Private repository, one maintainer, no CI. The gate runs before a commit exists.

## Setup

```sh
git config core.hooksPath .githooks   # once
./install.sh --dry-run                # see what a deploy would touch
```

Required: `bash`, `python3`, `git`, `gh`, `jq`. For a real run you also need one
backend on `PATH` (`claude`, `codex` or `cursor-agent`) and `podman` if you want
container verification.

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
bin/maintainer          refresh, diff, screen, report  (the run's bookkeeping)
bin/maintainer-merge    the merge gate; the only path to a merge
lib/run.sh              orchestrator, platform-independent
lib/backends/*.sh       claude | codex | cursor
lib/prose-style.md      injected into every prompt unless PROSE_STYLE=raw
profiles/<name>/        everything site-specific: paths, account, prompts, deny wall
platform/{linux,macos,windows}/   scheduling only
evals/scenarios/*.md    adversarial situations with a required behaviour
docs/maintainer-doctrine.md       why the refusals are the ones they are
```

The core is bash on every platform. Only scheduling forks. Two implementations
of a security gate drift, and the gate is the product; a test asserts there is
exactly one executable implementation of the merge gate.

## Adding a profile

Copy `profiles/sysknife/`, change `profile.env`, and write the prompts. No code
change should be needed. If one is, that is a bug in `run.sh`.

## Adding a backend

Implement `backend_name`, `backend_check` and `backend_run` in
`lib/backends/<name>.sh`. If the backend cannot express a per-command deny list,
also implement `backend_allowed_tasks` returning only the tasks it is fit for;
`run.sh` enforces it and exits 78 otherwise. Say what the containment actually
is in a comment at the top, and add a test that pins the claim. `cursor.sh` is
the worked example of a weak backend done honestly.
