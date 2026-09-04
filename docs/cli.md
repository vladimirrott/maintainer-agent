# Command reference

Five commands. Everything a person types is here; the subcommands `run.sh` calls
on your behalf are listed at the bottom and are not meant to be typed.

Every command reads the profile named by `MAINTAINER_PROFILE`, and refuses
rather than guessing when more than one profile is deployed.

## `maintainer`

| command | what it answers |
|---|---|
| `maintainer status` | the front door: which version is deployed, which profile, whether it posts, what ran, what is due, what failed, and what it has spent |
| `maintainer version` | the deployed version and commit, and whether your checkout has moved ahead of it |
| `maintainer run <task>` | run one task now, through the same orchestrator the timer uses |
| `maintainer screen <pr>` | may this pull request be executed on this host? Fails closed on anything it cannot classify |
| `maintainer digest <run-id> [--compact]` | what one run did and what it cost |
| `maintainer audit [run-id\|--all]` | compare a run's report against the transcript of what actually ran |
| `maintainer claims` | who has claimed what, how long they have been quiet, and which claims GitHub cannot see |
| `maintainer offers` | who can be offered an issue, and who is already over the one-offer rule |
| `maintainer gc [--dry-run]` | prune logs and drafts past `RETENTION_DAYS`. Never touches `runs/` or `index.md` |
| `maintainer log [n]` | the last n lines of the current run's log |

## `maintainer-merge`

The only path to a merge.

| command | what it does |
|---|---|
| `maintainer-merge verify <pr> <sha> <filter> <sed>` | run the test in a container, apply the mutation, run it again, and record a receipt only if it passed clean and failed mutated |
| `maintainer-merge merge <pr>` | merge, if every condition holds. See the table in the README |
| `maintainer-merge show [pr]` | print a recorded receipt |
| `maintainer-merge receipt <pr> <sha> <proof>` | record a human's claim. Refused inside an unattended run, and a run may not merge on one |

## `maintainer-repo`

| command | what it does |
|---|---|
| `maintainer-repo prune [--dry-run]` | delete branches merged into main, local and remote. Never a branch with an open PR |
| `maintainer-repo release-check` | whether a release is owed and which digit moves, read from the CHANGELOG |

## `maintainer-doctor`

`maintainer-doctor [--quick]` checks the install by running it: the GitHub
identity, the repository, the scheduler, a real container, and the audit trail.
`--quick` skips the container probe and says that it did.

## `maintainer-mcp`

`maintainer-mcp --tools` lists what it exposes over MCP. See
[Deploying it](deploy/README.md) for the client configuration.

## Called by run.sh, not by you

`start`, `finish`, `abort`, `failed`, `ok`. They open a run, close it, record
that one produced nothing, write a failure marker and clear it. `run.sh` calls
them in order; typing them by hand puts the audit trail out of step with what
happened.
