#!/usr/bin/env bash
# systemd passes one instance name, "<profile>-<task>". Split it and dispatch.
# Kept separate from lib/run.sh so the unit file needs no shell quoting.
set -uo pipefail
instance="${1:?usage: run-instance.sh <profile>-<task>}"
profile="${instance%%-*}"
task="${instance#*-}"
exec "$(dirname "$(readlink -f "$0")")/run.sh" "$profile" "$task"
