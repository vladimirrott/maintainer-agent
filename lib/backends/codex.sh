#!/usr/bin/env bash
# Codex CLI backend.
#
# Verified against codex-cli 0.149.1.
#
# Containment is COARSER than the Claude backend, and the difference matters.
# Codex expresses a sandbox mode (`read-only`, `workspace-write`,
# `danger-full-access`) rather than a per-command deny list, so it cannot
# express "everything except `git push`, `gh pr merge`, `cargo publish` and
# reads of ~/.ssh". `workspace-write` confines writes to the working tree, and
# the network policy comes from config, but a shell command that pushes or
# publishes is not individually blocked the way it is under Claude.
#
# Consequence, stated plainly: run publishing-capable tasks on the Claude
# backend. Codex is for read-and-report passes, and for a second opinion on a
# diff, where the blast radius is a comment.

backend_name() { printf 'codex'; }

backend_check() {
    command -v codex >/dev/null || { echo "codex not on PATH"; return 1; }
    return 0
}

# backend_run <prompt-file> <model> <log-file> <extra-readable-dir>
backend_run() {
    local prompt_file="$1" model="$2" log="$3" _extra_dir="$4"
    # `codex exec` takes the prompt on stdin when no positional argument is
    # given. -C sets the working root; -s bounds writes to it.
    codex exec \
        --sandbox workspace-write \
        -C "$REPO_PATH" \
        -m "$model" \
        --skip-git-repo-check \
        - < "$prompt_file" >>"$log" 2>&1
}
