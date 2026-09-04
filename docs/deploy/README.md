# Deploying it

Four ways, in order of how much you have to trust the machine.

## 1. A timer on a machine you own (what this repo does)

`./install.sh --timers` on Linux, `platform/macos/install-launchd.sh` on macOS,
`Install-Maintainer.ps1` on Windows, `platform/posix/install-cron.sh` anywhere
else. The agent runs as you, with your `gh` credentials and your model
subscription.

**Trust:** total. It is your machine and your token. This is why `POST=off` is
the default for a new profile and why the deny wall exists.

**Best for:** one maintainer, one or two repositories, work that needs a real
checkout and a container.

## 2. On demand, from any MCP client

```sh
maintainer-mcp --tools
```

`assets/mcp.json.example` is the config. Claude Code, Claude Desktop, Cursor and
Codex all speak MCP over stdio.

Six tools: `status`, `screen`, `verify`, `merge`, `release_check`, `prune`.
Every mutation shells out to the same binary a human uses, so the receipt, the
identity gate, the check board, the merge state and `POST=off` all still apply.
A client asking to merge without a receipt gets the gate's own refusal.

Absent on purpose: **`receipt`** in its asserted form, and anything that
publishes. An agent that can write its own receipt proves nothing, and exposing
that over MCP would be the same hole with a nicer interface.

**Trust:** the same as (1) plus your MCP client, because tool arguments come
from a model. Every argument is validated rather than interpolated, and a pull
request number that is not an integer is refused before anything runs.

**Best for:** driving the maintainer from the editor you are already in.

## 3. GitHub Actions

`examples/github-actions-review.yml` is a working starting point and is **not**
enabled in this repository, deliberately.

**Trust:** different, and worse in one specific way. The agent gets a
`GITHUB_TOKEN` with write scope and runs on infrastructure you do not control,
so a prompt injection that reaches it is operating with the repository's own
credentials rather than with a token you can scope by hand. Weigh that against
the advantage, which is real: a fresh, disposable machine per run, so a hostile
pull request has nothing durable to attack.

If you do this:

- run on `pull_request_target` **never**; use `pull_request`, which does not
  give a fork's code access to secrets
- keep `permissions:` at `contents: read` and add only what a task needs
- leave `POST=off` until you have read a week of runs
- never let it merge from CI: the receipt needs a container and a mutation, and
  a run that cannot produce one must not be able to skip it

## 4. A container on a server

The whole tool is bash and python3. `install.sh` deploys into `~/.local`, so an
image is a base, a checkout, and `./install.sh`. The state directory should be a
volume, because it is the audit trail.

**Trust:** you are back to (1), except the machine is unattended in a different
sense. `podman` inside a container needs privileges you probably do not want to
grant, so `maintainer-merge verify` is the part that will not work; the review
tasks will.

## Releasing the tool itself

`.github/workflows/release.yml` runs on a `v*` tag: the gates run against the
tag, then the release is published with notes taken from the CHANGELOG rather
than from commit subjects. A tag whose version has no CHANGELOG section is
refused rather than given invented notes.
