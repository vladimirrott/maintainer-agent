# Testing a change to magent

Everything in this repository's suite tests a refusal. magent earns trust by what it declines to do, so a test here proves that a guard stops something, and a test that cannot fail proves nothing. This page covers the four layers of tests, how to run each, how to write a case that can go red, how to prove it goes red, and how to run the same gates the maintainer runs before a commit exists.

If you read one section, read [Writing a test that can fail](#3-writing-a-test-that-can-fail) and [Proving a test bites](#4-proving-a-test-bites). Every defect in `docs/lessons.md` about the suite is a test that passed while the guard it named was absent.

## Contents

1. [The layers](#1-the-layers)
2. [Anatomy of a case in `run-tests.sh`](#2-anatomy-of-a-case-in-run-testssh)
3. [Writing a test that can fail](#3-writing-a-test-that-can-fail)
4. [Proving a test bites](#4-proving-a-test-bites)
5. [Isolation](#5-isolation)
6. [Published figures](#6-published-figures)
7. [Running the gates locally](#7-running-the-gates-locally)
8. [Rust tests](#8-rust-tests)
9. [Reviewing a test](#9-reviewing-a-test)
10. [Troubleshooting](#10-troubleshooting)

## 1. The layers

| layer | what it proves | add a case when | run it | time |
|---|---|---|---|---|
| `tests/run-tests.sh` | The black-box oracle. Every program, profile, script and document refuses what it must and says so. Cases that read program text carry an `sc_case` tag. | You add or change a guard, a prompt rule, a profile file, a script or a doc claim. This is the default home for a new case. | `bash tests/run-tests.sh` | about 4 minutes on a loaded laptop |
| `tests/characterization/` | What `bin/maintainer-merge` does today, odd behaviour included, by exit code, stream and `gh` argv, so a port can be held to it. | You change the merge gate's observable behaviour: its argv, its exit codes, its messages, its order of calls. | `bash tests/run-characterization.sh` | about 1 minute |
| `tests/diff/` | That two program trees (the bash tree and a Rust tree) behave the same on the scenarios in `tests/diff/scenarios/`: argv per stub tool, exit code, stdout, stderr, state tree. | You add a scenario for a program that a port will replace. | `bash tests/diff/record.sh`, `compare.sh`; the recorder's own checks are `selftest.sh` and `prove.sh` | `selftest.sh` about 25 s, `prove.sh` under 2 minutes |
| `scripts/rust-gate.sh` | The Rust workspace formats, lints clean, passes its tests, keeps process spawning inside `mx-ports`, and exchanges receipts with the bash gate. | You touch anything under `rust/`. | `scripts/rust-gate.sh` | about 30 s once built |

Counts of cases are not typed here. The suite prints its own total, and the figure markers in the README keep the published number honest (see [Published figures](#6-published-figures)).

### `tests/run-tests.sh`

One bash file of several thousand lines, organised in sections that each open with `echo "== what this section proves =="`. A run prints one line per case, then a summary:

```
  PASS  unknown profile is rejected
  FAIL  <name>
  ...
  N passed, F failed (K source-coupled cases)
```

The exit code is 0 only when `F` is 0. The file has no section filter: it takes no arguments. To run one section while you iterate, build a probe from the file's head, the section and the file's tail, the way the suite tests itself (`mx_probe` in the suite):

```sh
cd ~/code/maintainer-agent                    # your worktree
sect='a verdict is read from output'          # the words after "== " in the header
start="$(grep -n "^echo \"== $sect" tests/run-tests.sh | cut -d: -f1)"
[ -n "$start" ] || { echo "no such section"; exit 1; }
end="$(awk -v s="$start" 'NR>s && /^echo "== /{print NR-1; exit}' tests/run-tests.sh)"
{ sed -n '1,/^echo "== argument handling =="/p' tests/run-tests.sh | sed '$d'
  sed -n "${start},${end}p" tests/run-tests.sh
  sed -n '/^if \[ "\$skip" -gt 0 \]/,$p' tests/run-tests.sh; } > tests/probe.sh
bash -n tests/probe.sh && bash tests/probe.sh; rm -f tests/probe.sh
```

A section often reads a variable an earlier section set (`$mg`, `$md`, a stub). `unbound variable` in the output means the probe left that setup out: copy the line that defines it, or run the whole suite. Read the summary line either way: a probe that ran zero cases prints `0 passed, 0 failed` and exits 0.

**`MX_TREE`** points the suite at another tree with the repository layout, for a build whose programs are not shell. The first output line names the tree under test. A tree without `bin/maintainer-merge`, `lib/run.sh` or `profiles/` exits 2 before any case runs, so a wrong path cannot read as a tree that fails. The suite's own text always comes from the checkout that holds the file (`suite_root`); the programs, profiles and docs the cases run or read come from the tree under test (`root`). Two guard cases grep the suite for a case that mixes them up.

**`sc_case` and `MX_SKIP_SOURCE_COUPLED`.** A case is source-coupled when its verdict depends on the text of a shell program: it greps the program, sources it and calls an internal function, or runs a checker that scans program text. A compiled tree has no text to grep, so those cases are wrapped:

```sh
if sc_case 2; then
grep -q 'flock' "$mg" && ok "..." || bad "..."
check "..." "$x" "$y"
sc_end; fi
```

`sc_case N` declares that the block records exactly `N` outcomes. With `MX_SKIP_SOURCE_COUPLED=1` it returns 1, the block does not run, and `N` skips are counted, so a skipped run reports the number a normal run executes. `sc_end` fails the suite when the block recorded a different count, and `sc_case 0`, a block never closed, and a stray `sc_end` each fail too. Tag a new case `sc_case` only when it reads shell text. A case that runs a program and reads what it prints belongs outside the block, because it must hold for any tree.

**Skips.** `noenv "reason"` records a skip, a case this machine could not run (no container runtime, no `flock`). A skip is not a pass: the summary prints `N passed, F failed, S skipped`, the exit code stays 0, and CI fails the job when it sees a skipped case. The runners have docker, so every case that needs a container must run there even though your laptop may not have one. Say how many skips a run had when you describe it.

### `tests/characterization/`

A characterization case records what the bash gate does now. Where the bash program does something a port is meant to change, the comment above the case says `pins current behaviour, see plan decision F<n>`, and the case still pins it. Where a case caught a defect, it flips to the fixed behaviour and says `fixed`, as the F9 head-fence cases do (`tests/characterization/gate-merge-path.sh`).

`tests/run-characterization.sh` runs every file of a known family (`gate`, `run`, `doctor`, `repo`, `install`, matched as `<family>-*.sh`), skips helper files named `lib*.sh`, and takes file names to run a subset:

```sh
bash tests/run-characterization.sh gate-merge-path.sh
```

Each case file ends by printing `SUMMARY cases=N pass=P fail=F`. The runner refuses a file with no summary, a summary whose total does not equal the `PASS`/`FAIL` lines it printed, and a run of zero cases, so a file that dies half way cannot read as a pass. `MX_TREE` works here as well.

`tests/characterization/lib.sh` holds the helpers. A case is a function run in a fresh sandbox:

```sh
case_merge_head_read_fails() {
    cz_merge_ready 7                      # a PR that merges: approved, clean, one passing check
    cz_gh pr-view.headRefOid "" 1         # what the stub gh prints for that call, and its exit code
    cz_mm merge 7                         # run bin/maintainer-merge under env -i
    cz_expect_refusal 1 "maintainer-merge: could not read the head commit of #7; ..."
}
cz_case "merge: a failed read of the head refuses, and gh pr merge is never called" case_merge_head_read_fails
```

The sandbox gives each case its own stub directory first on `PATH`, its own `HOME`, state directory and signing key, and runs the program under `env -i`. `gh`, `podman`, `docker`, `curl`, `wget`, `ssh` and `flock` are stubs. A `gh` call with no planned answer exits 99 and is logged, and `cz_case_end` fails the case that made it, so a call nobody planned cannot be swallowed by the program under test. Assert by value: `cz_expect_rc` and `cz_expect_refusal 1 "<first stderr line>"` take the code and the message, and `cz_expect_gh_line "$(cz_argv ...)"` compares one `gh` call, argument by argument.

The receipt format has a known-answer vector: `tests/characterization/golden/receipt.key` (a test key) and `receipt-asserted.json`. `gate-receipt.sh` checks the gate's bytes against the golden file after normalising only the timestamp and the signature, and the Rust crate checks the same file (see [Rust tests](#8-rust-tests)).

### `tests/diff/`

The differential recorder runs one set of scenarios against two trees and diffs what each stub received, the exit code, stdout, stderr and the state tree.

```sh
bash tests/diff/record.sh <tree> tests/diff/scenarios <out>     # one result directory per scenario
bash tests/diff/compare.sh <out-old> <out-new>                  # exit 0 same, 1 differ, 2 harness error
bash tests/diff/selftest.sh                                     # the normaliser, compare, record guards, determinism
bash tests/diff/prove.sh                                        # four detection mutants and the normaliser bite
```

A scenario is one bash file in `tests/diff/scenarios/` with a shebang and no `. lib.sh` line. `record.sh` sources `lib.sh`, then the file, under `env -i`. The file builds stubs and state with the `mx_*` helpers (`mx_stub`, `mx_env`, `mx_git_repo`, `mx_receipt`) and ends with exactly one `mx_run <program-in-tree> [args]`; a second `mx_run` is a harness error. `PATH` holds the stubs and symlinks to real tools only, so a tool nobody stubbed is `command not found` in both trees.

`tests/diff/normalise.py` rewrites the values that legitimately differ between two runs (temporary paths, timestamps, pids) so the diff shows behaviour. `python3 -I tests/diff/normalise.py rules` lists every rule with its reason, and `... selftest` runs the examples each rule must change and the text it must leave alone. A new rule needs a reason and an example, because a rule that hides a real difference is a hole in the recorder. `prove.sh` removes one rule from a copy and shows that two recordings then differ, and that four one-line mutants of the bash gate (a usage word, an exit code, an argument order, a message) each change the named scenario and field.

### The Rust gate

`scripts/rust-gate.sh` runs, in order, and stops at the first failure: `cargo fmt --all --check`; `cargo clippy --workspace --all-targets --locked -- -D warnings`; `cargo test --workspace --locked` with a floor on the number of tests that ran; a probe that adds a crate calling `Command::new` and demands clippy refuse it; a scan that no crate but `mx-ports` names the `disallowed_methods` lint; and the receipt interop run. [Rust tests](#8-rust-tests) says what each step protects.

## 2. Anatomy of a case in `run-tests.sh`

The top of the file sets up everything a case may use. Read the first 170 lines once; everything a case may use is there.

- `ok "name"`, `bad "name"` record a pass or a failure. `check "name" "$actual" "$expected"` compares two strings and reports both on failure. `noenv "name"` records a skip.
- `stub_dir="$(mktemp -d)"` is a scratch directory removed on exit. It holds the stubs, and cases that need files build them under it. Put it first on `PATH` for the call that needs the stubs: `PATH="$stub_dir:$PATH" bash "$root/..."`.
- `make_stub NAME 'body'` writes an executable `NAME` into `stub_dir` with `#!/usr/bin/env bash` and the body. The suite starts with stubs for `notify-send`, `claude`, `codex` and `flock`. A case that needs `gh` writes its own.
- `MAINTAINER_STATE_DIR` and `MAINTAINER_RECEIPT_KEY` point into `stub_dir`, so a run cannot append to the real audit trail or sign with a developer's real key. A case that runs a program that reads `MAINTAINER_STATE` (without `_DIR`) sets it itself, as the example below does. The suite unsets every `MAINTAINER_*` variable at the top, so the answer never depends on who called it.
- `MAINTAINER_NOTIFY=off` is exported once, so a case with a minimal `PATH` cannot raise a desktop popup. `MAINTAINER_REPO_ORIGIN` is a bare repository in `stub_dir`, so a case that provisions a checkout clones from it and never from github.com. `MAINTAINER_SHELL_IMAGE` is a registry image so the container cases run on a runner with no locally built image.
- Every scratch git repository a case builds runs under the unset at the top of the suite, `unset $(git rev-parse --local-env-vars)`. A pre-commit hook runs the suite with `GIT_DIR` and `GIT_INDEX_FILE` set for the commit in progress, and a scratch repository that inherits them writes into the real index (lesson 110). A later case asserts that none of those variables reaches the cases.
- `root` is the tree under test and `suite_root` is the checkout that holds the suite. A case that runs or reads a program uses `$root`; only the suite's own text goes through `$suite_root`. Both directions are pinned by cases near the end of the file.

A complete case, run against the repository as it stands:

```sh
echo "== a pull request number is an integer =="
make_stub gh 'exit 0'
out="$(PATH="$stub_dir:$PATH" HOME="$stub_dir" MAINTAINER_STATE="$stub_dir/state-root" \
    MAINTAINER_ACCOUNT=testuser MAINTAINER_SLUG=o/r MAINTAINER_REPO="$stub_dir/no-repo" \
    bash "$root/bin/maintainer-merge" merge '7;1' 2>&1)"; rc=$?
check "a pull request number with a semicolon exits 1" "$rc" "1"
grep -q "must be a positive integer, not '7;1'" <<<"$out" \
    && ok "and the refusal names the integer rule" \
    || bad "the refusal came from somewhere else: $out"
```

It captures the output and the exit code before it inspects either, it asserts the message as well as the code, it greps a herestring, and its failure text carries the output. Section 4 uses this case to show why the second assertion exists.

`HOME="$stub_dir"` matters: without it the program reads the deployed profiles in your real home, and the case fails with `<N> profiles are deployed` or `no profile is deployed`, which looks like a regression and measures your laptop (lesson 40).

## 3. Writing a test that can fail

Each rule below comes from a defect where a test passed with the guard absent. Lesson numbers refer to `docs/lessons.md`; the CHANGELOG entries for 0.11.0 carry the newest cases.

1. **Assert the message, not only the code.** An exit code is a number any earlier failure can produce. The identity-gate cases asserted `rc=1` while the code under test sat behind a failing `backend_check` that also returned 1, so the gate never ran (lesson 45). In the example above, a mutant that breaks the integer check still exits 1, because the next guard refuses `7;1` for another reason; only the message assertion goes red.
2. **Assert the count of cases that ran.** A filter that selects nothing passes. `sc_case N` and `sc_end` pin a block's count, the characterization runner refuses a file with no `SUMMARY` line or a total that disagrees with its `PASS`/`FAIL` lines, and `rust-gate.sh` refuses a run of 15 tests or fewer. A scan over files states how many it scanned and refuses too few, as the `grep -q` scan does (`$pq_n scanned`, lesson 116). When you write a loop over a list, assert the list is not empty first.
3. **Capture before you inspect.** `out="$(cmd 2>&1)"; rc=$?`, then look at `$out`. `out="$(cmd | tail -3)"; rc=$?` reports `tail`'s status, and under `pipefail` `cmd | grep -q x` reports the death of `cmd` when it dies. A case in this suite passed for two runs while the check it tested did not exist, because `doctor | grep -q` returned doctor's own exit code. The suite now greps its own text for that shape and names the line (the section "a verdict is read from output, not from a pipeline's exit code").
4. **Grep a herestring.** `grep -q 'pattern' <<<"$out"`. `grep -q` exits at the first match, the writer on its left takes SIGPIPE, and `pipefail` reports the match as a failure: 3 failures in 300 calls on a 23 KB payload, none with a herestring, and a suite that failed about two runs in five on a different assertion each time (lesson 67). A second guard scans every shipped script for a pipe into `grep -q` (lesson 116).
5. **A stub needs an arm for every call the code makes.** A stub with no arm for a call returns nothing, the helper errors, and the guard skips in silence. In `tests/characterization/lib.sh` the `gh` stub exits 99 on an unplanned call and the case fails. In `run-tests.sh`, a `make_stub gh "case \"\$*\" in ... esac"` with no matching arm exits 0 with no output: include an arm for each call and, for a case that matters, a final `*) echo "unplanned: $*" >&2; exit 99;;`.
6. **A stub that always succeeds mocks the thing you are proving.** The suite starts with `make_stub flock 'exit 0'`, so every case with `stub_dir` on `PATH` has a lock that is always free. A test of the merge lock ran under it, reported two concurrent merges both proceeded, and accused a lock that worked (lesson 74). The case now links the real `flock` into its own directory ahead of `stub_dir`, and it asserts that the holder really took the lock before it asserts that the second caller was refused. Prove the setup before you prove the refusal.
7. **A stub `PATH` can lose a tool the code needs.** The sweep test builds a minimal `PATH` of symlinks. `command -v true` prints the word `true`, not a file, because `true` is a builtin; the test needs `type -P true`, or the stub `systemd-run` cannot run its `true` probe, the sweep falls back to uncapped with the message `no memory cap`, and it still exits 0. Only the case that reads the capped linter line fails. When you build a `PATH` from symlinks, check each tool you link resolves to a file.
8. **A probe that logs the same flags as the real call hides a missing real call.** The `systemd-run` probe (`... true`) and the linter run log the same `--scope MemoryMax=...` words. The case that the linter ran capped reads the line that ends in ` shellcheck `, the line that proves the thing. Before you assert on a log, find the line only the behaviour you claim could have written.
9. **An assertion looser than its title.** `[ "$rc" != 0 ]` under a title that says exit 64 passes for any failure, including a crash. Assert the code you claim, by value. When the title says "refuses and names the PR", assert both.
10. **Fixtures that overwrite a shared file.** `stub_dir` is global state. A `make_stub gh` in one section replaces the stub for every later section until something removes it, and a `podman` stub left behind made a real test two hundred cases later report a receipt it never earned (lesson 74). Remove what you add when the block ends (`rm -f "$stub_dir/gh"`, as the sections around the container cases do), and name the files you write after the case.
11. **A fixture can expire.** A test wrote the date `2026-08-24` and asserted the idle column matched `1[0-9]d`. It passed for nine days and then accused the tool of the bug it tested. Compute dates from `date -u -d`, assert the exact figure, and leave an hour of margin so the two timestamps cannot straddle a second (lesson 78).
12. **Build the empty case as a fixture.** A guard whose input is never empty in the author's tests has never run. `release-check` warned about an empty Unreleased section for the first time when someone cut a real release; two tests covered it and both were greps for a phrase in the program's source (lesson 28). A grep for an identifier proves the file mentions it, not that the caller can call it (lesson 82).
13. **A test must build what it reads.** A test that reads `$HOME/.local/share/maintainer/...` measures the laptop that wrote it (lessons 23 and 40). CI runs the suite twice, once with `HOME` set to an empty directory, for exactly this: `HOME="$(mktemp -d)" bash tests/run-tests.sh`. Run it before you push.
14. **A mutant that only breaks syntax does not count.** If your proof turns the whole file red, you proved the file parses. Section 4 shows one; `bash -n` on the mutant, and a named case red by assertion, are the two checks.
15. **A check you have not seen fail is a check you do not have.** Calibrate a new checker on input where the answer is known before you believe a verdict: a flag rate of 0% or 100% means the check is broken (lesson 3), and a probe needs a control alongside it (lesson 4).

## 4. Proving a test bites

A new test is not accepted on the strength of going green. Show that it goes red when the production line it protects is removed. The maintainer's own gate does this for every guard a pull request adds (`maintainer-merge verify`, below); a contributor reproduces it by hand.

### The recipe

Work in a scratch copy of a committed tree. Never edit your worktree to test a mutant, and never restore with `git checkout -- path` or `git restore`, which also wipe uncommitted work. Commit your change first; the clone holds committed files only. It keeps `.git`, which a few cases in `run-tests.sh` need (see Troubleshooting).

**Step 1, a pristine copy and a working copy.**

```sh
S=~/.cache/magent-wt-scratch/mut; rm -rf "$S" "$S.pristine"
git clone -q --no-hardlinks "$PWD" "$S"          # run from your worktree root; the clone keeps .git
cp -a "$S" "$S.pristine"
```

**Step 2, a patch script that asserts before it edits.** The assertion comes before the first write, so a pattern that does not match exactly once leaves the file alone and stops.

```sh
cat > "$S.mutate.py" <<'PY'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, f"pattern occurs {s.count(old)} times, want 1"
open(path, "w").write(s.replace(old, new))
PY
```

**Step 3, apply it, read it back, check it parses, hash it.**

```sh
f="$S/bin/maintainer-merge"; before="$(sha256sum < "$f")"
python3 -I "$S.mutate.py" "$f" "$OLD" "$NEW" || echo "the pattern did not match once; stop"
diff "$S.pristine/bin/maintainer-merge" "$f"                  # read the change
bash -n "$f" || echo "the mutant does not parse; it proves nothing"
[ "$(sha256sum < "$f")" != "$before" ] || echo "the mutation did not land"
```

**Step 4, run the named case and expect it, and only it, to go red.** Touch every file first: a copy keeps old modification times, and a build tool decides freshness by them. Cap the run by time.

```sh
find "$S" -type f -exec touch {} +
out="$(timeout 300 bash "$S/tests/run-characterization.sh" gate-merge-path.sh 2>&1)"; rc=$?
echo "rc=$rc"; grep -E '^FAIL|cases,' <<<"$out"
```

Expect `rc=1` and the case you wrote on a `FAIL` line. A mutant that turns every case red failed to parse or broke something upstream. A mutant that turns nothing red is the finding: your test is decorative. For a case in `run-tests.sh`, run the suite against the mutant with `MX_TREE="$S" bash tests/run-tests.sh` (the suite text stays in your worktree and the programs come from the mutant) and read the `FAIL` lines.

**Step 5, restore from the pristine copy, and prove it.**

```sh
cp "$S.pristine/bin/maintainer-merge" "$f"
[ "$(sha256sum < "$f")" = "$(sha256sum < "$S.pristine/bin/maintainer-merge")" ] && echo restored
```

**Step 6, run the control.** Touch the files again and run the command from step 4. It must report `0 failed`. A control that fails is information: read why before you run again. For a batch of mutants, restore between them so one cannot contaminate the next, and run the control once more after the last.

**Step 7, report a cap as its own outcome.** A mutant that deletes a loop's exit guard can run forever, and `timeout` ending the run is neither a catch nor a pass.

### A worked example: the head fence

`maintainer-merge merge` reads the pull request's head and pins `gh pr merge --match-head-commit` to it, so a push that lands after the last check cannot merge. Before 0.11.0 the read had no check of `gh`'s exit status: a `gh` that failed there left the head empty, and the merge ran with an empty pin, which removes the fence. The fix is in `bin/maintainer-merge` in `cmd_merge`:

```sh
    head="$(gh pr view "$pr" --repo "$REPO_SLUG" --json headRefOid --jq .headRefOid)" \
        || die "could not read the head commit of #$pr; refusing to merge without a head to pin it to"
    case "$head" in
        ''|*[!0-9a-f]*) die "the head commit of #$pr came back as '$head', which is not a commit id; ..." ;;
    esac
```

Three cases in `tests/characterization/gate-merge-path.sh` pin it (the read fails, the read is empty, the read is not a commit id). To show the first one bites, remove the `|| die` line.

A first attempt deletes just the `|| die ...` line and leaves the backslash on the line above. That joins the next line onto the command and the file stops parsing: `bash -n` prints `syntax error near unexpected token ')'`, and the run reports `0 passed` with every case in the file failed. That result proves nothing about the guard. The mutant that counts removes the backslash with it:

```sh
python3 -I "$S.mutate.py" "$f" ' --jq .headRefOid)" \
        || die "could not read the head commit of #$pr; refusing to merge without a head to pin it to"' ' --jq .headRefOid)"'
```

`bash -n` passes, and the run reports exactly one failure, the case named for the failed read. The two neighbouring cases stay green because the `case` arm below still guards the empty and malformed head. After the restore and the control run, the file reports `0 failed` again. Each guard has its own case and its own mutant, and a guard behind another guard needs a test shaped for the path where only the inner guard stands between the input and the wrong answer.

The same discipline applies to the integer check in section 2. Replacing `*[!0-9]*` with `*[a-z]*` in `pr_or_die` leaves the exit-code assertion green (the next guard refuses `7;1` with exit 1 and a different message) and turns only the message assertion red. That is the reason to assert both.

### Where magent's own gate does this

`maintainer-merge verify <pr> <head-sha> <test-filter> <sed-mutation> [suite]` runs a test unmutated, applies a `sed` mutation to the files the profile's suite allows, runs it again, and records a signed receipt only when the first run passes and the second fails. It refuses a mutation that changes no line, one aimed outside the suite's mutate glob, a clean run that executed no tests, a run killed by memory or time, and, since 0.11.0, a mutation of production code the pull request did not change. `docs/verifying.md` has the full list. To reproduce its verdict by hand, use the recipe above with the same `<sed-mutation>` and the same test filter, and expect the same red case.

## 5. Isolation

No case may reach the network, a real `gh`, a real `podman` or `docker` (except the container cases), a real notifier, your `HOME` or your state directory. The harness enforces most of it by construction:

- `gh`, `claude`, `codex`, `notify-send` and `flock` are stubs in `run-tests.sh`; `gh`, `podman`, `docker`, `curl`, `wget`, `ssh` and `flock` are stubs in the characterization sandbox, and the diff recorder puts a logging stub in place of every tool in `MX_STUB_TOOLS`.
- State and keys live under `stub_dir` or the case's sandbox; the suite exports `MAINTAINER_STATE_DIR`, `MAINTAINER_RECEIPT_KEY`, `MAINTAINER_NOTIFY=off` and `MAINTAINER_REPO_ORIGIN` once, so a case added later cannot forget.
- The characterization and diff programs run under `env -i`.

To prove your own change reaches nothing real, put a decoy ahead of the real tools on `PATH`. The decoy records each call and fails:

```sh
d=~/.cache/magent-wt-scratch/decoy; mkdir -p "$d"
for t in gh claude codex; do
  printf '#!/usr/bin/env bash\nprintf "%s %%s\\n" "$*" >> "${DECOY_LOG:?}"\nexit 97\n' "$t" > "$d/$t"
  chmod +x "$d/$t"; bash -n "$d/$t" || echo "bad stub $t"
done
: > "$d.log"
DECOY_LOG="$d.log" PATH="$d:$PATH" bash tests/run-tests.sh; rc=$?
echo "suite rc=$rc, decoy calls: $(wc -l < "$d.log")"
```

A case that reaches past its own stubs to the next `gh` on `PATH` writes a line to the log. The cases that build their own `PATH` with `$stub_dir` first never reach the decoy; the decoy catches a case whose `PATH` does not. On the commit this page was written against, the suite exited 0 and the decoy logged five calls: one `gh api repos/actions/checkout/git/ref/tags/...` from the action-pin check and four `gh api user --jq .login` from identity checks. Those cases reach whatever `gh` is on `PATH` when no stub is present, so on a machine with a real, logged-in `gh` they make read-only API calls. Treat a new line in that log as a defect in your case. A decoy only proves something when it can be hit: first confirm it records (`DECOY_LOG=$d.log $d/gh x; cat $d.log`).

A case that genuinely needs a container runtime follows the verify cases: test for `podman` or `docker` with `command -v`, run the real runtime against a registry image, and call `noenv "<what> (needs podman or docker)"` on the other branch so the skip is counted and CI, which has docker, runs it. Never make the case pass when the runtime is missing, and never stub the runtime to say yes: a permissive `podman` stub in the shared directory once made a case two hundred lines later report a receipt it never earned (lesson 74).

## 6. Published figures

A number in the README, `CONTRIBUTING.md` or `docs/` that the tree derives is a marker, and a person never types it. The two forms, written here as code spans because a marker inside a code fence fails the check:

- `<!-- fig:NAME -->VALUE<!-- /fig -->` is exact, for a figure only a deliberate act moves.
- `<!-- fig:NAME floor=K -->VALUE<!-- /fig -->` is a rounded floor: `floor(v/K)*K` and a trailing `+`.

`scripts/render_figures.py` holds one counting function per name in `FIGURES` (`tests`, `evals`, `backends`, `denied_verbs`, `lessons`, `stories`, `gaps`, `profiles`) and the floors in `FLOORS`. A marker's floor must equal the registry's, so a test count cannot quietly become an exact figure that goes stale on every pull request. `REQUIRED` lists where each figure must appear, so a site that stops stating its figure fails.

```sh
python3 scripts/render_figures.py --check --no-tests        # verify; the suite cannot know its own count, so the tests marker is checked for structure only
python3 scripts/render_figures.py --write --no-tests        # rewrite stale markers; idempotent
python3 scripts/render_figures.py --values --tests N        # print each name and value
bash scripts/check_claims.sh                                # runs the suite, measures the count, hands it to the renderer
```

`--check` prints one `FAIL file:line: reason` per problem: a stale marker, an unknown name, a malformed or nested marker, a marker inside a code fence, a figure typed outside a marker, a required site that stopped stating its figure, and a source that could not be read. It never skips: a figure whose source cannot be read is a failure.

Add a case and the `tests` count moves. `--check --no-tests` (the hook step) never compares that value; `check_claims.sh` does, and the floor makes it differ only when the count crosses a multiple of 100. Add a lesson, an eval scenario, a profile or a backend, and the exact figure moves, so run `--write --no-tests` and commit the result. A figure typed in prose where a marker belongs fails `--check`; the `BARE` patterns in `render_figures.py` say which phrasings it recognises, and the suite size is policed in the README. `check_claims.sh` counts passed plus skipped cases as the suite size, so a contributor with no container runtime measures the same size the README states.

Do not type a count in a document you write. Point at the command that prints it, or add a name to `FIGURES` with a source function that fails closed on a missing directory, an unparseable file and a count of zero.

## 7. Running the gates locally

CI runs the same gates on every push and pull request, including from a fork. The jobs in `.github/workflows/ci.yml` are `the four gates` (syntax by shebang, the suite twice, the eval rules per profile, README numbers, drift, figures, action pins, relative links), `shellcheck`, `rust` and `powershell`. Locally, the pre-commit hook (`.githooks/pre-commit`; enable it once with `git config core.hooksPath .githooks`) runs these steps in order and reports each failing step by name:

| step | what it protects |
|---|---|
| syntax: every shell script | `bash -n` on each tracked bash script and `ast.parse` on each tracked Python script, chosen by shebang, so a bad edit never reaches the suite |
| offline test suite | `tests/run-tests.sh` at nice 15 |
| eval rules still present, once per profile | `evals/run-evals.sh` asserts that the rule behind each adversarial scenario still exists in that profile's prompts; it does not measure behaviour |
| shellcheck sweep | `scripts/shellcheck-sweep.sh`, at `--severity=warning`, one linter process per script |
| docs match the code | `python3 scripts/check_drift.py`: doc paths, environment variables, CLI verbs, config docs, repository names |
| figures are rendered | `python3 scripts/render_figures.py --check --no-tests` |
| README numbers are derived | `bash scripts/check_claims.sh`, which runs the suite once more |

Run the cheap gates yourself while you work:

```sh
python3 scripts/check_drift.py
python3 scripts/render_figures.py --check --no-tests
bash scripts/check_claims.sh                    # runs the whole suite
```

A local commit runs the suite twice (the suite step and `check_claims.sh`). CI runs it three times: with an empty `HOME`, as it stands, and inside `check_claims.sh`. Expect a commit to take several minutes.

### The machine lock and the memory gate

The suite and the sweep are heavy: `shellcheck` on `tests/run-tests.sh` alone peaked near 8 GB. On 2026-11-09 four worktrees committed at once, two sweeps overlapped, the kernel hit a global out-of-memory and killed the terminal (the 0.11.0 CHANGELOG entry has the story). Two mechanisms stop a repeat:

- **`scripts/with-hook-lock.sh`** serialises the whole hook per machine, across every worktree, with one `flock`. The lock file is `<XDG_RUNTIME_DIR or XDG_CACHE_HOME or ~/.cache>/magent/hook.lock`, in a directory mode 0700 that you own; the script refuses a symlink or a file owned by someone else. It waits silently. `MAGENT_HOOK_LOCK` moves the lock file and `MAGENT_HOOK_LOCK_WAIT` sets the wait in seconds (default 1800). When the wait runs out it exits 75, and any other exit code is the command's own.
- **`scripts/shellcheck-sweep.sh`** waits until `MemAvailable` covers the job (`MAGENT_SWEEP_MIN_AVAIL_KB`, default 10485760 KB, 10 GiB), polling every `MAGENT_SWEEP_POLL` seconds for at most `MAGENT_SWEEP_WAIT` (default 300), and exits 75 if it never does. It then runs one `shellcheck` per script in a systemd user scope with `MemoryMax=12G` (`MAGENT_SWEEP_MEM_MAX`) and no swap, at nice 15, so an overrun kills the linter and nothing else. `MAGENT_SWEEP_NO_CAP` skips the scope. Under `CI` the gate and the cap stand down: a runner is its own sandbox.

When a commit waits, the hook is queued behind another gate run, not hung. Ask the lock: `flock -n "${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}}/magent/hook.lock" true` exits 1 while a run holds it and 0 when nobody does. Before you start a heavy job of your own, check `free -g` (leave at least 12 GB available) and `uptime`. Do not pass `--no-verify`, and do not poll in a tight loop.

### Without systemd, podman, shellcheck or Linux

- **No systemd user scope** (a container, macOS, WSL without systemd): the sweep prints `no memory cap (no systemd user scope on this host)`, still waits on free memory, and runs the linter uncapped. Where `/proc/meminfo` is unreadable (macOS) it says it is not checking free memory.
- **No `flock`** (stock macOS): the hook lock prints `flock is not installed; this run is not serialised with other worktrees` and runs the hook anyway, and the suite records `noenv "hook lock cases need flock"`. Install a `flock` if you run several worktrees.
- **No podman or docker**: the container cases print `SKIP` and the suite exits 0. The skip count is not zero, so CI is where those cases run for you. Every other gate applies in full.
- **No shellcheck**: the sweep exits 127 and says it inspected nothing. This fails the hook on purpose: a linter that reports success when it is absent is how a gate turns green over code nothing inspected. Install it (`apt-get install shellcheck`, `brew install shellcheck`, or the static binary into `~/.local/bin`); CI runs it either way.
- **No `gh`, `claude`, `codex`**: nothing in the suite needs them. They are stubs.

## 8. Rust tests

The workspace is `rust/` with three crates: `mx-core` (`Fact<T>`, `Refusal` with an exhaustive exit-code table, `NonEmpty<T>`; no I/O), `mx-ports` (the `Gh`, `Git`, `Containers`, `Clock`, `Fs` and `Proc` traits, an in-memory fake for each, and `RealProc`) and `mx-receipt` (byte-compatible receipts). Run `scripts/rust-gate.sh` from the repository root before you push anything under `rust/`.

What each step protects:

1. **fmt and clippy with `-D warnings`.** The toolchain is the `rust-version` in `rust/Cargo.toml`, and CI installs that version, so a new clippy lint cannot turn a green `main` red.
2. **`cargo test` with a floor.** The gate sums `test result:` lines. It fails on zero results, on any failed or ignored test (an ignored test reads as green), and on 15 or fewer passed.
3. **The spawn ban.** Only `mx-ports` starts a process. `rust/clippy.toml` lists `std::process::Command::new` under `disallowed-methods`, the workspace lints deny it, and `RealProc` holds the one `#[allow]` with its reason. The gate proves the ban bites: it copies the workspace, checks the clean copy passes clippy (so a refusal can only come from the probe), adds a crate that calls `Command::new`, and demands clippy refuse it with the disallowed-method message.
4. **The allow-scan.** No crate but `mx-ports` may name `disallowed_methods` in a `.rs` or `.toml` file, and every crate manifest has a `[lints]` table with `workspace = true`. An `#[allow]` elsewhere would switch the ban off without touching `clippy.toml`.
5. **Interop.** `rust/crates/mx-receipt/tests/interop.sh` builds a helper, has the bash gate write receipts and `mx-receipt` verify them and write them back to the same bytes, has `mx-receipt` write receipts the gate's own `receipt_check` accepts, and runs controls (an edited, reordered, unsigned or wrong-PR receipt is refused by both sides). It prints `interop: N checks, F failed` and the gate refuses a run that printed no such line or ran no checks.

Write Rust tests the way the shell tests are written: against the fakes in `mx-ports` by default, so a unit test never starts a process; against `RealProc` only in the test that is about `RealProc`. A new refusal in `mx-core` needs an exit code in the table, and a test fails when a code changes. `Fact::Unreadable` never becomes `Fact::Absent`, because a read that failed is not a read that found nothing; a test that reads a fact asserts the unreadable case as well as the absent one (the tests in `rust/crates/mx-core/src/fact.rs` do).

Byte compatibility is tested against golden vectors. `rust/crates/mx-receipt/tests/golden.rs` signs the golden inputs and compares the bytes and the signature with `tests/characterization/golden/receipt-asserted.json`, then feeds the golden receipt to the check and round-trips it. The shell side (`gate-receipt.sh`) checks the same file. A change to the receipt format must change the golden file in one commit with both suites reading it, and the PR must say so.

Touch files before a `cargo` run on a copied tree: cargo decides a crate is fresh when no source is newer than its artifact, and `cp -a` keeps old modification times, so a pristine copy can reuse the previous mutant's build. Check which crates compiled (`cargo build` prints `Compiling`) before you trust a control. `rust-gate.sh` honours `CARGO_TARGET_DIR`, so one warm target directory serves every worktree.

## 9. Reviewing a test

These are the questions a reviewer asks, and a contributor can ask them first.

- **Revert the production hunk. Does this test go red?** If it stays green, it is decorative. The reviewer applies a mutation and so should you (section 4).
- **Which line of the output proves the behaviour?** A test that reads a log should read the line that only the claimed behaviour writes. If a probe logs the same flags as the real call, the test cannot see a missing real call.
- **Is the assertion as strong as the title?** Code and message, by value. Not `!= 0`.
- **Is the new script wired into the suite?** A test file nothing runs is the same as no test. The characterization runner globs five families by file name; a new test of another shape must be called from `run-tests.sh` or the hook.
- **Does it select anything?** A filter, a glob or a loop over a list must assert it matched something.
- **Does it fail for the right reason?** Run it once against the unfixed tree. The failure message should name the missing behaviour, not an unrelated setup error. A test written after the fix that has never been red has not been seen to work.
- **Does it measure the repository or the machine?** Run it with `HOME="$(mktemp -d)"` and, for cases that read the tree, as `MX_TREE=<an exported copy> bash tests/run-tests.sh`.
- **Does the guard have its own test, shaped for the path where only that guard stands between the input and the wrong answer?** When a guard sits behind another guard, the test must pass every outer guard first.
- **Did the author say what they ran?** A pull request that adds a guard states the mutation and the red case it produced. A reviewer who cannot reproduce the red result asks for it.

## 10. Troubleshooting

| symptom | cause | fix |
|---|---|---|
| `git commit` prints nothing for minutes | another gate run holds the machine lock, and `with-hook-lock.sh` waits silently up to 1800 s | wait; ask the lock with `flock -n <lock-file> true`; do not use `--no-verify`. Exit 75 means the wait ran out: retry when the other run ends |
| `sweep: MemAvailable is ... KB and the linter needs ... KB; gave up` (exit 75) | less than 10 GiB free for 300 s | close something heavy and retry, or lower `MAGENT_SWEEP_MIN_AVAIL_KB` knowing a smaller figure can reach the cap |
| `sweep: shellcheck was killed (rc=137)` | the `MemoryMax=12G` scope killed the linter on a large file | raise `MAGENT_SWEEP_MEM_MAX`, and check that nothing else is using the memory the scope counts |
| `shellcheck is not installed, so this gate inspected nothing` (exit 127) | the linter is missing | install shellcheck; the gate never passes without it |
| the figures step fails after you added a case, a lesson, a profile, an eval or a backend | the exact figures moved | `python3 scripts/render_figures.py --write --no-tests`, then commit the changed markers. The `tests` figure is a floor, so a new case alone rarely moves it |
| `check_claims.sh` says `the test suite is RED` | the suite failed before the claims were checked | fix the failing case first; the script prints the first ten `FAIL` lines |
| a case fails under `MX_TREE=<export>` and passes in your worktree | it reads program text, and the tree under test has none the case understands, or it needs `git` | decide whether the case is source-coupled (wrap it in `sc_case N`) or a black-box case that should pass on any tree |
| `git ls-files` cases fail in an exported tree with `no tracked files or no PROD_GLOBS; the check below would be vacuous` and `no production file matched both PROD_GLOBS and suite_covers` | `git archive` and a plain copy have no `.git`, so `git -C "$root" ls-files` prints nothing | use a clone as the tree under test, or run `git init` and `git add -A` in the export. The cases refuse an empty file list on purpose, so they fail instead of scanning nothing |
| a case fails with `<N> profiles are deployed` or `no profile is deployed` | the program read the profiles deployed in your real `HOME`, or a variable the suite unsets | give the case `HOME="$stub_dir"` and set the `MAINTAINER_*` variables it needs |
| the suite passes in your shell and fails in the hook | the hook exports `GIT_DIR` and `GIT_INDEX_FILE`, and a scratch repository wrote to the wrong place | the suite unsets `git rev-parse --local-env-vars` at its top; if a new script runs `git` on a scratch repository, run it under the same unset (lesson 110) |
| `SKIP` lines and a nonzero skip count | no podman, no docker, or no `flock` on this machine | the exit code is 0 and CI runs those cases; to close the gap locally install a runtime |
| `characterization: no bin/maintainer-merge under MX_TREE` or `run-characterization: no such case file` | a wrong `MX_TREE`, or a file name that does not exist | fix the path; an empty run is an error on purpose |
| a mutant run reports `0 passed, N failed` for every case | the mutant does not parse | `bash -n` the mutated file; mutate a whole statement, not half of a continued one |
| a mutant "survived" and you cannot see why | the case is shaped for a different path, or an outer guard refuses first | read the line that refuses; build the input that reaches only the guard under test |
| cargo reuses a mutant's build after you restore | `cp -a` kept old modification times | `find <tree> -type f -exec touch {} +` before every run, and look for `Compiling` |
| the suite fails `a home path leaked into the repository` after you ran `rust-gate.sh` | cargo wrote `rust/target/` inside the tree, and that case greps every file under the tree for your home path, ignored files included | delete `rust/target`, or build outside the tree with `CARGO_TARGET_DIR=~/.cache/magent-target scripts/rust-gate.sh` |
| `rust-gate.sh` reports `FAILED: probe (the clean copy does not pass clippy ...)` | the workspace does not pass clippy on its own, so the probe proves nothing | fix clippy first; the gate runs the clean copy as a control on purpose |
