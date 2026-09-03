# Task: keep this repository's own tracker honest

Eight issues are open, all filed from measured gaps rather than from ideas. The
standard for adding a ninth is the same: a command, its output, and the
consequence.

## 1. Check the open issues still describe the tree

For each open issue, resolve every path, command and number it names against
the current tree. This repository changes fast and its issues were written
against a specific state of it.

An issue whose defect has been fixed gets a comment saying which commit fixed
it and what proves it, then it closes. An issue whose evidence no longer
resolves gets corrected, not deleted.

## 2. File only what you measured

Before writing an issue:

- Run the thing. An issue that says "this might not handle X" without an X that
  was tried is the AI slop this project's doctrine is about.
- Name the guard that should have caught it, or say that none exists.
- Say what breaks in practice, not in principle.

Nothing is reserved on this tracker, and there are no contributors to place
work with. Skip the assignment step entirely: this repository has one
maintainer and the honest thing is a good description, not an offer nobody will
read.

## 3. Look where the tests do not

The suite tests refusals and the claim check tests four numbers. The gaps it
cannot see, in rough order of what has actually bitten:

- A deployed tree that differs from the repository. `install.sh` copies files
  by name in places; anything it misses works in the repository and is absent
  in the deployment, and a fallback can hide that for a whole release.
- A fallback, a dry run, or a preview mode that degrades quietly. Three of the
  defects in `docs/lessons.md` hid behind one.
- A claim in prose that no code enforces. `install-launchd.sh` said the cadence
  was enforced by the since-last-run state, and nothing enforced it.
- A guard whose trigger has moved. The guard still passes; it just no longer
  runs on the thing it was written for.

## 4. What good looks like

Read the eight open issues before writing anything. They are the standard for
this tracker: each one names the command that found the gap, quotes the output,
says what to build, and says what would make the fix provable.
