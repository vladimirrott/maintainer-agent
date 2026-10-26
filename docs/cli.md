# Command reference

Five commands. Everything a person types is here; the subcommands `run.sh` calls
on your behalf are listed at the bottom and are not meant to be typed.

Every command reads the profile named by `MAINTAINER_PROFILE`, and refuses
rather than guessing when more than one profile is deployed. `maintainer --help`
needs no profile: it prints every verb, from the table the command dispatches
on. Defaults and the environment variables are in [Configuration](configuration.md).

## `maintainer`

| command | what it answers |
|---|---|
| `maintainer status` | the front door: which version is deployed, which profile, whether it posts, what ran, what is due, what failed, and what it has spent |
| `maintainer version` | the deployed version and commit, and whether your checkout has moved ahead of it |
| `maintainer run [--show-prompt] <task>` | run one task now, through the same orchestrator the timer uses. `--show-prompt` prints the prompt the run would send and starts nothing |
| `maintainer screen <pr>` | may this pull request be executed on this host? Fails closed on anything it cannot classify |
| `maintainer digest <run-id> [--compact]` | what one run did and what it cost |
| `maintainer audit [run-id\|--all]` | compare a run's report against the transcript of what actually ran |
| `maintainer claims` | who has claimed what, how long they have been quiet, and which claims GitHub cannot see |
| `maintainer offers` | who can be offered an issue, who is over the one-offer rule, and who is free. A hold is read from three places: a maintainer mention, GitHub's assignee, or an open pull request closing it, with the assignee winning. The free list is every past contributor minus everyone holding something |
| `maintainer assign <issue> <user>` | assign an issue and read the assignee list back, refusing to report success when GitHub silently dropped the name. It drops a non-collaborator who has not posted on that issue, returning 200 either way |
| `maintainer release <issue> <user> <reason>` | retract an offer so `offers` stops counting it. It posts a comment carrying the marker `offers` reads, names that one person and refuses a reason naming a second, and reads the comment back before reporting success. A released person who is assigned is unassigned, and the claim label comes off. Prose alone does not retract anything: two offers withdrawn in public on 2026-09-22 still read as live holds, and the campaign that followed was told to hand work to the contributor those phantom holds ruled out. At `POST=off` it rehearses |
| `maintainer offer <issue> <user> <text> [--second]` | offer one issue to one person, on that issue's own thread. It refuses an issue somebody already holds, one an open pull request already closes, one that is reserved, assigned or claimed, and anyone who already holds an open offer, all from the same ledger `offers` prints. It also refuses when the open pull requests cannot be read, and refuses text that names a second person. On 2026-10-01 three offers on sysknife were typed into pull-request reviews, where `holders` cannot see them, and two were offered again within hours to somebody else. The offer is read back before it reports success, and the issue gets the profile's `CLAIM_LABEL`, because GitHub will not assign a fresh issue to somebody who has not posted on it and the label is the only reservation others see. `--second` lets the maintainer give one person another issue when they decide to; the issue-side refusals still hold. At `POST=off` it prints what it would post |
| `maintainer settle` | assign every answered offer to its holder. GitHub accepts the assignment once the holder has posted on the issue, so this is the step that turns an offer into an assignment. Each assignment is read back, and one GitHub dropped is named and makes the command exit non-zero |
| `maintainer stale [days]` | name every hold nobody has touched for `days` days (default `STALE_HOLD_DAYS`, 9): no comment from the holder, no maintainer mention, no open pull request of theirs closing it. Read-only; free one with `release` |
| `maintainer stalled [days]` | name every open pull request whose only open review items are mechanical and whose author has been silent for `days` days (default `FIXUP_QUIET_DAYS`, 10). A pull request is listed only when its `CHANGES_REQUESTED` review is the maintainer's own, ends in a `fixup-items` marker for the current head whose every `kind` is `rebase`, `test-count` or `doc-line`, and no commit, comment, review or thread reply of the author's came after it. Read-only. An unreadable pull request is reported and the command exits non-zero, never skipped as not stalled |
| `maintainer fixup-check <pr>` | the check `maintainer-repo fixup` runs at the current head: prints `state=notice` (the heads-up is due), `state=ready` (the push may follow) and the facts the script needs, or exits 1 with the reason. Also refuses a patch that touches production, `.github/`, anything the screen calls build- or gate-executed, a file the review did not name, or more than `FIXUP_MAX_LINES` lines. Read-only |
| `maintainer holders <issue>` | who the maintainer has pointed at one issue and not released, one handle per line. `maintainer-merge` calls this before merging a PR that closes an issue, so the gate and `offers` share one derivation instead of two |
| `maintainer file-issue --title T --body-file F [--fingerprint FP] [--label L] [--dry-run]` | file one tracker issue for a finding, deduplicated by fingerprint. The only path issue creation takes; a bare `gh issue create` is denied. `--dry-run`, or `POST=off`, rehearses. An unreadable tracker stops it, since it cannot tell whether the finding is already filed |
| `maintainer gc [--dry-run]` | prune logs and drafts past `RETENTION_DAYS`, and PR leases that expired longer ago than that. Never touches `runs/`, `index.md`, a live lease or the run lease |
| `maintainer lease take <pr>... [--ttl D] [--for TEXT]`<br>`lease release <pr>...`<br>`lease check <pr>` | say who is working a pull request, until when, and why, so a timer run and an interactive session never work one blind. A lease is a file under the state directory's `leases/`: holder (`interactive`, or `run:<profile>/<task>` inside a run), note, acquired, renewed, TTL. `take` refuses while another holder's lease is live and names that holder; taking again renews; an expired lease may be taken over and the takeover is printed. Several PRs are all or nothing. `--ttl` is seconds or `10m`, `2h`, `1d` (default `LEASE_TTL_SECONDS`, 3600). `check` exits 0 when the PR is free or yours, 1 when someone else holds it (printing who, why and when it expires), and 2 when the lease file cannot be read, which is never read as free. `release` frees your own lease, or an expired one, and refuses someone else's live one |
| `maintainer log [n]` | the last n lines of the run index (`index.md`), default 10: one line per finished run. A run's own log is under the state directory's `logs/` |

