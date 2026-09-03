#!/usr/bin/env bash
# Cursor CLI backend.
#
# Verified against the documented CLI: `cursor-agent -p` is non-interactive,
# `--output-format text|json|stream-json`, and `--force` is required before it
# will apply file changes rather than propose them.
#
# CONTAINMENT: the weakest of the three, and the docs say so plainly. Cursor's
# own documentation states that in non-interactive mode the agent has full write
# access, and there is no per-command deny list to express "everything except
# git push and cargo publish". `--force` compounds it by turning proposals into
# writes.
#
# Consequence: this backend is for READ-ONLY passes. It is never given a task
# that can post, publish, merge or write to the repository, and `run.sh` refuses
# to pair it with one. Use it for a second opinion on a diff, where the output
# is text a human reads.

backend_name() { printf 'cursor'; }

backend_check() {
    command -v cursor-agent >/dev/null || { echo "cursor-agent not on PATH"; return 1; }
    return 0
}

# Tasks this backend may run. Anything else is refused by run.sh.
backend_allowed_tasks() { printf 'readonly-review'; }

# backend_run <prompt-file> <model> <log-file> <extra-readable-dir>
backend_run() {
    local prompt_file="$1" model="$2" log="$3" _extra="$4"
    # No --force on purpose. Without it Cursor proposes rather than writes, which
    # is the only containment available here.
    cursor-agent -p --output-format text -m "$model" "$(cat "$prompt_file")" >>"$log" 2>&1
}
