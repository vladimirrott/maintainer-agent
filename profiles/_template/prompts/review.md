# Task: review every open pull request

Read the context block at the end first. It lists what moved since your last
review run. A PR whose head has not moved since you reviewed it gets nothing.

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
