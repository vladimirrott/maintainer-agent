# Security policy

This project runs a language model unattended, with a GitHub token and whatever
else is on the machine, and lets it post in a maintainer's name. Its whole value
is the set of things it refuses to do, so a hole in a refusal is the bug that
matters most here.

## Reporting

**Do not open a public issue.** Use GitHub's private vulnerability reporting on
this repository (Security, Report a vulnerability). If that is unavailable to
you, contact the maintainers privately before publishing anything.

The agent that maintains this repository is instructed to file a **draft**
advisory and say in public only that the rest is handled privately. It never
publishes one.

## What counts

Anything that lets an agent, or a contributor's pull request, reach past a
refusal:

- **Forging a verification receipt**, or any path to `maintainer-merge merge`
  without one. The receipt is the only thing standing between a green board and
  a merge.
- **Escaping the deny wall** by a spelling it does not cover. The wall is
  generated and spells every verb from every directory it could run from,
  including the one it is installed in, and the bound is stated openly in the
  README: enumeration cannot be complete, so this stops a cooperative agent
  rather than a hostile one. A spelling that a *cooperative* agent would
  plausibly produce is a bug. A deliberately obscure one is a documented limit.
- **A rehearsal that reaches GitHub.** `POST=off` must produce reports and
  drafts and nothing else, including through the tools the agent is allowed to
  call, which is where two holes have already been found.
- **Executing contributor code** that `maintainer screen` should have refused.
- **Prompt injection** that changes what a run does, rather than being reported
  and ignored.
- **Anything that reads a credential**: `~/.ssh`, `~/.aws`, `~/.gnupg`,
  `~/.netrc`, a `gh` token, a model API key.

## What does not

- The deny wall not covering an exotic spelling nobody would type. Enumeration
  is incomplete by design and the README says so.
- An agent making a poor review. Wrong is not a vulnerability.
- Anything requiring write access to `~/.local/share/maintainer` already: at
  that point the profile is sourced by design and execution is granted.

## What to include

The command or fixture, what happened, what should have happened, and the
commit. If you have a reproduction, a shell transcript with secrets removed is
worth more than a description of one.

## What we do

Acknowledge it, reproduce it, write the failing test first, fix it, and say in
the release notes what was wrong. Every fix in this repository ships with a
mutation that turns the new test red, and a security fix is not an exception.
