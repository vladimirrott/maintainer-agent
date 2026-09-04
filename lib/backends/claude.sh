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

# Declaring this is how a backend says it can honour POST=off. run.sh refuses a
# rehearsal on any backend that does not, because a rehearsal that silently
# posts is worse than no rehearsal.
backend_rehearsal() { printf 'settings'; }

backend_check() {
    command -v claude >/dev/null || { echo "claude not on PATH"; return 1; }
    local st="${MAINTAINER_SETTINGS:-$PROFILE_DIR/settings.json}"
    [ -f "$st" ] || { echo "missing $st"; return 1; }
    return 0
}

# backend_run <prompt-file> <model> <log-file> <extra-readable-dir>
backend_run() {
    local prompt_file="$1" model="$2" log="$3" extra_dir="$4"
    # Reasoning effort is not a CLI flag. Claude Code takes the thinking budget
    # from MAX_THINKING_TOKENS in the environment, so the profile sets it per
    # task and this exports it. Naming the mechanism beats implying a flag
    # exists that does not.
    local think_var="THINKING_$MAINTAINER_TASK"
    local think="${!think_var:-${MAINTAINER_THINKING:-}}"
    [ -n "$think" ] && export MAX_THINKING_TOKENS="$think"
    # And the model its subagents get, by the same per-task mechanism.
    #
    # A review fans out: several files, several dimensions, each independent.
    # Running that fan-out on the same model as the main loop pays opus prices
    # for work sonnet does as well, and the main loop is where the thinking
    # budget is spent. Declared per task because only `review` fans out; a
    # cadence sweep that spawns nothing should not carry a setting that reads
    # as though it does.
    #
    # CLAUDE_CODE_SUBAGENT_MODEL is a DEFAULT: a per-invocation model, or a
    # `model:` field in an agent definition, still wins. That is the reason it
    # is used here rather than CLAUDE_CODE_SUBAGENT_MODEL_FORCE, which would
    # override an agent someone deliberately wrote to need a stronger model.
    # A cost control that silently downgrades a security reviewer is not a cost
    # control. Requires Claude Code 2.1.238 or later.
    local sub_var="SUBAGENT_MODEL_$MAINTAINER_TASK"
    local sub="${!sub_var:-}"
    [ -n "$sub" ] && export CLAUDE_CODE_SUBAGENT_MODEL="$sub"
    # MAINTAINER_SETTINGS is how run.sh swaps in the rehearsal wall. Defaulting
    # here rather than requiring it keeps a direct call working.
    local settings="${MAINTAINER_SETTINGS:-$PROFILE_DIR/settings.json}"
    # stream-json rather than text, so the log records what the agent RAN and
    # not only what it said. `--verbose` is required with it in print mode.
    # A missing filter must not cost a run its output, so fall back to text.
    local filter="${MAINTAINER_SCRIPTS:-}/transcript.py"
    if [ -f "$filter" ]; then
        claude -p \
            --settings "$settings" \
            --permission-mode bypassPermissions \
            --model "$model" \
            --add-dir "$extra_dir" \
            --output-format stream-json --verbose \
            < "$prompt_file" 2>>"$log" \
            | python3 "$filter" "$log" "${log%.log}.commands"
    else
        # Say so. A silent fallback is how the transcript went missing for a
        # whole deployment without anyone noticing.
        printf 'transcript.py not found at %s; this run records prose only\n' \
            "$filter" >>"$log"
        claude -p \
            --settings "$settings" \
            --permission-mode bypassPermissions \
            --model "$model" \
            --add-dir "$extra_dir" \
            < "$prompt_file" >>"$log" 2>&1
    fi
}
