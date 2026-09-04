#!/usr/bin/env bash
# systemd passes one instance name, "<profile>-<task>". Split it and dispatch.
# Kept separate from lib/run.sh so the unit file needs no shell quoting.
set -uo pipefail
instance="${1:?usage: run-instance.sh <profile>-<task>}"
# Split on the LAST hyphen, not the first. A profile named after a hyphenated
# repository, which is the natural choice, split as profile="my" task="repo-review".
# Task names cannot contain a hyphen: run.sh builds MODEL_$task, SKILL_$task and
# MIN_HOURS_$task as shell variable names, and a hyphen makes those invalid.
profile="${instance%-*}"
task="${instance##*-}"
exec "$(dirname "$(readlink -f "$0")")/run.sh" "$profile" "$task"
