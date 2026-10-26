# Daily task: review every open sysknife pull request

Invoke the `sysknife-review` skill and follow it. Repo `lacs-project/sysknife`,
working directory `$MAINTAINER_REPO` (this profile's own review checkout, which you
start in), push account `vladimirrott`.

1. Take every open PR, oldest first. Skip any whose head SHA you already reviewed
   (the context block says which moved). Re-pin the SHA and name it in the review.
   Run `maintainer lease check <pr>` first and skip a PR it reports as leased,
   saying so in the report.
2. Run the gates its change class requires, copying the commands from
   `.github/workflows/ci.yml` rather than from memory. Use podman on a free port
   for anything Postgres, and confirm the run prints `running N tests` with N > 0.
3. Trace the change to a live production entry point and say what the observable
   consequence is, not what the code says.
4. Mutation-prove every guard it adds or touches, both directions. Then revert the
   production hunk and re-run the PR's own new tests. A test that stays green with
   the fix removed is the finding, and it has already happened twice here.
5. Give it a security pass against `references/security.md`. Anything touching
   `packaging/`, `validate.rs`, the action catalogue, the audit chain, provider
   plumbing or a trust-boundary dependency gets the deeper read. Diff both copies
   of any validator that exists in Rust and in Python.
6. List every fork workflow run sitting at `action_required` in the report. Your
   wall denies that POST, by design: approving a run on a pull request that
   touches `.github/workflows/**` is how a fork takes the token. Naming them is
   the whole job here; do not spend a turn trying the API call.
7. **Post the review.** `gh pr review N --request-changes --body-file` when there
   is a blocking item, `--comment` when there is not. Close it with one next-issue
   invite where one is due.
8. If you find something exploitable, file a **draft** advisory and say in the
   public thread that the rest is handled privately. Never describe the exploit
   publicly.

Merging goes through the gate and nowhere else. When a pull request is ready and
the gate refuses, report the refusal rather than working around it: put the pull
request at the top of the run report under a heading
`## Ready to merge, awaiting Vladimir`, with the exact commands he should run and
what the gate said.

## Reserved issues: whatever carries `twir-listed` today

Issues listed in a This Week in Rust Call for Participation are held for
strangers arriving from that listing. The label is the record; a number written
here is not. On 2026-09-23 this section still named #345, #327 and #356, all
three closed weeks earlier, and said nothing about the seven open issues that
carry the label now. A hold that names numbers goes stale in the direction that
costs something: the reserved list looked handled while the actually-reserved
issues were free to be offered.

So ask the label, every run, before naming any issue to anyone:

```sh
gh issue list --repo lacs-project/sysknife --label twir-listed --state open \
    --json number --jq '[.[].number] | join(" ")'
```

Anything it returns is off limits: do not offer it, assign it, name it as a next
step in a review, or add it to a stale-claim check-in. This holds hardest right
after somebody merges something and one of them is the obvious match, which is
when the mistake gets made. Pick a different issue.

Removing the label is a human decision, taken when the listing has run its
course. You never remove it.

## Merging

You may merge, and you may only merge through the gate.

`gh pr merge` is denied to you. `maintainer-merge` is not, and it enforces what a
green board cannot see: that a guard exists which fails when the change is
removed.

1. **Prove it.** Mutate the guard the PR adds or touches and watch it go red.
   `maintainer screen <pr>` first; if it says DO NOT EXECUTE, run the mutation in
   podman, which works here:

   ```sh
   podman run --rm --network=none -v "$PWD:/repo:z" -v "$HOME/.cargo:/cargo:O" \
     -w /repo -e CARGO_HOME=/cargo -e CARGO_TARGET_DIR=/repo/.container-target \
     -e CARGO_NET_OFFLINE=true docker.io/library/rust:1-slim \
     cargo test -p <crate> --bins --offline <filter>
   ```

   The `rust` image sets `CARGO_HOME=/usr/local/cargo`, so the mount is ignored
   unless you also pass `-e CARGO_HOME`. `sysknife-cli` is a binary crate and
   needs `--bins`.

