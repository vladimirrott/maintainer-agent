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
| `REPORT_MIN_LINES` | 3 | non-empty lines a run report needs below its heading before `finish` indexes it; `lib/preamble-core.md` asks a quiet run for exactly this many |
| `CLAIM_STALE_DAYS` | 7 | days of silence after which `maintainer claims` marks a claim stale |
| `STALE_HOLD_DAYS` | 9 | days of silence after which `maintainer stale` names a hold |
| `FIXUP_QUIET_DAYS` | 10 | days an author must be silent after a review before `maintainer stalled` lists the pull request and `maintainer-repo fixup` may act on it |
| `FIXUP_NOTICE_DAYS` | 5 | days between the heads-up comment and the fixup push. Covers the slowest comment reply seen on sysknife (4.0 days) |
| `FIXUP_MAX_LINES` | 20 | most lines, added plus deleted, a fixup patch may change. Five times the 4 lines each past test-count edit changed |
| `GH_LIST_LIMIT` | 1000 | rows requested from a gh list that must be complete. A listing exactly this long is refused, because gh cuts silently at the limit |
| `CONTRIBUTOR_WINDOW` | 300 | merged pull requests read to find past contributors. A recency window, so filling it is not an error |
| `GH_TRIES` | 3 | attempts `run.sh` makes to reach GitHub before recording an exit-75 failure |
| `GH_BACKOFF` | 20 | seconds between those attempts |
| `RED_GRACE_HOURS` | 6 | hours `main` may stay red before `maintainer-doctor` fails |
| `DOCTOR_RUN_LIMIT` | 40 | workflow runs `maintainer-doctor` reads to decide whether `main` is red |
| `DENY_WALL_MIN_RULES` | 100 | fewest rules a rendered deny wall may hold before the doctor calls it stale |
| `LEASE_TTL_SECONDS` | 3600 | seconds a `maintainer lease take` holds a pull request when `--ttl` is not given. An unrenewed lease frees itself after this long |
| `DOCTOR_LEASE_HOURS` | 12 | hours since a lease was last renewed before `maintainer-doctor` warns that it was forgotten |
| `OPENCODE_MODEL` | groq/openai/gpt-oss-120b | model the opencode backend uses when the profile names a Claude model |
| `DEPS_AUTOMERGE` | minor | which green Dependabot bumps `maintainer deps` sends to `verify`: `none`, `patch` (every member semver-patch) or `minor` (patch or minor). A semver-major member always goes to a person |
| `DEPS_UNKNOWN_READS` | 3 | reads `maintainer deps` makes of a merge state GitHub answers `UNKNOWN`, before it reports it |
| `DEPS_UNKNOWN_WAIT` | 5 | seconds between those reads |

Adding a key: put it in `lib/defaults.env` with a comment, add a row here, and read
it through `$KEY` in bash (after `maintainer_load_defaults`) or `_tunable("KEY")`
in `bin/maintainer`. Never write the number at the call site.

One profile key has no default and is not in that file: `FIXUP_COUNT_CMD`, a
command that prints the profile's test count, run in the scratch clone by
`maintainer-repo fixup` so that a `test-count` item is derived and never typed.
It must count statically (`grep -c`, `find | wc -l`), because it runs over a
contributor's tree: a command that builds or runs their tests runs their code.
With it unset, a `test-count` item is refused.

## Environment variables that are not defaults

Every name below is read by the code. A test fails when the code reads a
`MAINTAINER_*` name this page does not list.

**You set these**, for one invocation or in your shell:

| variable | what it does |
|---|---|
| `MAINTAINER_PROFILE` | which deployed profile a command acts on. Required when more than one is deployed |
| `MAINTAINER_FORCE` | `1` skips the cadence gate in `run.sh` for one run. It is unset before the agent starts |
| `MAINTAINER_POST` | `on` or `off`, overriding the profile's `POST` for one run |
| `MAINTAINER_NOTIFY` | `off` silences desktop notifications |
| `MAINTAINER_ALERT_CMD` | a shell command `run.sh` runs on every failure alert, after the failure marker and the desktop popup, for ntfy, mail or a webhook. The message arrives as `$1`; it also sees `MAINTAINER_ALERT_TASK` and `MAINTAINER_ALERT_LOG`. Its own failure is logged and never fatal |
| `MAINTAINER_UNINSTALL_YES` | `1` lets `install.sh --uninstall` proceed while timers are enabled |
| `MAINTAINER_CARGO_JOBS` | cargo's job count in the sysknife rust suite. Overrides the suite's `suite_jobs` |
| `MAINTAINER_SHELL_IMAGE` | the image the sysknife shell suite runs in. The test suite points it at a registry image |
| `MAINTAINER_RECEIPT_KEY` | path of the receipt signing key. Default: `~/.local/share/maintainer/receipt.key` |
| `MAINTAINER_IMAGE_RESOLVER` | the script `verify-deps` asks what an image tag resolves to. Default: `scripts/resolve_image_digest.py` |
| `MAINTAINER_FAILURE_SHAPES` | path of the failure-classification table. Default: `lib/failure-shapes.json` |
| `MAINTAINER_SETTINGS` | the permission file the backend uses (the claude settings or the opencode config), replacing the profile's own. `run.sh` sets it itself to swap in the rehearsal wall |
| `MAINTAINER_THINKING` | thinking-token budget for the claude backend when the profile sets no `THINKING_<task>` |
| `MAINTAINER_CURSOR_DIR` | directory of the cursor backend's configuration |
| `MAINTAINER_BACKEND` | overrides `BACKEND` in a profile that reads it (the shipped ones do) |
| `MAINTAINER_PROSE_STYLE` | `raw` turns the prose discipline off, for debugging a prompt |
| `MAINTAINER_REPO_PATH`, `MAINTAINER_REPO_ORIGIN`, `MAINTAINER_STATE_DIR` | where a profile's review checkout lives, where it is cloned from, and where runs are recorded |
| `MAINTAINER_<KEY>` | any key in the table above |

**`run.sh` sets these** for the tools it calls, so a tool called from inside a run
acts on that run's repository and nothing else. Setting them by hand is how a
tool is pointed at the wrong project:

| variable | what it carries |
|---|---|
| `MAINTAINER_SLUG`, `MAINTAINER_REPO`, `MAINTAINER_STATE`, `MAINTAINER_ACCOUNT` | the profile's `REPO_SLUG`, `REPO_PATH`, `STATE_DIR` and `GH_ACCOUNT` |
| `MAINTAINER_TASK`, `MAINTAINER_TASKS`, `MAINTAINER_SKILL` | the task being run, the profile's task list, the skill that task loads |
| `MAINTAINER_IN_RUN` | `<profile>/<task>`. A tool that sees it refuses to start another run, and `maintainer-merge` refuses an `asserted` receipt |
| `MAINTAINER_SCRIPTS` | the directory holding `scripts/` |
| `MAINTAINER_VERSION`, `MAINTAINER_COMMIT` | the deployed build, stamped into the run report |
| `MAINTAINER_ALERT_TASK`, `MAINTAINER_ALERT_LOG` | which run an alert is about, and its log |
| `MAINTAINER_SCRUB_NEEDLE` | the secret the exit-time scrub removes from the run's files. It travels in the environment, never in argv |

**A profile key spelled like one:** `MAINTAINER_NAME` in `profile.env` is the
maintainer's name, written into the doctrine as `__MAINTAINER__`.
