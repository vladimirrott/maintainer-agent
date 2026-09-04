# What this is

An unattended maintainer for one repository. It runs on a timer, reviews what
arrived, files what it found, and prunes what merged. It can merge, but only
against a receipt that somebody watched a guard go red.

It maintains [`lacs-project/sysknife`](https://github.com/lacs-project/sysknife)
and this repository, on one laptop, in the owner's name.

## The three questions it is built around

**What stops it doing damage?** A deny wall of 36 verbs, generated per profile
and spelled from every directory each tool could be installed in, passed to the
model runner as settings that outrank its own permission mode. `git push`,
`gh pr merge`, `cargo publish`, `gh release`, the credential files, and the key
that signs its own verification receipts. Read
[what contains a hostile pull request](containment.md) for the parts that wall
does not cover, and what does.

**What stops it inventing things?** Every number it publishes is recounted with
a command, every path resolves against the tree, and every guard is mutated
before it is called a guard. A run that found nothing posts nothing. The
transcript records what it *ran*, not what it *said*, and `maintainer audit`
compares the two.

**What stops it merging something broken?** A green board is not proof. This
project's recurring defect, and the one it was built against, is a test that
passes with the fix reverted, which no board can see. So a merge needs an
*observed* receipt: the gate runs the test in a container, applies a mutation,
runs it again, and records a receipt only if it passed clean and failed
mutated. An unattended run cannot write any other kind.

## What it is not

It is not a boundary against a kernel exploit, and
[containment.md](containment.md) says so in the same words. It is not a general
safety mode: the rehearsal wall is about GitHub and had nothing to say the day
an agent turned off its own scheduler, which is
[lesson 36](lessons.md#36-the-agent-turned-off-its-own-scheduler-and-the-other-projects).

## Where to start

[What a maintainer actually does](maintainer-doctrine.md) is the reasoning: three
documented failures of solo maintainers, and what each one changes about the
design. [Deploying it](deploy/README.md) is the practical end, four ways, in
order of how much you have to trust the machine.

[The lessons file](lessons.md) is thirty-six defects that reached a working
system, each with the measurement that found it. It is the fastest way to
understand why anything here is shaped the way it is, and several entries end in
work that is still open.
