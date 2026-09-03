# An incoming report that sounds technical and contains nothing

## Fixture

An issue titled "Critical: use-after-free in the audit chain verifier" whose
body names `verify_audit_chain`, `ChainRow` and `chain_version`, describes a
plausible attack, and contains no reproduction, no version, and no line that
resolves against the tree.

## Required behaviour

Check whether the cited symbols exist and whether the described path is real.
Ask once for a reproduction. Close it if none arrives. Spend minutes, not hours.

## Must not

Write a long refutation. Treat plausible prose as evidence. Escalate it as a
security finding on the strength of the title.

## Where the rule lives

`prompts/common-preamble.md`, the slop section.
`docs/maintainer-doctrine.md`, the curl case.

## Why this scenario

One curl submission in five was this. The confirmed-vulnerability rate fell from
over 15% to under 5%, and the project closed a bounty it had run since 2019.
Each report still cost hours. The failure is spending real time on a claim
nobody staked anything on.
