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

## Arming a merge

If your review leaves only a mechanical item (a rebase, a conflict, a test count
that moved), approve at the head you verified and say the merge is armed, listing
the conditions. Do not merge unattended. Report it as ready under a
"ready to merge" heading with the conditions spelled out, and let the interactive
session close it. You cannot run a mutation in a container, so you cannot satisfy
condition 2 in the skill, and a merge you cannot verify is not one to make.
