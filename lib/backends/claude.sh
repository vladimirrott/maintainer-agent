#!/usr/bin/env bash
# Claude Code backend.
#
# Verified against Claude Code 2.1.257.
#
# Containment: `--settings` carries a deny list that outranks
# `--permission-mode bypassPermissions`. That ordering is the whole reason this
# backend is the default: the agent runs without approval prompts, and still
# cannot reach `git push`, `gh pr merge`, `cargo publish`, `curl`, or any
# credential file. Proven by mutation, not assumed.

backend_name() { printf 'claude'; }

backend_check() {
    command -v claude >/dev/null || { echo "claude not on PATH"; return 1; }
    [ -f "$PROFILE_DIR/settings.json" ] || { echo "missing $PROFILE_DIR/settings.json"; return 1; }
    return 0
}

# backend_run <prompt-file> <model> <log-file> <extra-readable-dir>
backend_run() {
    local prompt_file="$1" model="$2" log="$3" extra_dir="$4"
    claude -p \
        --settings "$PROFILE_DIR/settings.json" \
        --permission-mode bypassPermissions \
        --model "$model" \
        --add-dir "$extra_dir" \
        < "$prompt_file" >>"$log" 2>&1
}
