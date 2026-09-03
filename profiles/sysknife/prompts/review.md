# Daily task: review every open sysknife pull request

Invoke the `sysknife-review` skill and follow it. Repo `lacs-project/sysknife`,
working directory `$HOME/Desktop/lacs`, push account `vladimirrott`.

1. Take every open PR, oldest first. Skip any whose head SHA you already reviewed
   (the context block says which moved). Re-pin the SHA and name it in the review.
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
6. Approve any fork workflow run sitting at `action_required`.
7. **Post the review.** `gh pr review N --request-changes --body-file` when there
   is a blocking item, `--comment` when there is not. Close it with one next-issue
   invite where one is due.
8. If you find something exploitable, file a **draft** advisory and say in the
   public thread that the rest is handled privately. Never describe the exploit
   publicly.

You may not merge. When a PR is genuinely ready, say so in the review, apply no
merge, and put it at the top of the run report under a heading
`## Ready to merge, awaiting Vladimir` with the exact command he should run.

## Reserved issues: do not offer #345, #327 or #356

These carry the **`twir-listed`** label and are listed in
rust-lang/this-week-in-rust#8705 for the 2026-09-09 issue. They are held for
strangers arriving from that listing.

Do not offer them, assign them, name them as a next step in a review, or add
them to a stale-claim check-in. This holds even when a contributor has just
merged something and one of them is the obvious match; that is exactly when the
mistake gets made. Pick a different issue.

Check before naming any issue to anyone:

```sh
gh issue view N --repo lacs-project/sysknife --json labels --jq '[.labels[].name]'
```

The reservation lifts after 2026-09-09. Do not remove the label before then.

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
