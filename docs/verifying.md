# Verifying a pull request

`maintainer-merge verify` earns the receipt that `maintainer-merge merge` asks
for. It proves one thing: a test fails when the guard it names is removed. A
green board cannot show that, so verify runs the test twice, once on the pull
request as it is and once with a mutation applied, and records a receipt only if
the first run passes and the second fails.

```sh
maintainer-merge verify <pr> <head-sha> <test-filter> <sed-mutation> [suite]
```

## What it does

1. Takes a per-pull-request lock, so two verifies of one pull request cannot
   build the same workspace side by side.
2. Reads the changed paths and picks a suite from the profile's `verify.d/`:
   the one you named, or the one suite that covers every changed path, or the
   one that covers every production path. When none does, it refuses and prints
   which suite covers which path, instead of running the wrong one.
3. Fetches the pull request head, checks it is the sha you named, extracts it to
   a scratch directory, and refuses a tree with a symlink that points outside
   itself.
4. If the suite defines `suite_prefetch_command`, runs it once with a network
   (the rust suite runs `cargo fetch --locked`), so a dependency bump can find
   the crates it names. The runs that execute tests never have a network.
5. Runs `<test-filter>` in a container: `--network=none`, `--cap-drop=ALL`,
   `--read-only`, `no-new-privileges`, a `/tmp` tmpfs, and the memory, CPU,
   process and time limits in [configuration](configuration.md). It must pass,
   and `suite_ran` must count at least one test that executed.
6. Applies `<sed-mutation>` to the files matching `suite_mutate_glob`. The
   mutation must change at least one file, and one the profile calls
   production (`PROD_GLOBS`), or the receipt would say a test notices its own
   edit.
7. Runs the container again. It must fail. A container that was killed (memory,
   timeout) is reported as that, never as a guard that bites or a contributor
   whose test broke.
8. Writes a signed receipt of kind `observed` under the state directory, with the
   first failing line of the mutated run.

`verify-deps <pr> <head-sha>` is the path for a pull request that only bumps
dependencies or pins: there is no guard to mutate, so the gate classifies the
diff and checks pins and image digests instead. `verify-part` proves one suite's
share of a diff that no single suite covers, and `merge` checks that the parts
add up to every production path.

## A suite

A profile's `verify.d/<name>.sh` is sourced by the gate and defines functions.
The file name is the suite name.

| function | required | what it answers |
|---|---|---|
| `suite_covers <path>` | yes | does this suite run that path |
| `suite_image` | yes | the image to run in |
| `suite_command <filter>` | yes | the shell command to run in the container |
| `suite_mutate_glob` | yes | one glob per line, the files a mutation may touch |
| `suite_ran <log>` | yes | how many tests the clean run executed, read from its log |
| `suite_needs` | no | binaries the image must contain; `maintainer-doctor` checks them |
| `suite_requires <runtime>` | no | refuse a runtime the suite cannot use |
| `suite_podman_args <runtime> <tree>` | no | extra container flags, one per line |
| `suite_prefetch_command`, `suite_prefetch_guard` | no | the networked fetch, and a host-side check that runs first |
| `suite_memory`, `suite_cpus`, `suite_pids`, `suite_tmpfs` | no | this suite's own resources, above the profile and below `MAINTAINER_VERIFY_*` |

`suite_ran` cannot be generic: cargo prints `test result: ok. N passed`, and a
shell test prints whatever its author chose. A suite that cannot say how many
tests ran gets no receipt, because a filter that matches nothing passes.

A profile with no `verify.d/` gets no merge. Copy
`profiles/_template/verify.d/shell.sh` and change the five required functions.
