# When a release is owed

```sh
maintainer-repo release-check
```

It reads, and never tags or publishes. A published crates.io or npm version
cannot be replaced, so cutting one stays a human decision.

## What it reads

It fetches tags, takes the last tag reachable from `origin/main`, and lists the
commits since. Then it counts:

| line | source |
|---|---|
| production files touched | `git diff` of the tag against `origin/main`, limited to the profile's `PROD_GLOBS` |
| shipped surface touched | the same, limited to `SHIPPED_GLOBS`: what a release publishes. `PROD_GLOBS` includes CI, because a workflow change must invalidate a receipt; a release does not carry CI |
| Security and Added sections | the `## [Unreleased]` section of `CHANGELOG.md` |
| removed-capability wording | `no longer`, `used to succeed`, `used to work` and `refuses` in that section |

A profile that declares no `PROD_GLOBS` or `SHIPPED_GLOBS` gets a warning, since
unset is not the same as untouched.

## The verdict and the digit

- no production file changed: docs and tests only, a release is optional;
- a Security section or removed-capability wording: **release due**;
- otherwise production code changed and a release is worthwhile.

The digit follows the CHANGELOG's own rule. While the major version is 0, a
change that makes something that used to succeed now refuse is a break, and a
break moves the middle digit. Everything else, compatible additions and fixes,
moves the last. A security fix moves the middle digit as well, because it has
to reach every pinned installation.

## When its answer may be wrong

It says so instead of guessing. It reads the CHANGELOG from the working tree
while the counts come from `origin/main`, so it prints which branch it read,
warns when `CHANGELOG.md` has uncommitted changes, and warns when `HEAD` is
behind `origin/main`: that checkout lacks entries the file about to be tagged
has, and a break read as a patch would reach everyone pinned to the series.
An empty Unreleased section is reported too, with the newest version heading,
because it usually means the section was already promoted.
