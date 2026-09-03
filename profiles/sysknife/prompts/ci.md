# Three-day task: strengthen one sysknife gate

Invoke the `sysknife-ci-live-tests` skill and follow it. Prefer depth on one gate
over a survey of many.

1. Read your previous run reports under `~/.local/state/sysknife-maint/runs/` and
   continue from them. Say which gate the last pass audited, whether its finding
   is still open, and which gate you picked this time and why. Do not re-audit a
   gate audited in the last three runs unless its code changed.
2. Audit that gate properly: run it, revert the production code it guards, run it
   again. Green twice means it guards nothing. Then break the guard's own input
   and confirm it fails loudly rather than inspecting nothing.
3. Check the assertion for the shapes in `sysknife-review/references/traps.md`:
   pipefail masking a match, first-match `re.search`, anchoring on a literal the
   test declares itself, and assertions made after the test restored its setup.
4. Confirm every filter selects something. `cargo test NAME -- --exact` matching
   nothing exits 0, and a CI step running zero tests is green.
5. Postgres: podman on a free port, `--include-ignored` and
   `SYSKNIFE_REQUIRE_POSTGRES` both set, and a run that does not print
   `running 11 tests` did not exercise the contract.
6. Re-measure the two divergences in #346 and report the current numbers rather
   than repeating the ones in the issue. Check whether any new
   `tests/release/*.test.sh` or `tests/e2e/*.test.sh` landed unwired, and whether
   each workflow's `paths:` filter can be triggered by a change to what it guards.

Commit nothing and push nothing. When the fix is small and you are confident,
write the patch to the run's draft directory, file an issue that contains it, and
say in the report that a branch is ready to be cut. Vladimir opens the PR.
