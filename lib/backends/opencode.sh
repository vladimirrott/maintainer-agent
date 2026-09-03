#!/usr/bin/env bash
# opencode backend, provider-agnostic, wired here to Groq.
#
# Verified against the documented CLI: `opencode run [message..]`, `--model
# provider/model`, `--format default|json`, and a permission system configured
# in opencode.json.
#
# CONTAINMENT: the strongest of the four, and the reason is structural rather
# than diligent. opencode's permission rules are patterns evaluated last-match-
# wins, so the config can open with `"*": "deny"` and then allow specific
# commands. Everything unlisted falls through to deny.
#
# That closes the hole measured on the Claude backend, where a denylist is
# spelling-specific: `/usr/bin/git push` evaded a rule written for `git push`,
# because the matcher sees a different string. Under default-deny an unfamiliar
# spelling is denied precisely because it is unfamiliar.
#
# One trap found while writing the config, worth repeating: a broad allow
# re-opens the hole. `"cargo *": "allow"` permitted `cargo publish`. The
# publishing verbs are therefore denied again at the END of the map, where
# last-match-wins puts them on top.

backend_name() { printf 'opencode'; }

backend_check() {
    command -v opencode >/dev/null || { echo "opencode not on PATH (curl -fsSL https://opencode.ai/install | bash)"; return 1; }
    [ -f "$PROFILE_DIR/opencode.json" ] || { echo "missing $PROFILE_DIR/opencode.json"; return 1; }
    if [ -z "${GROQ_API_KEY:-}" ] && [ ! -f "$HOME/.groq-staging-key" ] \
       && [ ! -f "$HOME/.local/share/opencode/auth.json" ]; then
        echo "no Groq credential: set GROQ_API_KEY, or ~/.groq-staging-key, or run 'opencode auth login'"
        return 1
    fi
    return 0
}

# backend_run <prompt-file> <model> <log-file> <extra-readable-dir>
backend_run() {
    local prompt_file="$1" model="$2" log="$3" _extra="$4"
    # The profile names a Claude model; map it onto a Groq one unless the
    # profile already gave a provider/model pair.
    case "$model" in
        */*) ;;
        *) model="${MAINTAINER_OPENCODE_MODEL:-groq/openai/gpt-oss-120b}" ;;
    esac
    [ -z "${GROQ_API_KEY:-}" ] && [ -f "$HOME/.groq-staging-key" ] \
        && GROQ_API_KEY="$(tr -d '\n' < "$HOME/.groq-staging-key")" && export GROQ_API_KEY
    # --auto approves what the config does not explicitly deny. That is only
    # safe because the config denies by default; with an allow-by-default config
    # it would be equivalent to --yolo.
    OPENCODE_CONFIG="$PROFILE_DIR/opencode.json" \
    opencode run --model "$model" --auto --format default \
        "$(cat "$prompt_file")" >>"$log" 2>&1
}
