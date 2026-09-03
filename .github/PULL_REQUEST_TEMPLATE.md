## What this changes

One or two sentences. If it changes what an unattended agent is allowed to do,
say so in the first line.

## The mutation

This project's rule: **a guard you have not watched fail is not a guard.** Break
what your change protects, run the gates, and paste what went red.

```
$ <the mutation you applied>
$ ./tests/run-tests.sh
  ... FAIL  <the assertion that fired>
$ <restore>
$ ./tests/run-tests.sh
  ... N passed, 0 failed
```

If your change adds no guard, say so here instead. Docs and prose changes are
welcome and do not need one.

## Gates

- [ ] `./tests/run-tests.sh`
- [ ] `./evals/run-evals.sh` for every profile
- [ ] `./scripts/check_claims.sh` (README numbers are recounted from the tree)
- [ ] Nothing in `bin/` or `lib/` names a repository or a GitHub account
- [ ] A new number in the README is derived, not typed

## Anything you could not check

Say which command you could not run and why. That is a normal answer and a more
useful one than a ticked box.
