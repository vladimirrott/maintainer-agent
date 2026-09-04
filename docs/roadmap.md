# Where everything goes

Written 2026-09-04, after a week in which this agent maintained two repositories
and the defects it found in itself outnumbered the ones it found in them. It is
a plan for shape rather than for features: what belongs where, what a new
integration has to prove before it is allowed to post, and which drifts CI has
to catch because a human will not.

## 1. The backend contract is a containment contract

Adding a harness is easy. Adding one that may write to GitHub in somebody's name
is not, and the difference is a single question: **can this CLI be given a
per-command deny list it cannot edit?**

`backend_rehearsal` is where a backend answers it, and `run.sh` refuses a
`POST=off` run on any backend that does not declare it. That function is the
whole admission test. What follows is the current field, measured against it.

| harness | per-command deny list | tier | state here |
|---|---|---|---|
| **Claude Code** | `--settings` deny, outranks `bypassPermissions` | full | driving both profiles, proven daily |
| **opencode** | default-deny config, last-match-wins | full | wall generated, **never driven a run** |
| **Cursor** | `permissions.deny`, `CURSOR_CONFIG_DIR` | full | wall generated 2026-09-04, **unproven** |
| **Codex** | sandbox only, no per-command list | read-only | wall absent by design; correctly cannot rehearse |
| **Oh My Pi** | three-level posture, coarse | read-only | not integrated |
| **Hermes Agent** | sandboxed execution, not a deny list | read-only | not integrated |
| **Pi** | **none**: runs with the caller's permissions | none | must never post |
| Goose, Aider, Gemini CLI, CodeWhale | unassessed | — | not integrated |

Two things fall out of that table and they are the plan for this section.

**Tier is not popularity.** Pi is excellent and has no permission system at all,
which disqualifies it from every task that can post and leaves it a candidate
for `readonly-review` and nothing else. A harness's quality and its containment
are independent axes, and this project only cares about the second.

**A generated wall is not a proven wall.** Cursor's is rendered from the same
`deny.json` as every other backend and matches the documented shape. Nothing has
watched `cursor-agent` refuse a denied command. Until `tests/containment-probe.sh`
runs against it, the read-only restriction stays, and the same applies to
opencode. Issue #5 is where that evidence goes, and it is the gate on lifting
either restriction. Lifting a guard because a configuration ought to work is the
shape `lessons.md` records most often.

**Definition of done for a new backend:** a `lib/backends/<name>.sh` answering
the four questions, a wall generated from `deny.json` if it can hold one, a
containment probe run that names the command it refused, and a row in the table
above with the date it was proven. Not before.

## 2. Repo shape

The tree grew by accretion and two directories now mean more than their names.

```
bin/          five commands a person or a run types
lib/          run.sh, the shared doctrine, one file per backend
profiles/     one directory per maintained repository, plus _template
scripts/      generators and gates called by hooks, CI and install.sh
platform/     scheduling, one directory per OS
tests/        the offline suite, and the container probe
evals/        adversarial scenarios, scored per profile
docs/         the book, built by mdBook from this directory
```

What is wrong with it today, in the order worth fixing:

- **`scripts/` mixes generators with gates.** `render-settings.py` produces
  deployed artifacts; `check_claims.sh` and `shellcheck-sweep.sh` decide whether
  a commit may land. Those are different jobs with different blast radii.
  Proposal: `scripts/gen/` and `scripts/gates/`, with the hook and CI naming the
  directory rather than the file, so a new gate is picked up by existing.
- **`docs/` is both narrative and reference.** `lessons.md` and
  `maintainer-doctrine.md` are read once; `cli.md` and `deploy/` are read
  repeatedly. The book already separates them into sections; the directory does
  not.
- **`profiles/_template` is the contract for a new adopter and is tested only
  indirectly**, through `new-profile.sh`. Every rule a profile must satisfy
  (declare a budget per task, a subagent model only for tasks that fan out, a
  claim label or an explicit empty one) is enforced by a test that iterates
  `profiles/*/`. That is the right shape and should be the stated one: **the
  template is the specification, and the tests read it as such.**

## 3. CI, and the drifts it has to catch

Every gate below exists because something drifted silently first.

| gate | catches | added after |
|---|---|---|
| `check_claims.sh` | a README number that no longer matches the tree | a claim of 42 tests over a suite of 30 |
| user-stories cross-check | the gap count disagreeing with the `[GAP]` markers | nothing checked either |
| command/docs cross-check | a subcommand no document mentions, and an internal one advertised | six had accumulated |
| prompt/doctrine cross-check | a doctrine rule that stopped reaching the assembled prompt | a prompt naming a renamed command |
| deny-wall spelling | a verb denied in one spelling and reachable in another | `maintainer-merge receipt` at an absolute path |
| cursor wall shape | a blanket `Shell(git)` that blocks the work rather than the damage | the first render did exactly that |
| `shellcheck-sweep.sh` | shell defects, locally as well as in CI | it lived only in CI |
| zero-skip rule | a case that stopped running because a tool went missing | a skip read as a pass |

**What is still uncaught, in priority order.**

1. **The suite runs on one kind of machine.** Every runner and this laptop have
   `git`, `jq`, `systemctl`, `podman` and `python3`. A minimal-container job is
   issue #15 and would have caught the `jq` dependency and the `systemctl`
   crash before a user did.
2. **Nothing verifies a backend's claims against its vendor's current docs.**
   The Cursor backend asserted "no per-command deny list" for as long as it
   existed, and the claim was wrong by the time anybody checked. A quarterly
   `docs-drift` job that fetches each vendor's permission documentation and
   fails when a backend's stated containment no longer matches would have caught
   it. This is the highest-value gate not yet built.
3. **Prose drift between `docs/` and behaviour.** The command cross-check covers
   names. Nothing covers claims: `containment.md` describes flags, `README.md`
   describes refusals, and both could describe a version that no longer exists.
4. **The eval suite scores rule *presence*, not behaviour.** Issue #1. Nine
   scenarios check that the assembled prompt still contains a rule. None checks
   that a model given that prompt obeys it.

## 4. Documentation

The book is `docs/`, built by mdBook, deployed on every push to `main`. The rule
that keeps it honest: **every number in it is derived, and every command in it
exists.** Both are gates, not habits.

What is missing:

- **A page on the merge gate**, which is the most distinctive thing here and is
  currently explained across the README, the doctrine and two lessons.
- **A page per backend**, replacing the comment blocks in `lib/backends/`, with
  the containment tier and the date it was last verified against vendor docs.
- **An adopter's first hour**: install, scaffold a profile, read a rehearsal
  report, turn posting on. `deploy/README.md` covers the four topologies and not
  the sequence.

## 5. What this is not a plan for

**More harnesses for their own sake.** Four backends already exist and two have
never driven a run; a fifth would make that three. The next integration work
that matters is proving opencode and Cursor, not adding Hermes.

**Autonomy beyond what evidence supports.** The agent may merge only against a
receipt it earned by watching a mutation fail, and every extension of what it
may do without a human should be argued the same way: name the evidence, then
build the thing that produces it.
