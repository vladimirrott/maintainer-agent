# Task: review what has landed, and check the claims still hold

This repository has no pull requests and no CI. The review surface is the
commits that landed on `main` since your last run, and the gates are the
pre-commit hook. Nobody reviewed those commits before they landed, which is
what makes this pass worth running.

## 1. Read the diff that landed

```sh
git log --oneline <last-reviewed-sha>..HEAD
git diff <last-reviewed-sha>..HEAD
```

The context block names the range this task has not reviewed, as
`main moved <old> -> <new> ... commit(s) YOU HAVE NOT REVIEWED`, and lists them.
Use that range.

One line in the same block answers a different question and is not it. The
`main <before> -> <after>` line reports what this run's own fetch pulled in, and
reads `(already current)` when a commit was made on this machine rather than
fetched. Trusting it once cost a whole commit's review.

On the first run there is no previous SHA and the block says so: review the last
three commits instead, and say in the report that this run set the baseline.

Read the whole diff. This repository is small enough that skimming is a choice
rather than a necessity.

## 2. Run the gates yourself

```sh
./tests/run-tests.sh
./evals/run-evals.sh
./scripts/check_claims.sh
```

The hook ran these before the commit existed. Run them again: a hook can be
bypassed with `--no-verify`, and a gate that passes on the author's machine and
fails on a clean checkout is the defect this project keeps finding in others.

Report the three numbers. If any gate fails, that is the finding and the rest of
the pass is secondary.

## 3. Ask what the new tests would fail on

The suite tests refusals. For each test the diff added, name the mutation that
turns it red, and run at least one of them:

```sh
# edit the guard, run the suite, read which assertion fired, restore
```

A test that stays green with its guard removed is worth less than no test,
because it reports safety that is not there. `docs/lessons.md` has three
occasions where a check in this repository passed for the wrong reason.

Never leave the tree dirty. Restore what you mutated and prove it with
`git status --porcelain` in the report.

## 4. Check the prose against the tree

This is the gate that reads English, and `scripts/check_claims.sh` only covers
the four numbers it knows about. Everything else in `README.md`,
`CONTRIBUTING.md` and `docs/` is unguarded prose about a system that changes
under it.

Read the diff for claims, then verify them:

- A sentence saying a guard exists: find the guard and read it.
- A sentence saying something was measured: find the measurement, and check the
  number in the sentence matches what the command returns now.
- A file path or a command name in backticks: resolve it. A prompt naming a
  command that had been renamed is `docs/lessons.md` §12, and it survived every
  gate this repository had.

## 5. Treat every change as a security change

The list this repository holds itself to:

- The deny wall is generated. A verb added to `deny.json` must come out spelled
  four ways; check the generated `settings.json`, not the spec.
- `Read(~/...)` and `Read(//...)` deny. `Read(/abs/path)` does not, because a
  single leading slash anchors to the settings directory. Anything that
  normalises those away is a silent disabling of every credential rule.
- `maintainer screen` decides whether contributor code may execute on a machine
  holding SSH keys. A change to its classification lists needs a case in the
  suite.
- `POST=off` is enforced by a wall and a prompt. A change that lets a rehearsal
  reach GitHub is the worst defect this repository can ship.
- The merge gate is the only path to a merge, and `maintainer-merge receipt` is
  denied to an agent for a reason: an agent that can write its own receipt
  proves nothing.

## 6. Housekeeping

`maintainer-repo prune` and `maintainer-repo release-check` are written for a
repository with tags and a CHANGELOG. This one has neither, so `release-check`
will say it cannot find a tag. Report that once and do not report it again;
filing it as a finding every run is noise.

## What to write

A report with the SHA range, the three gate numbers, every mutation you ran with
its output, every claim you checked with the command that settled it, and the
list of what you would have posted if this profile were posting.
