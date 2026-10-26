# Configuration

Every tunable has one default, in [`lib/defaults.env`](../lib/defaults.env), with a
comment saying what it does. Four layers decide the value, highest first:

1. **An environment variable**, `MAINTAINER_<KEY>`, for one invocation:
   `MAINTAINER_VERIFY_MEMORY=8g maintainer-merge verify ...`
2. **A suite's own declaration**, for the `VERIFY_*` resource keys only. A file in
   `profiles/<name>/verify.d/` may define `suite_memory`, `suite_cpus`,
   `suite_pids` or `suite_tmpfs`, because the suite knows what its build needs.
   The sysknife rust suite declares `suite_memory` (6g) and `suite_jobs` (4)
   side by side: each cargo job is a rustc holding about a gigabyte while it
   links, so the two move together.
3. **The key in a profile's `profile.env`**, to change it for that profile.
4. **`lib/defaults.env`.**

A profile does not need to declare any of these. `maintainer-doctor`, `run.sh`,
`maintainer-merge`, `maintainer`, `maintainer-mcp` and the backends all read the
same file, so a number is changed in one place.

| key | default | what it bounds |
|---|---|---|
| `VERIFY_MEMORY` | 2g | container memory for a verify run (fetch, clean and mutated) |
| `VERIFY_CPUS` | 2 | CPUs for the clean and mutated runs |
| `VERIFY_PIDS` | 512 | process limit inside a verify container |
| `VERIFY_TMPFS` | 256m | size of the `/tmp` tmpfs inside a verify container |
| `VERIFY_TIMEOUT` | 1800 | seconds one clean or mutated container may run |
| `PREFETCH_TIMEOUT` | 900 | seconds the networked dependency fetch may run |
| `MCP_VERIFY_SLACK` | 300 | seconds added to the MCP verify deadline, which is `2 x VERIFY_TIMEOUT + PREFETCH_TIMEOUT + slack` |
| `LOCK_WAIT` | 3600 | seconds a run waits for the shared lock. Keep it below the unit's `TimeoutStartSec` (10800): the wait spends that budget, and the test suite fails if it reaches it |
| `RETENTION_DAYS` | 90 | days `maintainer gc` keeps logs and drafts. `runs/` and `index.md` are never pruned |
| `CLAIM_STALE_DAYS` | 7 | days of silence after which `maintainer claims` marks a claim stale |
| `STALE_HOLD_DAYS` | 9 | days of silence after which `maintainer stale` names a hold |
| `GH_LIST_LIMIT` | 1000 | rows requested from a gh list that must be complete. A listing exactly this long is refused, because gh cuts silently at the limit |
| `CONTRIBUTOR_WINDOW` | 300 | merged pull requests read to find past contributors. A recency window, so filling it is not an error |
| `GH_TRIES` | 3 | attempts `run.sh` makes to reach GitHub before recording an exit-75 failure |
| `GH_BACKOFF` | 20 | seconds between those attempts |
| `RED_GRACE_HOURS` | 6 | hours `main` may stay red before `maintainer-doctor` fails |
| `DOCTOR_RUN_LIMIT` | 40 | workflow runs `maintainer-doctor` reads to decide whether `main` is red |
| `DENY_WALL_MIN_RULES` | 100 | fewest rules a rendered deny wall may hold before the doctor calls it stale |
| `OPENCODE_MODEL` | groq/openai/gpt-oss-120b | model the opencode backend uses when the profile names a Claude model |

Adding a key: put it in `lib/defaults.env` with a comment, add a row here, and read
it through `$KEY` in bash (after `maintainer_load_defaults`) or `_tunable("KEY")`
in `bin/maintainer`. Never write the number at the call site.