2. **Have the gate observe it.** You cannot write your own receipt; that
   command is denied to you, because an asserted proof is exactly what the gate
   exists to replace. Instead:

   ```sh
   maintainer-merge verify <pr> <head-sha> "<test filter>" "<sed mutation>" [crate]
   ```

   It runs the filter in podman unmutated, applies the mutation, runs it again,
   and writes a receipt only if the test passed clean and failed mutated. If the
   test stays green under the mutation it refuses and says
   `THE GUARD DOES NOT BITE`, which is the finding, not an obstacle: report it.

3. **Merge**: `maintainer-merge merge <pr>`.

It refuses on a missing receipt, a review that is not `APPROVED`, any failing or
pending check, an empty check list, the wrong GitHub account, and any change to
production or CI files since the head the receipt names. If it refuses, report
the refusal; do not work around it.

Quote the mutation output in your review. A merge whose evidence is "CI was
green" is the failure this repository keeps having: a test that passes with the
fix reverted.

**Never merge** a PR touching `.github/workflows/**` without a human reading the
diff, a PR you have not reviewed at its current head, or one whose outstanding
item is substantive rather than mechanical.


## Mechanical items: mark them, and finish the quiet ones

When every blocking item of a `--request-changes` review is mechanical (a rebase,
a test count that moved, one line of a doc), end the review body with one hidden
line, last in the body with nothing after it:

    <!-- maintainer: fixup-items v1 head=<the 40-hex head you reviewed> [{"kind":"rebase"},{"kind":"test-count","file":"README.md"}] -->

The kind is rebase, test-count or doc-line and nothing else. The last two name
the one file. If anything else blocks, however small it feels, write no marker:
the pull request is substantive and stays with its author. Never write a marker
for a head you did not review, and never describe the class in prose instead of
the marker, because only the marker is read.

Once per run, after the reviews, run `maintainer stalled`. It lists the pull
requests whose author has been silent since such a review. For each one:

1. For a test-count or doc-line item, write the change as a unified diff of
   the one named file, in `git diff` form, to `fixup-<pr>.patch` under this run's
   drafts directory (the path `maintainer start` printed). Write the new value
   you can see in the tree; the script re-derives a test count with the
   profile's own command and refuses yours if it differs.
2. Run `maintainer-repo fixup <pr> --dry-run` and put what it prints in the
   report.
3. Run `maintainer-repo fixup <pr>`. The first call posts the heads-up and
   pushes nothing; a later run, after the notice has aged, does the push. It
   refuses on its own whenever any rule says no, and it reads the new head back
   from GitHub. Report its last line exactly. If it refuses, report the
   refusal and do not look for another way to the branch: you never push, and a
   conflict is the author's to resolve.

Never use this for a pull request that has a substantive item, touches
`.github/workflows/**` or production code, or has had any reply from its author
since your review.

## Housekeeping, every run

Two chores end projects by accumulating, so they close every review pass rather
than waiting for someone to feel like doing them.

1. **After any merge, prune.** `maintainer-repo prune` deletes branches that are
   ancestors of `origin/main`, local and remote, and refuses to touch one that
   still heads an open pull request. Run it after a merge lands, and once at the
   end of a run in which anything merged. `--dry-run` first if the list looks
   longer than you expect.

2. **Ask whether a release is owed.** `maintainer-repo release-check` reads the
   CHANGELOG's Unreleased section and says which digit moves. Report the verdict
   in the run report every time, in one line, even when it is
   `nothing to release`.

   On `RELEASE DUE` say so in the report and explain why in one sentence: a
   security fix or a removed capability sitting on `main` means every installed
   copy is still affected. **You never cut it.** crates.io and npm versions can
   never be replaced, so the tag is a human decision, and `gh release` is denied.

Both commands push or read on your behalf through a narrow path, the same way
`maintainer-merge` does. `git push` stays denied to you directly; what you are
allowed is the audited script, not the verb.

## Pull requests waiting on a human, not on you

Your wall denies `gh api ... POST`, so you cannot approve a fork's workflow run,
and that is deliberate: approving a run on a PR that touches `.github/workflows/**`
is how a fork takes the token. It does mean a first-time contributor's checks sit
at `action_required` until somebody clicks, and a review that reports "checks
pending" reads as the contributor's problem when it is the maintainer's.

List them explicitly. `gh pr checks <n>` showing `action_required`, or a rollup
with no runs at all, goes in the report under a heading that says a human has to
approve them, with the PR numbers. Saying nothing leaves them stalled for days.
