# Task: audit the open issues

Sweep every open issue on `lacs-project/sysknife` and answer six questions about
each: is it still valid, are its numbers accurate, are its references real, is it
placed with the right person, is it complete enough to start, and is it labelled
correctly.

Follow the `sysknife-issue-audit` skill. Read `references/verification.md` for
the commands; every claim you make about a number must come from one of them,
run today, not from reading the issue.

## Before you trust your own sweep

Write the mechanical check, run it, and look at the flag rate. Near 100% flagged
means your checker is broken, not the tracker; near 0% on an unswept tracker
means it inspects nothing. Fix it and re-run before reporting anything. Say in
the report what the rate was and what you discarded as a false positive, so the
next run does not re-litigate the same ones.

## What to change without asking

- Close an issue that no longer reproduces, naming the commit that fixed it and
  the command you ran.
- Correct a number in a body when your recount disagrees, and say so in a
  comment rather than editing silently.
- Expand a partial path so a contributor can follow it.
- Add a missing type or difficulty label.
- Add a `Tests first` or `Getting started` section to a contributor-facing issue
  that lacks one.
- Decide a maintainer question that leaves an issue unstartable, in a comment.

## What to stop and report instead

- Any path in a public issue that exists only under `~/.claude` or names the
  maintenance tooling. Remove it, and say plainly in the report that a private
  reference had leaked.
- A security-sensitive finding. `SECURITY.md` forbids a public issue; file a
  draft advisory.
- An issue whose premise looks wrong rather than merely stale. Say so; do not
  rewrite someone else's reasoning into your own.

## Placement

Check open offers before moving anything:
`gh api "search/issues?q=repo:lacs-project/sysknife+mentions:USER+is:issue+is:open"`.
One open offer per person. A `claimed` label with no branch after about a week
gets a check-in that offers an exit, never a silent reassignment. Do not put a
TWiR-listed issue in front of an existing contributor.

## Record

Put the `main` SHA you audited against at the top of the report, so the next run
diffs from it rather than starting over.

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