## `maintainer-merge`

The only path to a merge.

| command | what it does |
|---|---|
| `maintainer-merge verify <pr> <sha> <filter> <sed> [suite]` | run the test in a container, apply the mutation, run it again, and record a receipt only if it passed clean and failed mutated. The mutation must reach a file the profile calls production, or the receipt would say a test notices its own edit. `suite` names a `verify.d` suite when the paths do not pick one; see [Verifying](verifying.md) |
| `maintainer-merge verify-deps <pr> <sha>` | the receipt for a pull request that only bumps dependencies or pins: there is no guard to mutate, so the diff is classified and its pins and image digests are checked |
| `maintainer-merge verify-part <pr> <sha> <filter> <sed> <suite>` | one suite's share of a diff no single suite covers. `merge` checks that the parts add up to every production path |
| `maintainer-merge merge <pr>` | merge, if every condition holds. See the table in the README |
| `maintainer-merge show [pr]` | print a recorded receipt |
| `maintainer-merge receipt <pr> <sha> <proof>` | record a human's claim. Refused inside an unattended run, and a run may not merge on one |

## `maintainer-repo`

| command | what it does |
|---|---|
| `maintainer-repo prune [--dry-run]` | delete branches merged into main, local and remote. Never a branch with an open PR |
| `maintainer-repo fixup <pr> [--dry-run]` | finish a stalled pull request's mechanical items on the contributor's own branch. The first call posts one heads-up and pushes nothing; once `FIXUP_NOTICE_DAYS` have passed with the author still silent, the next call works in a scratch clone with no hook run, rebases (a conflict aborts everything) or applies the patch the run wrote, commits as the maintainer with a `Co-authored-by` trailer for the author, pushes (`--force-with-lease` against the checked head when it rewrites) and reads the head back from GitHub before it says it worked. `--dry-run` and `POST=off` print the plan and the diff. Never resolves a conflict, edits `.github/`, touches a claim label, approves or merges |
| `maintainer-repo release-check` | whether a release is owed and which digit moves, read from the CHANGELOG. See [Releases](release.md) |

## `maintainer-doctor`

`maintainer-doctor [--quick]` checks the install by running it: the GitHub
identity, the repository, the scheduler, a real container, and the audit trail.
`--quick` skips the container probe and says that it did.

## `maintainer-mcp`

`maintainer-mcp --tools` lists what it exposes over MCP. See
[Deploying it](deploy/README.md) for the client configuration.

## Called by run.sh, not by you

`start`, `finish`, `abort`, `failed`, `ok`, `run-lease`. They open a run, close
it, record that one produced nothing, write a failure marker and clear it, and
write or remove `leases/run.json`, the label `status` reads beside `run.lock`. `run.sh` calls
them in order; typing them by hand puts the audit trail out of step with what
happened.
