# Task: review every open pull request

Read the context block at the end first. It lists what moved since your last
review run. A PR whose head has not moved since you reviewed it gets nothing.
Run `maintainer lease check <pr>` before you post on one, and skip a PR it
reports as leased, saying so in the report.
`maintainer reviewed <pr>` lists what this account already said at the head now
and the lease, so use it instead of a hand-built loop over reviews and comments.

Two lines there answer different questions, and only one of them is yours.
`main moved <old> -> <new> ... commit(s) YOU HAVE NOT REVIEWED` is the range
this task has not seen, and it is the one to use. The `main <before> -> <after>`
line reports what this run's own fetch pulled in, and says `(already current)`
when a commit was made on the machine rather than fetched, which is not the same
as "nothing to review".

On the very first run there is no previous baseline and the block says so.
Review the last few commits instead, and say in the report that this run set the
baseline.

## Pin the head before you read

```sh
git fetch origin refs/pull/N/head:pN --force
git rev-parse pN
```

Put that SHA in your review. Contributors push mid-review, and a review of a
head that no longer exists wastes their time and yours.

## Screen before you build

```sh
maintainer screen <pr>
```

`cargo test`, `npm test`, `pytest` and their equivalents compile and run a
stranger's code as you, and a build script runs it earlier than that. On
anything but `INERT`, review by reading the diff, and say in the review that you
did not execute it. That sentence is not an apology: it tells the contributor
exactly how far your confidence goes.

## Check the author's own claims

Every number in the PR body gets recounted with a command whose output you can
paste. Most contributors are accurate. Recounting is what makes your numbers
worth reading, not a statement about them.

## Mutation-prove every guard the PR adds

A test that stays green with the fix reverted is the defect that survives every
other check, and it is the most common one on any tracker.

1. Break what the guard protects. It must fail, naming the file and the value.
2. Break the guard's own input. It must fail loudly rather than inspect nothing.
3. Revert the production hunk and re-run the PR's new test. Green here means the
   test proves nothing. Report that as the finding, with the command.

Commit first. `git checkout --` on a dirty tree destroys your own work and fakes
every later result.

## Merging

You may not merge directly. `maintainer-merge` is the only path, and it refuses
without a receipt that somebody watched a guard go red at this head.

```sh
maintainer-merge verify <pr> <head-sha> "<test filter>" "<sed mutation>"
maintainer-merge merge  <pr>
```

If it refuses, report the refusal. Do not work around it.

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

- After a merge lands, `maintainer-repo prune`. It deletes only branches that
  are ancestors of `origin/main` and refuses to touch one that still heads an
  open pull request.
- End every run with `maintainer-repo release-check` and report the verdict in
  one line, even when it is `nothing to release`. You never cut the release: a
  published version can never be replaced, so the tag is a human decision.

## Reply

Lead with the specific thing they did well. Separate the one blocking item from
the optional ones and say which is which; a long undifferentiated list makes a
finished PR look unfinished, and contributors abandon those. Name an open issue
that fits what they just demonstrated.
