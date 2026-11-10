# Trust boundary

magent runs a language model unattended, with a GitHub token, on a machine that
holds other people's keys and projects. What it refuses to do is the product.
This page lists the fifteen refusals a change may not weaken, says where each is
enforced and which test pins it, and describes the deeper review a change to
one of them gets. A pull request that breaks a rule here is rejected on
principle, however good the rest of it is.

If you are new, you will not trip over these by accident. Docs, tests, new
profiles and new verify suites rarely touch a rule. If your change does touch
one, this page tells you what to put in the pull request so the review takes
minutes and not days. The work is welcome: most of what these rules protect was
found by people and agents who read the gate closely.

## Contents

- [How to read a rule](#how-to-read-a-rule)
- [The fifteen rules](#the-fifteen-rules)
- [Changes that touch a rule](#changes-that-touch-a-rule)
- [Duplicated logic that must stay in step](#duplicated-logic-that-must-stay-in-step)
- [Reporting a hole](#reporting-a-hole)
- [What a security fix pull request looks like here](#what-a-security-fix-pull-request-looks-like-here)
- [Checklist to paste into a pull request](#checklist-to-paste-into-a-pull-request)

## How to read a rule

Every rule has the same five parts.

- **The rule** in one sentence.
- **Why it exists**: the incident or lesson that taught it. Lesson numbers
  point into [`docs/lessons.md`](../lessons.md); version numbers point into
  [`CHANGELOG.md`](../../CHANGELOG.md).
- **Enforced in**: the file and function that make it true.
- **Pinned by**: the test that fails when the rule breaks, and what happens to
  that test when the rule's line is deleted. We ran each deletion on a copy of
  the tree at the commit this page was written against and recorded the first
  failing case. Where a deletion left the suites green, the entry says so. A
  rule that is enforced and not pinned is a gap in the tests, and we would like
  the pull request that closes it.
- **A change that breaks it**: a concrete example we would reject.

Two limits apply to the whole page.

1. The deny wall stops a cooperative agent. It does not contain a hostile one.
   Enumerating every spelling of a command is impossible, and `SECURITY.md` and
   the README say so. A spelling that a cooperative agent would plausibly
   type is a bug. A deliberately obscure one is a documented limit.
2. Where a rule rests on a convention that no code enforces, the rule says
   "a convention, not a gate". A convention still binds you. Review reads for it.

The tests live in `tests/run-tests.sh` unless the entry names
`tests/characterization/`. The pre-commit hook runs `tests/run-tests.sh`, the
shellcheck sweep and the drift, figures and claims checks. It does not run
`tests/run-characterization.sh`, and neither does CI. That script holds
the cases that pin what `maintainer-merge` does, so run it yourself
(`bash tests/run-characterization.sh`) whenever a change touches the merge
gate.

## The fifteen rules

### Rule 1: only the gate writes a receipt that counts, and only the gate can sign one

**The rule.** `maintainer-merge merge` spends a receipt only when it recomputes
the receipt's HMAC-SHA256 signature and the result matches, and the signing key
sits where the agent's deny wall refuses every reader.

**Why it exists.** `SECURITY.md` lists forging a receipt first. Receipts were
once unsigned JSON protected by a deny rule on one command, and the wall
generates only `Bash()` and `Read()` rules, so any ordinary write tool could
create `receipts/<pr>.json` with `"kind": "observed"` and merge without a
mutation ever running (the comment above `receipt_sign` tells it). Lesson 49
records the review that found the neighbouring holes.

**Enforced in.**
- `receipt_sign`, `receipt_seal` and `receipt_signature_ok` in
  `bin/maintainer-merge`. The signature covers the receipt body with the
  `signature` field removed, serialised with `json.dump(indent=2)`. Every field
  is covered, including `pr`, `head`, `kind`, `suite` and `proofs`. The file
  name is not covered (see rule 2).
- `install.sh` mints `~/.local/share/maintainer/receipt.key` under `umask 077`
  and sets mode 0600.
- `credential_paths` in every `profiles/*/deny.json` lists the key.
  `scripts/render-settings.py` turns each path into a `Read(~/...)` rule and
  into `cat`, `head` and `tail` rules in the `~/`, `$HOME/` and expanded forms.
  The key sits beside the SSH keys on purpose: a receipt is unforgeable only
  while its key is unreadable.

**What a receipt proves.** At one head, in one container, a named test passed
unmutated with at least one test executed, and failed after a mutation that
landed on production code the pull request changed. It does not prove the
change is correct, that the test is a good test, or (for a `dependency`
receipt) that the new version is good. An `asserted` receipt proves a human
said something.

**Pinned by.** `tests/run-tests.sh`. Replace the comparison
`[ "$sig" = "$want" ] || return 3` in `receipt_signature_ok` with `true` and the
first failure is "a receipt edited after it was signed is refused". Delete
`maintainer-merge receipt` from a profile's `deny.json` and the wall cases fail
with "magent: LOST 'maintainer-merge receipt'" and "magent: no absolute spelling
of 'maintainer-merge receipt'". Two parts have no case: the key's file mode
(changing `chmod 600` to `chmod 644` in `install.sh` leaves both suites green,
and `maintainer-doctor` does not check the mode), and the `Read` rule for the
key is checked only as the string `receipt.key` inside `deny.json`.

**A change that breaks it.** Moving the key into the repository or the state
directory, making `receipt_sign` fall back to a default key when the file is
missing, or loosening the key's mode. A signature check that returns success on
an empty signature breaks it too.

### Rule 2: a receipt names one pull request and one tree

**The rule.** A receipt is valid for the pull request whose number it carries
and for a tree whose production code matches the head it names.

**Why it exists.** The signature covers the receipt's bytes, and the file name
is not in them. `cp 7.json 8.json` produced a receipt that verified and proved
a guard on the wrong pull request, and a docs-only pull request touches no
production path, so the head check waved it through (lesson 49, finding 3.1,
rated blocking). The second half came from lesson 25: the list of production
paths was hardcoded to one project's directories, so on another repository
the comparison compared nothing and reported "receipt still applies".

**Enforced in.**
- `receipt_check` in `bin/maintainer-merge` reads `pr` back out of the signed
  body and refuses when it differs from the pull request being merged.
- `require_prod_globs` refuses a profile with no `PROD_GLOBS`. There is no
  default, because guessing which paths are production was the original bug.
  `profiles/magent/profile.env` sets it.
- `receipt_fresh` compares production paths between the verified head and the
  head being merged. It merges the verified head with the base the branch
  contains and diffs the result, so GitHub's Update branch does not invalidate
  a receipt, while a conflict resolution or any production edit does.
- `receipt_covers` refuses a receipt earned by suites that do not run every
  production path in the diff.

**Pinned by.** `tests/run-tests.sh`. Replace the `pr` comparison in
`receipt_check` with `if false; then` and "a receipt copied onto another PR
number is refused" fails (first failure text: "a receipt earned for #7 was
accepted for #8"). Replace `[ -n "$diff" ]` in `receipt_fresh` with
`if false; then` and "production movement invalidates the receipt" fails.

**A change that breaks it.** Selecting a receipt by file name without reading
`pr`; narrowing `PROD_GLOBS` so `lib/` or `.github/` is no longer production;
replacing the tree-merge comparison with a two-dot `git diff verified..head`.
The comment in `receipt_fresh` explains why that fails: the range holds
everything main gained since the receipt, every Update branch then looks like a
production change, and the way around it was `gh pr merge --admin`, which spends
no receipt at all.

### Rule 3: an unattended run spends only receipts the gate observed

**The rule.** A run started by the timer cannot write an asserted receipt and
cannot merge on one. Only `verify` (which watches a mutation fail) and
`verify-deps` (which checks a dependency bump by rule) produce receipts a
run may spend.

**Why it exists.** An asserted receipt is a human's sentence that a guard
bites, and nothing checks it. An agent that skipped a step can write that
sentence as readily as a true one.

**Enforced in.** `cmd_receipt` refuses when `MAINTAINER_IN_RUN` is set, and
`receipt_check` refuses any kind other than `observed` or `dependency` when it
is set. `lib/run.sh` exports `MAINTAINER_IN_RUN` before the backend starts. The
wall denies `maintainer-merge receipt` in every spelling `render-settings.py`
generates. Those are three layers, and all three stop a cooperative agent. None
is a boundary against an agent that rewrites its own environment.

**Pinned by.** `tests/run-tests.sh`. Replace the `MAINTAINER_IN_RUN` refusal in
`cmd_receipt` with `true ||` and "a run is refused the receipt command" fails.
Replace the `MAINTAINER_IN_RUN` test in `receipt_check` with `if false; then`
and "inside a run an asserted receipt is refused, as merge refuses it" fails.

**A change that breaks it.** Letting `receipt_check` accept `asserted` under
some other condition (a flag, a label, a comment from the maintainer on the
thread); adding a new kind that an unattended run may spend without the gate
having observed its evidence.

### Rule 4: a merge lands at the head that was checked, on a board that says yes

**The rule.** `merge` reads the head commit, refuses when it cannot, and pins
`gh pr merge` to that head. It refuses unless the review decision is
`APPROVED`, `mergeStateStatus` is `CLEAN` or `HAS_HOOKS`, every check is `pass`
or `skipping`, at least one passed, none is failing, pending or cancelled, and
the list is not empty.

**Why it exists.** A merge without `--match-head-commit` lands whatever is
current when `gh` runs, so a push between the last check and the merge goes in
unchecked. The v0.11.0 Security entry records a `gh` failure that left the head
empty and the fence with it. Counting only `fail` and `pending` read a cancelled
check, a bucket `gh` might add next year, and an empty list as green (lesson
112 and the comment above the board count in `cmd_merge`).

**Enforced in.** `cmd_merge` in `bin/maintainer-merge`: the head read (a
lowercase hex id or a refusal), the `reviewDecision` test, the `case` on
`mergeStateStatus`, the board counts read with `python3`, and the final
`gh pr merge ... --match-head-commit "$head"`. `cmd_update` uses the same
receipt functions and exits 3 when only the author can press Update branch.

**Pinned by.** Two suites, and they differ in whether anything runs them.

`tests/run-tests.sh` pins the board and the approval. Replace the
`[ "$total" -gt 0 ]` test and "an empty list is refused as an empty board, which
the README promises" fails. Replace the cancelled-check test and "a cancelled
check is refused: it never reported a verdict" fails. Replace the pending test
and "a pending check is refused, and counted" fails. Replace the
`reviewDecision` test and "merge refuses an unapproved PR" fails.

The head fence and the head read have no case in `tests/run-tests.sh`. Delete
`--match-head-commit "$head"` from the merge call, or turn the malformed-head
refusal into a no-op, and that suite stays green. `tests/run-characterization.sh`
catches both. The fence fails several cases, among them "merge success: gh pr
merge argv carries --squash, --delete-branch and --match-head-commit <head>".
The head read fails "merge: an empty head from a successful read refuses (F9,
fixed)" and "merge: a head that is not a commit id refuses (F9, fixed)".
The pre-commit hook and CI do not run that script. After any change to
`cmd_merge`, run `bash tests/run-characterization.sh` yourself and paste the
summary line in the pull request.

**A change that breaks it.** Treating an empty board as green "because the
repository has no CI"; adding `--admin` to the merge call; reading the head
after the checks instead of before them; accepting `UNSTABLE` as a state that
may merge.

### Rule 5: every write runs as the configured account

**The rule.** The account that writes is `GH_ACCOUNT` from the profile. A run
refuses to start as anyone else, and the gate refuses when it cannot confirm
who it is.

**Why it exists.** `gh`'s active account flipped on its own twice in one
session (lesson 9). A 403 is the lucky outcome. A review under the wrong
identity is not. Lesson 53 records the next step: a start-of-run check cannot
catch a flip that happens after it.

**Enforced in.**
- `lib/run.sh` switches account, reads `gh api user --jq .login`, and exits 1
  on a mismatch or a 401 and 75 (a retryable failure) when GitHub is
  unreachable. It then exports `GH_TOKEN` for the whole run, read from
  `gh auth token --user "$GH_ACCOUNT"`, so no later `gh auth switch` can select
  another account, and it re-reads the login with that token before it goes on.
- `identity` in `bin/maintainer-merge` does the same read before `merge`, and
  `maintainer-repo fixup` and `maintainer file-issue` repeat it.
- The comparison ignores case, as GitHub does, and it uses the exit status of
  `gh`, never the text on stdout: on a 401 `gh` prints a JSON error body to
  stdout.

**Pinned by.** `tests/run-tests.sh`. Replace the account comparison in
`identity` with `true ||` and "merge refuses under the wrong gh account" fails.
Replace the mismatch test in `lib/run.sh` with `if false; then` and the
`gate_test "someone-else"` case fails (first failure text: "gh='someone-else'
exited 1 without saying 'refusing to run'").

**A change that breaks it.** Dropping the second read after the token is
pinned; treating a `gh` failure as "unknown, so continue"; hardcoding an
account name in the tools (the code names none; the profile does).

### Rule 6: a rehearsal reaches nobody

**The rule.** With `POST=off`, a run produces reports and drafts and posts,
merges, pushes, labels and deletes nothing, including through the tools the
agent may call.

**Why it exists.** The wall governs what the agent types. It cannot see what a
script does after the agent starts it. `maintainer-repo prune` pushes branch
deletions from inside a script, `maintainer file-issue` calls `gh issue create`
from inside Python, and each would have posted at `POST=off`. Lessons 63, 65
and 105 are three runs that posted while believing they rehearsed. `SECURITY.md`
notes two holes found in this class.

**Enforced in.**
- `lib/run.sh` exports `MAINTAINER_POST`, picks the rehearsal wall
  (`settings-rehearsal.json`, `opencode-rehearsal.json` or the cursor
  equivalent) through the backend's `backend_rehearsal_wall`, and exits 78 when
  the backend declares no `backend_rehearsal` or no wall is rendered. It also
  writes the posting state into the prompt in both directions, quoting the live
  value.
- `POSTING` in `scripts/render-settings.py` lists every verb the rehearsal wall
  adds on top of the live wall, including `maintainer-merge merge`, `verify` and
  `update`.
- The scripts that post honour the variable themselves: `cmd_merge` and
  `cmd_update` in `bin/maintainer-merge`, `cmd_prune` and `cmd_fixup` in
  `bin/maintainer-repo`, and `file-issue`, `assign`, `release`, `offer`,
  `settle` and `deps rebase` in `bin/maintainer`. In `bin/maintainer` anything
  other than the exact value `on` rehearses (`file-issue` also takes
  `--dry-run`).
- A prompt may describe what `POST=off` does. It may not say which state is in
  force, because only `lib/run.sh` can read that. The suite folds newlines and
  fails a prompt that claims a state.

**Pinned by.** `tests/run-tests.sh`. Remove the `post != "on"` condition from
`cmd_file_issue` in `bin/maintainer` (keep `dry_run`) and "with POST off,
file-issue rehearses rather than posting" fails. For the merge gate, make the
`[ "$POST" = off ]` test in `cmd_merge` never match and the suite goes red, but
at an incidental case ("the gate merged production code the receipt never
covered": the merge cases run the gate at `POST=off`). The purpose-built pins
are the source-coupled case "the merge gate returns before gh pr merge when
POST=off" and the characterization case in
`tests/characterization/gate-merge-path.sh` that expects the line
"POST=off: every condition holds and the merge is NOT being made".

**A change that breaks it.** A new subcommand that calls `gh ... -X POST`,
`git push` or `gh pr merge` from inside a script without a `MAINTAINER_POST`
check; a new write verb that `POSTING` does not list; a prompt sentence that
says "this profile is at POST=off".

### Rule 7: contributor code runs only in the verify container

**The rule.** The only command that executes a contributor's code is
`maintainer-merge verify` (and its `verify-part` form), and it does so only
inside a container started with no network, no capabilities, a read-only root,
no new privileges, and limits on memory, CPUs, processes, time and `/tmp`.

**Why it exists.** `cargo test` runs a stranger's code as this user, and
`build.rs` runs it at compile time. The machine holds SSH keys and other
people's projects. [`docs/containment.md`](../containment.md) has the measured
table and the honest limit: shared-kernel isolation does not stop a kernel
exploit. The timeout line was learned the hard way: `timeout 60 podman run`
kills the client and leaves the payload running, so the limit is podman's own
`--timeout`.

**Enforced in.**
- `run_in_container` inside `cmd_verify` passes `--timeout`, `--network=none`,
  `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--read-only`,
  `--tmpfs /tmp:rw,nosuid,size=...`, `--pids-limit`, `--memory` and `--cpus`,
  and mounts the extracted tree at `/repo`. A suite may add flags through
  `suite_podman_args`. The call passes no `-e` or `--env`, so no host variable
  enters the container. The gate dropped `noexec` from `/tmp` on purpose (the
  comment above `run_in_container` and lesson 71 say why), so read both before
  you add it back.
- `extract_tree` builds the tree with `git read-tree` and `git checkout-index`
  into a private directory under the state directory, and refuses a tree whose
  file count on disk differs from the count git lists. A partial extraction
  once reported the container's network as the cause (the v0.10.1 Fixed entry).
- `tree_escapes` refuses a tree holding a symlink that points outside itself,
  because the mutation step runs on the host.
- The only step that gets a network is `suite_prefetch_command` (for the rust
  suite, `cargo fetch --locked`), which compiles nothing, and the runs that
  execute tests never get one.

**Pinned by.** `tests/run-tests.sh` pins the extraction: make the count
comparison in `extract_tree` always true and "a directory holding a file the
tree does not track is refused" fails. It pins `tree_escapes` as a function
("a symlink to an absolute path outside the tree is reported" and its
neighbours).

Two sites have no case, and this page says so because a rule that looks pinned
and is not is worse than a gap. Replace `if [ -n "$links" ]; then` in
`cmd_verify` with `if false; then` and both suites stay green: nothing checks
that `cmd_verify` refuses a tree with an escaping link. Delete `--network=none`
from `run_in_container` and both suites stay green too. `tests/containment-probe.sh`
builds its own `hardened` call, and its closing "the probe still describes the
real gate" loop greps `bin/maintainer-merge` for each flag, which the comments
above the call also contain. Until a case runs the gate's own call, the reviewer
reads these two sites line by line. A pull request that adds either case is
welcome.

`tests/containment-probe.sh` measures the flags against real attacks. It needs
podman or docker and the suite does not run it, so run it by hand when you
touch a flag.

**A change that breaks it.** Adding `-v $HOME:...`, `--privileged`,
`--network=host` or `--cap-add`; running the clean pass on the host "to save
time"; widening a suite's `suite_podman_args` to pass an environment variable
through.

### Rule 8: the mutation is text, and it lands on what the pull request changed

**The rule.** The `sed` expression a verify applies is a plain text transform.
It must change at least one file, at least one production file, and at least
one of the production files the pull request changed.

**Why it exists.** The expression comes from the agent and reaches host `sed`,
where GNU `e`, `w` and `r` run shell and touch arbitrary files (lesson 49,
finding 3.4). A mutation that matches nothing leaves the tree unchanged, and
the mutated run then passes for the gate's own reason and reads as "the guard
does not bite". A suite's mutation glob is a file type and not a trust
boundary: a mutation of the contributor's own test earns a receipt that proves
a test notices its own edit (lesson 99), and a mutation of an unrelated
production file speaks for a change nothing there broke (the v0.11.0 Security
entry).

**Enforced in.** `apply_mutation` runs `sed --sandbox -i` over files matched by
`suite_mutate_glob`, hashes them before and after, and prints the changed paths.
`cmd_verify` then refuses a mutation that changed nothing, that landed only
outside `PROD_GLOBS`, or that landed on production code the diff did not touch.
A container that was killed (memory or time) is reported as that, never as a
guard that bites.

**Pinned by.** `tests/run-tests.sh`. Replace the mutation-on-the-diff test in
`cmd_verify` with `false` and "a mutation of production code the pull request
did not change earns no receipt" fails. The `--sandbox` flag is pinned by a
source-coupled case that greps for it ("the host-side mutation runs sed in
--sandbox mode"), because the execution path needs a real container run: remove
`--sandbox` from `apply_mutation` and that case fails with "the mutation runs
sed without --sandbox, so an e-flag mutation execs on the host". A grep proves
the flag is in the file and does not prove the call runs.

**A change that breaks it.** Dropping `--sandbox` to let a contributor's
mutation use `s/x/y/w out`; counting a mutation of `tests/*` as a hit; treating
a non-zero exit from a killed container as a red test.

### Rule 9: `screen` fails closed, and says so when it could not look

**The rule.** `maintainer screen <pr>` answers `DO NOT EXECUTE` for any diff
that touches executable content or that it cannot classify, and it answers a
second question on every verdict: whether the pull request's queued workflow run
may be approved.

**Why it exists.** A screen that errs toward safe launders an unknown into a
reassurance. The workflow-run answer exists because approving a fork's run lets
a fork's code execute in CI with this repository's permissions. sysknife#527
arrived as one clean lockfile commit on a branch that had been force-pushed
over a commit editing `.github/workflows/ci.yml` (lesson 100). Lesson 49 also
records `maintainer screen` calling a hostile `package.json` inert (finding
3.3).

**Enforced in.** `cmd_screen`, `_screen_blocks` and
`_report_workflow_exposure` in `bin/maintainer`. A `gh` read that fails raises
instead of printing a verdict. A path the screen cannot classify as inert
raises "failing closed". A truncated file list adds a block. The force-push
history is read from workflow runs, and when it cannot be read the output says
to treat the approval as unsafe.

**Pinned by.** `tests/run-tests.sh`. Replace `if len(inert) != len(paths):` in
`cmd_screen` with `if False:` and "an unclassifiable file fails closed" fails.

**A change that breaks it.** Adding a file suffix to the inert list without
reading what runs it; catching a `gh` failure and printing `INERT`; answering
the workflow question from the head's file list alone.

### Rule 10: the deny wall is generated, spelled from everywhere, and a new capability gets a deny entry first

**The rule.** The wall is rendered from each profile's `deny.json` by
`scripts/render-settings.py`. A verb is written once and comes out spelled with
every prefix a shell would accept. A change that gives the agent a new
capability adds the deny entry (or the explicit allow in the opencode config)
in the same pull request, first in the commit order.

**Why it exists.** The wall was once 40 hand-listed rules, and
`/usr/bin/touch /tmp/mt-y` succeeded against a rule denying `touch /tmp/mt-y`
(lesson 6). `./install.sh --uninstall` turned off every timer on the machine
because no rule matched the spelling `./` (lesson 36). A single leading slash in
a `Read` rule anchors to the settings directory, so `Read(/home/you/.ssh/**)`
denies nothing (lesson 14).

**Enforced in.** `scripts/render-settings.py`: `STATIC_DIRS`, `HOME_DIRS` and
the directories the verbs resolve to on this machine; the `~/` form for
credential paths; refusal to write a wall with no `Read(~/` rule; refusal when
the receipt command lacks its absolute spelling; refusal when `deny.json`
contains a literal home path. `install.sh` renders the wall at install time, so
the rendered files are not committed.

**Pinned by.** `tests/run-tests.sh`. Remove `"./"` from `STATIC_DIRS` and
"./install.sh --uninstall walks past the wall that names it", "a copied binary
run as ./curl is not denied" and "sh ./install.sh --uninstall walks past" fail.
Remove the `git push` verb from a profile's `deny.json` and "magent: LOST 'git
push'" and "magent: no absolute spelling of 'git push'" fail.

Four parts of this rule have no failing case: the generator's refusal to write a
wall with no `Read(~/` rule, its refusal when the receipt command lacks its
absolute spelling (replace either `if` with `if False:` and both suites stay
green), the opencode config's `*maintainer-merge receipt*` deny pattern (delete
it and both suites stay green), and the `/usr/bin/` entry of `STATIC_DIRS`
(removing it changes nothing on a machine where `gh` lives in `/usr/bin`,
because the generator also adds the directory each verb's binary resolves to).
Several cases check `deny.json` with `grep -q '<verb>'`, which proves the verb
is in the source file and says nothing about the rendered rules. Read the
rendered wall when you change the generator.

**A change that breaks it.** Hand-editing a rendered `settings.json`; adding a
tool or backend with no entry in `deny.json`; "tidying" `Read(~/` to
`Read(/home/...)`; adding a verb that publishes (`cargo publish`,
`npm publish`, `git tag`, `gh release`) to an allow list.

### Rule 11: no secret travels where a child can print it, and none outlives the run

**The rule.** A credential is never placed in an argument vector, never printed,
and never left in a file the run wrote. The run exports its pinned token to its
own children on purpose, so the guard sits on the way out: the run scrubs the
token from everything it left behind.

**Why it exists.** On 2026-09-09 a run wrote `${GH_TOKEN:+yes}${GH_TOKEN:-no}`.
The `:-` arm expands to the value when the variable is set, so the live token
landed in two session transcripts (lesson 70). No deny rule can enumerate the
commands that print an environment variable. Lesson 82 records the scrub that
had never once run: the trap called a function the file never sourced, and
`|| true` turned "command not found" into success.

**Enforced in.**
- `scrub_pinned_token` in `lib/run.sh`, installed with `trap ... EXIT`, calls
  `maintainer_scrub_secret` from `lib/profile.sh` over the state directory and
  the Claude session directory for the repository. The secret reaches the
  scrubber through `MAINTAINER_SCRUB_NEEDLE`, never argv, because `/proc`
  exposes argv to every process of the same user. A needle shorter than 16
  bytes is refused, because it would rewrite every file it walks.
- `printenv`, bare `env`, `gh auth token`, `curl`, `wget` and `nc` are in
  `deny.json`.
- `maintainer-doctor` looks for the token on disk from the other end.
- The verify container receives no host environment (rule 7).

**Pinned by.** `tests/run-tests.sh`. Delete `trap scrub_pinned_token EXIT` from
`lib/run.sh` and "run.sh's EXIT trap really removes the pinned token from what
the run left behind" fails. That case runs the real `lib/run.sh` against a
planted token, which is the shape lesson 82 asks for. The scrubber's own cases
sit beside it in `tests/run-tests.sh`, including one that fails a scrubber which
passes the secret in argv.

**A change that breaks it.** Passing a token as a command-line argument, even to
"our own" helper; logging the environment for debugging; removing the `EXIT`
trap because the run "already cleans up"; a test that greps `lib/run.sh` for the
function's name instead of running the trap (lesson 82).

### Rule 12: a fact that could not be read refuses

**The rule.** When a read fails or comes back empty where an answer was
required, the tool stops, names what failed, and does nothing. It never reads
the empty result as permission.

**Why it exists.** This shape of defect recurs in the repository. An unreadable
head removed the merge fence. An empty check list read as green. A
`maintainer holders` that refused for want of a profile read as "nobody holds
this issue", and the merge gate sailed past its claim check. A rejected token printed a JSON error body
that the run read as a login (lesson 108). A screen that goes quiet when it
could not ask is the one failure that command exists to avoid.

**Enforced in.** By hand, at each site. The reads in `cmd_merge` (head, review,
author, closing issues, holders, labels, assignees, check board), `cmd_update`
(`update_facts`, `update_approved_by_me`, which returns 2 for "could not read"),
`receipt_covers` (an empty file list), `lease_gate` (rule 13), `cmd_screen` and
`_force_pushed_workflow_commits`. This rule is a convention, not a gate: no
test enumerates every read. The way to hold it is the test shape in the
checklist below.

**Pinned by.** Per site. The characterization cases in
`tests/characterization/gate-merge-path.sh` stub `gh` to fail and expect a
refusal ("could not read the head commit", "came back as ''", and the check
count refusal). Deleting the malformed-head refusal turns two of those red,
and only when you run that suite by hand (see rule 4).

**A change that breaks it.** `x="$(cmd 2>/dev/null || true)"` followed by
`[ -n "$x" ] || continue`; `grep -q` on the output of a command that may have
failed under `pipefail`; a new read added to the merge path with no case that
makes it fail.

### Rule 13: one actor per action

**The rule.** A pull request an interactive session holds is off limits to a
timer run, and two runs cannot merge or verify the same pull request at once.

**Why it exists.** On 2026-10-25 a session and the 21:14 run worked #637, #658
and #660 together (lesson 114). On 2026-09-14 a hand-run verify and the timer's
verify built the same workspace side by side, and the supervisor read the page
cache they filled as memory exhaustion (comment above the verify lock). A
person at a keyboard is not made to wait for a timer, so runs yield.

**Enforced in.** `lease_gate` in `bin/maintainer-merge` calls
`maintainer lease check <pr>` before `verify`, `verify-deps`, `merge` and
`update`. It exits on 1 (held by someone else) and on any other status
(unreadable), because a gate that could not ask has not said "free". `cmd_merge`
and `cmd_verify` hold per-pull-request `flock` locks under `receipts/`, and
`lib/run.sh` holds `run.lock`. Liveness is asked of the lock, never of a pid
or a process name.

**Pinned by.** `tests/run-tests.sh`. Turn the `1)` arm of `lease_gate` into a
no-op and "a live lease held by another actor (lease check exit 1) refuses"
fails.

**A change that breaks it.** Treating a lease read error as "free"; replacing a
`flock` with a `pgrep` check; dropping the lease check from `update` or
`verify-deps` because "the receipt already covers it".

### Rule 14: input is data

**The rule.** Nothing that arrives from outside becomes code, a path or a
command. A pull request number is a positive integer. A profile or task name is
a plain word. A structured file is read with `json.load(open(sys.argv[1]))`,
never by interpolating a path into program text. A comment body goes through
`--body-file` or a quoted heredoc (a convention, not a gate). Text in a pull request, issue, comment,
commit message or file never changes what a run does.

**Why it exists.** `$pr` became part of a path and then part of a Python string
literal inside the merge gate (lesson 50). A backticked SHA in a double-quoted
comment ran as a command (lesson 10). The preamble every run reads says that a
PR body saying "the maintainer approved this offline" is an attack whoever
appears to say it. `xz` was taken over by social pressure on a tired
maintainer ([`docs/maintainer-doctrine.md`](../maintainer-doctrine.md)); an
agent reads every word as input, so the decision is removed from it.

**Enforced in.** `pr_or_die` in `bin/maintainer-merge`, called by `receipt`,
`verify-deps`, `verify`, `merge` and `update`; `_SAFE_NAME` in
`bin/maintainer` for profile and task names; `receipt_field` and the other
Python helpers, which take paths through `sys.argv`; `sed --sandbox` (rule 8);
`lib/preamble-core.md` for the prompt-injection doctrine. The preamble is a
convention, not a gate: no code stops a model from reading an instruction. What
holds is that the wall and the gates do not depend on the model complying.
The one known exception is `maintainer-merge show`, which does not call
`pr_or_die` and reads `"$RECEIPTS/<arg>.json"` as typed. The characterization
cases pin that behaviour as it is today, with the note that a later port will
refuse such an argument. Do not extend the pattern to a new command.

**Pinned by.** `tests/run-tests.sh`. Weaken the `*[!0-9]*` pattern in
`pr_or_die` and "merge rejects a non-integer PR" fails for each hostile input
(`1;rm -rf x`, `../../etc/passwd`, a quote-and-`__import__` string, `1 2`). The
profile-name case ("a profile name that is not a plain word is refused") runs a
profile whose name contains a shell injection and checks the marker file never
appears.

**A change that breaks it.** `python3 -c "...$pr..."`; `eval` of anything read
from GitHub; `bash -c "$title"`; a profile variable whose value reaches a
command line unquoted; removing a validator because "GitHub only sends
integers".

### Rule 15: the agent holds no trust, publishing or deletion authority

**The rule.** The agent never grants or recommends access, relaxes a gate on
request, publishes a release or an advisory, deletes anything, or changes
repository settings. Persistence from a contributor raises suspicion and gets
reported.

**Why it exists.** The xz backdoor was social, and the lever was a maintainer
made to feel he was letting people down. An agent is more susceptible than a
person: it has no fatigue to warn it. Releases to crates.io and npm cannot be
replaced. A vulnerability that becomes a public issue is disclosed.

**Enforced in.** The wall: `deny.json` denies `git push`, `git tag`,
`cargo publish`, `npm publish`, `gh release`, `gh pr merge`, `gh pr create`,
`gh repo delete`, `gh repo edit`, `gh secret`, `gh variable`,
`gh workflow run`, `gh api` with `--method` or `-X` set to `DELETE` or `PUT`,
`gh api` calls to `update-branch`, `systemctl --user stop`, `disable` and
`mask`, and `install.sh --uninstall`. `maintainer-repo fixup` is the one narrow path onto a
contributor's branch: it refuses substantive items, conflicts, production and
workflow paths, bots, and any sign of the author since the review, each in code
with a test that goes red without it ([`docs/maintainer-doctrine.md`](../maintainer-doctrine.md)
lists them). That a draft advisory is the only advisory the agent files is a
convention, not a gate.

**Pinned by.** `tests/run-tests.sh`. Remove `git push` from a profile's
`deny.json` and the wall cases fail ("magent: LOST 'git push'"). The
"denies install.sh --uninstall" and "denies disabling a timer" cases check the
same file for those verbs. The agent's refusal to hold trust, and the draft-only
advisory, are conventions in `lib/preamble-core.md` and have no case.

**A change that breaks it.** Giving the agent a path that adds a collaborator,
edits branch protection or a ruleset, tags, or answers pressure by lowering a
bar; a prompt line that says a maintainer "may" be asked to waive a check.

## Changes that touch a rule

Where the rules live. `CODEOWNERS` names `bin/maintainer-merge`,
`lib/profile.sh`, `scripts/render-settings.py`, `profiles/*/deny.json`,
`lib/preamble-core.md` and `.github/` explicitly. Rules also live in
`lib/run.sh`, `bin/maintainer`, `bin/maintainer-repo`, `lib/backends/*.sh`,
`profiles/*/opencode.json`, `profiles/*/verify.d/*.sh`, `install.sh`,
`platform/*` and the characterization cases under `tests/characterization/`.
Treat a change to any of these as a change to a rule.

What the review does that it does not do for a docs change.

1. **It mutates the guard.** The reviewer deletes the guard's line in a copy
   of the tree, runs the named test, and watches it go red. For the merge
   gate this is `maintainer-merge verify` itself: a test filter and a `sed`
   mutation, run twice in the container. A guard whose test stays green with the
   line deleted is not yet a guard, and the review stops there.
2. **It traces to a live path.** The reviewer checks that the real entry point
   reaches the guard. A test that greps a file for a function name proves the
   name is in the file (lesson 82), and a test that exits 1 on a refusal produced
   eleven steps before the guard proves nothing about it (lesson 45). Expect a
   request to drive the real program with a stubbed `gh` and read the exit code
   and the message.
3. **It reads both copies of anything duplicated.** The next section lists
   them.
4. **It makes each read fail.** For a new read, the reviewer stubs the command
   to exit non-zero and to print nothing, and expects a named refusal.
5. **It checks the `CHANGELOG.md` entry.** A security fix names what was wrong,
   how it was found, and what now refuses. The maintainer rolls the changelog
   at release, so propose the text in the pull request body.
6. **It reads the proof for the bound.** The pull request says what the change
   cannot stop.

What to put in the pull request body so this takes minutes.

- The rule number (or numbers) the change touches, and the line that enforces
  it.
- The test that pins it and the case label.
- The mutation you ran: the exact edit and the first failing line it produced.
  Run the edit on a copy, restore from a pristine copy rather than with
  `git checkout`, and run the pristine tree again afterwards to show the restore
  worked.
- How you proved the real entry point reaches the guard.
- Every duplicated copy you changed or checked.
- What the change does not stop.

If you are unsure which rule a change touches, ask in the pull request. We
would rather answer the question than review a guess.

## Duplicated logic that must stay in step

A second copy of a rule is a copy that goes stale. These are the places the
repository keeps two, and how each is compared today.

| What | Copies | Check that compares them |
|---|---|---|
| Which verbs the agent may not run | `profiles/magent/deny.json`, `profiles/sysknife/deny.json`, `profiles/_template/deny.json` | None compares the three against each other. The suite loops over `profiles/*/deny.json` and checks each one. At the commit this page was written against, the three `spelled_everywhere` lists were identical. A change to one profile's list is a change to the other two unless the pull request says why not. |
| The same verbs for the opencode backend | `deny.json` and `profiles/*/opencode.json` (default deny, an allowlist, then deny patterns; the three files are byte-identical today) | Partial: a probe of commands against the sysknife config, and the `update-branch` probes in every profile. Nothing checks that every verb in `deny.json` has a counterpart. The reviewer reads both files. |
| The same verbs for the cursor backend | `deny.json` and the `cursor/cli-config.json` that `render-settings.py` writes | Generated from the same `deny.json`, so they cannot drift unless the generator is edited. |
| Verbs the rehearsal adds | `POSTING` in `scripts/render-settings.py` and the `POST` checks in `bin/maintainer`, `bin/maintainer-merge` and `bin/maintainer-repo` | The rehearsal cases in `tests/run-tests.sh`. A new write verb needs both: a line in `POSTING` and a check in the script that performs it. |
| The posting default | `${MAINTAINER_POST:-on}` and `[ "$POST" = off ]` in the two bash programs; `_setting(..., "off")` and `post != "on"` in `bin/maintainer` | Nothing compares them. The bash programs rehearse only on the exact value `off`; `bin/maintainer` posts only on the exact value `on`. Keep the two directions in mind when you add a value. |
| Receipt checks in merge and update | `receipt_check`, `receipt_covers`, `receipt_fresh` | One implementation, called by both on purpose. Do not copy them. |
| Receipt format | `bin/maintainer-merge` (bash and an inline Python writer) and the Rust crate `mx-receipt` | `rust/crates/mx-receipt/tests/interop.sh` runs both directions against the real gate, with controls the gate must refuse (edited, reordered, unsigned, copied to another pull request, asserted under a run). The golden key and vector are under `tests/characterization/golden/`. |
| Exit codes and refusal text | the bash programs and the `Refusal` table in `rust/crates/mx-core/src/refusal.rs` | During the migration, `tests/diff/record.sh` and `compare.sh` record argv, exit code, stdout, stderr and state for both trees and diff them. The migration plan decides which differences are intended. Do not infer that the two tables match. |
| Profile values read by shell and by Python | `lib/run.sh` and the tools source `profile.env`; `_profile_env` in `bin/maintainer` sources it again and reads an allowlist (`keys`) | A suite case cross-checks every key `bin/maintainer` reads from `_ENV` against that tuple. A new profile variable the Python side needs must join the tuple. |
| Which paths a suite runs and mutates | `suite_covers` and `suite_mutate_glob` in each `profiles/*/verify.d/*.sh` | A suite case checks them against the repository's own tracked files. |
| The container flags | the `run_in_container` call in `bin/maintainer-merge`, the table in [`docs/containment.md`](../containment.md), and `tests/containment-probe.sh` | The probe is run by hand. The table and the probe still list `noexec` on `/tmp`, which the gate dropped on purpose (rule 7). |
| The doctrine | `lib/preamble-core.md`, each `profiles/*/prompts/common-preamble.md`, and [`docs/maintainer-doctrine.md`](../maintainer-doctrine.md) | `lib/run.sh` declares the posting state, and a suite case fails any prompt that claims one. Nothing else compares the three. |

When you change one copy, name the others in the pull request and say whether
you changed them.

## Reporting a hole

A hole in a refusal is never a public issue. That includes a pull request, a
comment or a discussion post that describes how to get past one. Report it
privately through the vulnerability reporting form that `SECURITY.md` names;
that file also gives a contact address for when the form is unavailable.

`SECURITY.md` defines what counts. In our words: anything that lets an agent, or
a contributor's pull request, reach past a refusal. The cases that matter most
are forging a receipt or reaching `merge` without one, a spelling a cooperative
agent would plausibly type that the wall does not cover, a rehearsal that
reaches GitHub, executing contributor code that `screen` should have refused,
prompt injection that changes what a run does, and anything that reads a
credential. A deliberately obscure spelling the wall misses is a documented
limit and not a vulnerability. A poor review by the agent is wrong and not a
vulnerability. Anything that needs write access to the state directory already
has it by design.

Include the command or fixture, what happened, what should have happened, and
the commit. A shell transcript with the secrets removed is worth more than a
description. Expect an acknowledgement within a few days: this is a small
project with two maintainers and no paid on-call, and we say so instead of
promising an hour.

What we do next: acknowledge, reproduce, write the failing test first, fix it,
and say in the release notes what was wrong. Every fix ships with a mutation
that turns the new test red. The agent that maintains this repository files a
draft advisory when it finds one and says in public only that the rest is
handled privately. It never publishes an advisory.

If you have a fix, keep it in the private thread with the reproduction until we
have agreed how to release it.

## What a security fix pull request looks like here

The two Security entries in v0.11.0 (`CHANGELOG.md`, change #216) are the
worked example. Both went through the same four steps.

**1. The failing test first.** The unreadable head was found
while writing characterization cases for the merge gate: a `gh` that failed
when the gate read the head left it empty, and the merge ran with
`--match-head-commit ""`, which removes the fence between the last check and
the merge. The off-diff mutation was found
by an automated review of the commit that added the production check: the check
asked whether the mutation hit production code and never whether it hit the
diff, so a mutation of any other production file earned a receipt.

**2. A fix at the narrowest layer.** The merge reads the head first and refuses
unless it looks like a commit id (`cmd_merge`). The verify refuses a mutation
that lands on production code the pull request did not change, and the refusal
names the mutated file and the production files the pull request changed
(`cmd_verify`).

**3. A pin that bites.** The head fix is pinned by the characterization cases in
`tests/characterization/gate-merge-path.sh` (the label "merge: a head that is
not a commit id refuses (F9, fixed)" and the two beside it). The mutation fix is
pinned by the case "a mutation of production code the pull request did not
change earns no receipt" in `tests/run-tests.sh`. We deleted each fix on a copy.
Deleting the off-diff check turns cases in `tests/run-tests.sh` red. Deleting
the head refusal turns characterization cases red and nothing in
`tests/run-tests.sh`, so the step "a pin that bites" holds for it only when
someone runs `tests/run-characterization.sh`.

**4. An entry that says what was wrong.** The changelog names the defect, how it
was found, and the exact refusal that now exists. It does not say the code is
now safe. Lessons 117 and 119 show the same pattern: a hole found by reading, or by a
review briefed to break the boundary, a test that fails against the shipped
code, and then the fix.

A good security pull request is small, names its rule, shows the red line, and
says what it still cannot stop. We will thank you for it in the release notes.

## Checklist to paste into a pull request

Paste this into the body of any pull request that touches a rule above. Delete
lines that do not apply and say why.

```markdown
### Trust-boundary checklist

- [ ] Rule(s) touched: <numbers from docs/contributing/trust-boundary.md>
- [ ] The line that enforces it: <file:function>
- [ ] The test that pins it: <file and case label>
- [ ] Mutation: I deleted <the line> in a copy of the tree, ran <test>, and it
      failed with: <first failing line>. I restored from a pristine copy and the
      pristine tree passes.
- [ ] The real entry point reaches the guard: <command, stub, exit code, message>
- [ ] A read this change adds or changes refuses when it fails and when it
      returns nothing: <the cases>
- [ ] Duplicated copies changed or checked: <deny.json x3, opencode.json x3,
      POSTING, other>
- [ ] No secret in argv or in what a run leaves behind; no new command prints
      the environment
- [ ] A new verb, tool or backend has its deny entry (or allowlist decision) in
      this pull request
- [ ] A new write path honours MAINTAINER_POST and is in POSTING
- [ ] Contributor code still runs only in the verify container
- [ ] What this change does not stop: <the bound>
- [ ] CHANGELOG text proposed (Security section if it closes a hole)
- [ ] `bash tests/run-characterization.sh` passes (required when the change
      touches `bin/maintainer-merge`; the hook and CI do not run it)
- [ ] `python3 scripts/check_drift.py`, `python3 scripts/render_figures.py
      --check --no-tests` and `bash scripts/check_claims.sh` pass
```
