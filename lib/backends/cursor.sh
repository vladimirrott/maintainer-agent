#!/usr/bin/env bash
# Cursor CLI backend.
#
# `cursor-agent -p` is non-interactive, `--output-format text|json|stream-json`,
# and `--force` is required before it applies file changes rather than proposing
# them.
#
# CONTAINMENT. This file used to say Cursor has "no per-command deny list", and
# restricted the backend to read-only tasks on that basis. That was stale. The
# documented configuration carries `permissions.allow` and `permissions.deny`
# with `Shell()`, `Read()` and `Write()` patterns, and `CURSOR_CONFIG_DIR`
# points the CLI at a directory of our choosing, which is what makes a
# per-profile wall possible at all. scripts/render-settings.py generates one
# from the same deny.json every other backend uses.
#
# A stale claim about containment is not conservative. It made this backend
# less capable than it is while reading like caution, and it is the reason
# `readonly-review` was the only task it could be given.
#
# What is still weaker than Claude here, and why this is not simply equivalent:
#
#   - Unproven end to end. The wall renders and its shape matches the
#     documentation. Nothing here has watched cursor-agent refuse a denied
#     command, because the CLI is not installed on this machine and its login is
#     interactive. Until somebody runs the probe, this is a configuration
#     believed to work, which is exactly the kind of claim docs/lessons.md keeps
#     recording. See issue #5.
#   - `--force` turns proposals into writes. It is never passed.

backend_name() { printf 'cursor'; }

# Declared now, because the wall exists and run.sh can hand it a POST=off run.
backend_rehearsal() { printf 'config-dir'; }

# STILL restricted, and the restriction is now gated on proof rather than on the
# stale claim it used to rest on. The wall renders and matches the documented
# shape; nothing has watched cursor-agent refuse a denied command. Lifting a
# guard because a configuration ought to work is the over-claiming this project
# keeps recording. tests/containment-probe.sh is the shape of the evidence
# needed; issue #5 is where it goes. Delete this function when the probe passes,
# not before.
backend_allowed_tasks() { printf 'readonly-review'; }

backend_check() {
    command -v cursor-agent >/dev/null || { echo "cursor-agent not on PATH"; return 1; }
    local dir="${MAINTAINER_CURSOR_DIR:-$PROFILE_DIR/cursor}"
    [ -f "$dir/cli-config.json" ] || { echo "no cursor wall at $dir; run ./install.sh"; return 1; }
    return 0
}

# backend_run <prompt-file> <model> <log-file> <extra-readable-dir>
backend_run() {
    local prompt_file="$1" model="$2" log="$3" _extra="$4"
    # The wall, chosen by run.sh: the rehearsal directory adds every GitHub
    # write verb on top of the live one.
    local dir="${MAINTAINER_CURSOR_DIR:-$PROFILE_DIR/cursor}"
    # No --force on purpose. Without it Cursor proposes rather than writes, and
    # that stays true whatever the permissions file says.
    CURSOR_CONFIG_DIR="$dir" \
        cursor-agent -p --output-format text -m "$model" "$(cat "$prompt_file")" >>"$log" 2>&1
}
