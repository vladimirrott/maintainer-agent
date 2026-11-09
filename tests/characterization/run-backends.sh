#!/usr/bin/env bash
# Characterization: backend selection and what each backend runs. The exact argv
# of claude, codex, opencode and cursor-agent, the stdin or the single-argument
# prompt each is given, the environment each backend file sets, where the output
# goes, the refusals that come from backend_check and backend_allowed_tasks, and
# the exit status of a failed backend. A stub logs everything it was given.
#
# Pins current behaviour. Plan decisions named in the comments: F7 for the cursor
# backend's one task that cannot run.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib-run.sh"
cz_init
rz_init

LOG="" 
setup() { rz_setup; LOG="$RZ_LOGS/$RZ_RUNID.log"; }
CRIT_TITLE='maintainer · fx review · FAILED'
CLAUDE_ARGV_LIVE() { printf -- '-p --settings %s --permission-mode bypassPermissions --model %s --add-dir %s --output-format stream-json --verbose' "$RZ_PROFILE_DIR/settings.json" "${1:-opus}" "$RZ_STATE"; }

# --- claude --------------------------------------------------------------------------

case_claude_argv() {
    setup
    rz_run fx review
    cz_expect_rc 0
    rz_expect_b_argv claude "$(CLAUDE_ARGV_LIVE)"
    rz_expect_b_env claude PWD "$RZ_STATE/checkout"
    rz_expect_b_env claude MAINTAINER_TASK review
}
cz_case "claude: argv is -p, --settings, --permission-mode bypassPermissions, --model, --add-dir STATE_DIR, stream-json, --verbose" case_claude_argv

case_claude_model_from_profile() {
    setup
    rz_profile_add 'MODEL_review="sonnet"'
    rz_run fx review
    cz_expect_rc 0
    rz_expect_b_argv claude "$(CLAUDE_ARGV_LIVE sonnet)"
}
cz_case "claude: the model argument is the profile's MODEL_<task>" case_claude_model_from_profile

case_claude_output_through_filter() {
    setup
    printf 'claude stderr line\n' > "$CZ_CASE/b/err"
    rz_run fx review
    cz_expect_rc 0
    rz_log_line "agent says hello"
    rz_log_line "claude stderr line"
    cz_expect_stderr_empty
    cz_check "commands file" "$(cat "$RZ_LOGS/$RZ_RUNID.commands")" '$ echo hi'
}
cz_case "claude: the stream goes through transcript.py into the log and the .commands file, claude's stderr goes to the log" case_claude_output_through_filter

case_claude_no_filter_dir() {
    setup
    rm -rf "$RZ_TREE/scripts"
    printf 'plain text answer\n' > "$CZ_CASE/b/out"
    printf 'claude stderr line\n' > "$CZ_CASE/b/err"
    rz_run fx review
    cz_expect_rc 0
    rz_expect_b_argv claude "-p --settings $RZ_PROFILE_DIR/settings.json --permission-mode bypassPermissions --model opus --add-dir $RZ_STATE"
    rz_log_line "transcript.py not found at /transcript.py; this run records prose only"
    rz_log_line "plain text answer"
    rz_log_line "claude stderr line"
    cz_expect_no_file "$RZ_LOGS/$RZ_RUNID.commands"
    rz_expect_b_env claude MAINTAINER_SCRIPTS "<unset>"
}
# Pins current behaviour: with no scripts directory MAINTAINER_SCRIPTS is unset, so
# the message names /transcript.py, a path at the filesystem root.
cz_case "claude: with no scripts/ directory the text fallback runs and the log names /transcript.py" case_claude_no_filter_dir

case_claude_no_filter_file() {
    setup
    rm "$RZ_TREE/scripts/transcript.py"
    rz_run fx review
    cz_expect_rc 0
    rz_log_line "transcript.py not found at $RZ_TREE/scripts/transcript.py; this run records prose only"
    rz_expect_b_argv claude "-p --settings $RZ_PROFILE_DIR/settings.json --permission-mode bypassPermissions --model opus --add-dir $RZ_STATE"
}
cz_case "claude: with scripts/ but no transcript.py the fallback names the missing file" case_claude_no_filter_file

case_claude_fails_pipeline() {
    setup
    printf '3' > "$CZ_CASE/b/rc"
    rz_run fx review
    cz_expect_rc 0
    cz_expect_stderr "claude exited non-zero for $RZ_RUNID. See $LOG"
}
cz_case "claude: a non-zero claude is a backend failure even though the filter succeeds (pipefail)" case_claude_fails_pipeline

case_claude_filter_fails() {
    setup
    printf 'import sys\nsys.stdin.read()\nsys.exit(5)\n' > "$RZ_TREE/scripts/transcript.py"
    rz_run fx review
    cz_expect_rc 0
    cz_expect_stderr "claude exited non-zero for $RZ_RUNID. See $LOG"
}
cz_case "claude: a failing filter with a succeeding claude is a backend failure too (pipefail, rightmost non-zero)" case_claude_filter_fails

case_claude_thinking_profile() {
    setup
    rz_run fx review
    rz_expect_b_env claude MAX_THINKING_TOKENS 31999
}
cz_case "claude: THINKING_<task> becomes MAX_THINKING_TOKENS" case_claude_thinking_profile

case_claude_thinking_fallback() {
    setup
    rz_profile_add 'unset THINKING_review'
    cz_set MAINTAINER_THINKING 777
    rz_run fx review
    rz_expect_b_env claude MAX_THINKING_TOKENS 777
}
cz_case "claude: without THINKING_<task> MAINTAINER_THINKING is the fallback" case_claude_thinking_fallback

case_claude_thinking_task_wins() {
    setup
    cz_set MAINTAINER_THINKING 777
    rz_run fx review
    rz_expect_b_env claude MAX_THINKING_TOKENS 31999
}
cz_case "claude: THINKING_<task> wins over MAINTAINER_THINKING" case_claude_thinking_task_wins

case_claude_thinking_none() {
    setup
    rz_profile_add 'unset THINKING_review'
    rz_run fx review
    rz_expect_b_env claude MAX_THINKING_TOKENS "<unset>"
}
cz_case "claude: with neither, MAX_THINKING_TOKENS is not exported" case_claude_thinking_none

case_claude_subagent_model() {
    setup
    rz_run fx review
    rz_expect_b_env claude CLAUDE_CODE_SUBAGENT_MODEL sonnet
}
cz_case "claude: SUBAGENT_MODEL_<task> becomes CLAUDE_CODE_SUBAGENT_MODEL" case_claude_subagent_model

case_claude_subagent_model_absent() {
    setup
    rz_start_id "$RZ_STAMP-issues"
    rz_run fx issues
    cz_expect_rc 0
    rz_expect_b_env claude CLAUDE_CODE_SUBAGENT_MODEL "<unset>"
}
cz_case "claude: a task with no SUBAGENT_MODEL_<task> exports no subagent model" case_claude_subagent_model_absent

case_claude_not_on_path() {
    setup
    rm "$CZ_CASE/bin/claude"
    rz_run fx review
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr "backend claude unusable: claude not on PATH"
    cz_expect_no_file "$CZ_CASE/flock.calls"
    rz_expect_helper_count "start review" 0
    rz_expect_gh
    rz_log_line "maintainer=9.9.9 backend=claude model=opus log=$LOG"
}
cz_case "claude: not on PATH exits 1 before the lock, the identity check and the helper's start" case_claude_not_on_path

case_claude_preview_skips_check() {
    setup
    rm "$CZ_CASE/bin/claude"
    rz_run --show-prompt fx review
    cz_expect_rc 0
    cz_expect_stderr_empty
    rz_want_prompt "$CZ_CASE/want.prompt" review claude on "$RZ_PREVIEW_CONTEXT"
    cz_expect_file_equals "$CZ_CASE/stdout" "$CZ_CASE/want.prompt" "the preview"
}
cz_case "claude: a preview does not check that the backend is installed" case_claude_preview_skips_check

# --- codex ---------------------------------------------------------------------------

case_codex_argv() {
    setup
    cz_set MAINTAINER_BACKEND codex
    rz_run fx review
    cz_expect_rc 0
    rz_expect_b_not_called claude
    rz_expect_b_argv codex "exec --sandbox workspace-write -C $RZ_STATE/checkout -m opus --skip-git-repo-check -"
    rz_want_prompt "$CZ_CASE/want.prompt" review codex on "$(printf '=== maintainer %s ===\nskill        fixture-skill' "$RZ_RUNID")"
    cz_expect_file_equals "$(rz_b codex.stdin)" "$CZ_CASE/want.prompt" "the prompt on codex's stdin"
    rz_log_line "maintainer=9.9.9 backend=codex model=opus log=$LOG"
}
cz_case "codex: argv is exec --sandbox workspace-write -C REPO -m MODEL --skip-git-repo-check -, prompt on stdin" case_codex_argv

case_codex_output_to_log() {
    setup
    cz_set MAINTAINER_BACKEND codex
    rz_set_backend_out "codex says hi"
    printf 'codex stderr line\n' > "$CZ_CASE/b/err"
    rz_run fx review
    cz_expect_rc 0
    rz_log_line "codex says hi"
    rz_log_line "codex stderr line"
    cz_expect_stderr_empty
    cz_expect_no_file "$RZ_LOGS/$RZ_RUNID.commands"
}
cz_case "codex: stdout and stderr both go to the log, and no .commands file is written" case_codex_output_to_log

case_codex_fails() {
    setup
    cz_set MAINTAINER_BACKEND codex
    printf '1' > "$CZ_CASE/b/rc"
    rz_run fx review
    cz_expect_rc 0
    cz_expect_stderr "codex exited non-zero for $RZ_RUNID. See $LOG"
}
cz_case "codex: a non-zero codex is a backend failure" case_codex_fails

case_codex_not_on_path() {
    setup
    cz_set MAINTAINER_BACKEND codex
    rm "$CZ_CASE/bin/codex"
    rz_run fx review
    cz_expect_rc 1
    cz_expect_stderr "backend codex unusable: codex not on PATH"
}
cz_case "codex: not on PATH exits 1" case_codex_not_on_path

case_codex_preview_skips_check() {
    setup
    cz_set MAINTAINER_BACKEND codex
    rm "$CZ_CASE/bin/codex"
    rz_run --show-prompt fx review
    cz_expect_rc 0
    cz_expect_stderr_empty
}
cz_case "codex: a preview works with codex missing" case_codex_preview_skips_check

case_codex_post_off() {
    setup
    cz_set MAINTAINER_BACKEND codex
    cz_set MAINTAINER_POST off
    rz_run fx review
    cz_expect_rc 78
    cz_expect_stdout_empty
    cz_expect_stderr "backend 'codex' cannot enforce POST=off (no per-command deny list); use claude or opencode"
    rz_expect_helper_count "failed review" 1
    cz_expect_no_file "$CZ_CASE/flock.calls"
    rz_expect_b_not_called codex
}
cz_case "codex: POST=off exits 78 before the lock because codex has no rehearsal wall" case_codex_post_off

case_codex_post_off_preview() {
    setup
    cz_set MAINTAINER_BACKEND codex
    cz_set MAINTAINER_POST off
    rz_run --show-prompt fx review
    cz_expect_rc 0
    cz_expect_stderr "run.sh: (preview) no rehearsal wall is rendered in this tree; a real
        run would refuse here. ./install.sh renders it."
    rz_want_prompt "$CZ_CASE/want.prompt" review codex off "$RZ_PREVIEW_CONTEXT"
    cz_expect_file_equals "$CZ_CASE/stdout" "$CZ_CASE/want.prompt" "the preview"
}
cz_case "codex: a POST=off preview works and warns that a real run would refuse" case_codex_post_off_preview

# --- opencode ------------------------------------------------------------------------

# The first line of opencode's argv log starts with the given text.
rz_expect_oc_prefix() {
    local first; first="$(head -1 "$(rz_b opencode.argv)")"
    case "$first" in "$1"*) ;; *) cz_note_fail "opencode argv does not start with '$1': $(printf '%s' "$first" | cut -c1-120)" ;; esac
}
OC_CONFIG_MISSING() { printf 'backend opencode unusable: missing %s' "$1"; }

oc_setup() {
    setup
    cz_set MAINTAINER_BACKEND opencode
    cz_set GROQ_API_KEY fixture-groq-key
}

case_opencode_argv() {
    oc_setup
    rz_run fx review
    cz_expect_rc 0
    rz_expect_b_not_called claude
    rz_expect_oc_prefix "run --model groq/openai/gpt-oss-120b --auto --format default \$'Provenance for this run"
    rz_expect_b_env opencode OPENCODE_CONFIG "$RZ_PROFILE_DIR/opencode.json"
    rz_expect_b_env opencode GROQ_API_KEY fixture-groq-key
}
cz_case "opencode: argv is run --model M --auto --format default <whole prompt as one argument>, config from the profile" case_opencode_argv

case_opencode_prompt_argument() {
    oc_setup
    rz_run fx review
    cz_expect_rc 0
    rz_want_prompt "$CZ_CASE/want.prompt" review opencode on "$(printf '=== maintainer %s ===\nskill        fixture-skill' "$RZ_RUNID")"
    # $(cat file) drops the trailing newline, so the argument is the prompt minus its last newline.
    local want="$CZ_CASE/want.arg"
    printf '%s' "$(cat "$CZ_CASE/want.prompt")" > "$want"
    cz_expect_file_equals "$(rz_b opencode.lastarg)" "$want" "the prompt argument"
    cz_check "stdin is empty" "$(wc -c < "$(rz_b opencode.stdin)" | tr -d ' ')" 0
}
cz_case "opencode: the prompt is the last argument, without its trailing newline, and stdin is empty" case_opencode_prompt_argument

case_opencode_model_mapping() {
    oc_setup
    rz_profile_add 'MODEL_review="groq/other-model"'
    rz_run fx review
    cz_expect_rc 0
    rz_expect_oc_prefix "run --model groq/other-model --auto --format default "
}
cz_case "opencode: a profile model that already has a provider/model form is passed through" case_opencode_model_mapping

case_opencode_model_default() {
    oc_setup
    rz_profile_add 'MODEL_review="sonnet"'
    rz_run fx review
    rz_expect_oc_prefix "run --model groq/openai/gpt-oss-120b --auto --format default "
}
cz_case "opencode: a bare model name is replaced by OPENCODE_MODEL from defaults.env" case_opencode_model_default

case_opencode_model_override() {
    oc_setup
    cz_set MAINTAINER_OPENCODE_MODEL groq/override-model
    rz_run fx review
    rz_expect_oc_prefix "run --model groq/override-model --auto --format default "
}
cz_case "opencode: MAINTAINER_OPENCODE_MODEL overrides the default model" case_opencode_model_override

case_opencode_key_file() {
    setup
    cz_set MAINTAINER_BACKEND opencode
    printf 'key-from\nfile\n\n' > "$RZ_HOME/.groq-staging-key"
    rz_run fx review
    cz_expect_rc 0
    rz_expect_b_env opencode GROQ_API_KEY key-fromfile
}
cz_case "opencode: with no GROQ_API_KEY the key is read from ~/.groq-staging-key with every newline removed, inner ones too" case_opencode_key_file

case_opencode_key_env_wins() {
    setup
    cz_set MAINTAINER_BACKEND opencode
    cz_set GROQ_API_KEY key-from-env
    printf 'key-from-file\n' > "$RZ_HOME/.groq-staging-key"
    rz_run fx review
    rz_expect_b_env opencode GROQ_API_KEY key-from-env
}
cz_case "opencode: GROQ_API_KEY from the environment wins over the key file" case_opencode_key_env_wins

case_opencode_auth_json() {
    setup
    cz_set MAINTAINER_BACKEND opencode
    mkdir -p "$RZ_HOME/.local/share/opencode"; printf '{}\n' > "$RZ_HOME/.local/share/opencode/auth.json"
    rz_run fx review
    cz_expect_rc 0
    rz_expect_b_env opencode GROQ_API_KEY "<unset>"
}
cz_case "opencode: a login in auth.json is enough, and no GROQ_API_KEY is exported" case_opencode_auth_json

case_opencode_no_credential() {
    setup
    cz_set MAINTAINER_BACKEND opencode
    rz_run fx review
    local msg="backend opencode unusable: no Groq credential: set GROQ_API_KEY, or ~/.groq-staging-key, or run 'opencode auth login'"
    cz_expect_rc 1
    cz_expect_stderr "$msg"
    rz_expect_b_not_called opencode
    rz_expect_notify 1 critical "$CRIT_TITLE" "$(printf '%s\nlog  %s' "$msg" "$LOG")"
}
cz_case "opencode: no credential from any of the three sources exits 1" case_opencode_no_credential

case_opencode_not_on_path() {
    oc_setup
    rm "$CZ_CASE/bin/opencode"
    rz_run fx review
    local msg="backend opencode unusable: opencode not on PATH (curl -fsSL https://opencode.ai/install | bash)"
    cz_expect_rc 1
    cz_expect_stderr "$msg"
    rz_expect_notify 1 critical "$CRIT_TITLE" "$(printf '%s\nfix  install it, then: maintainer-doctor\nlog  %s' "$msg" "$LOG")"
}
cz_case "opencode: not on PATH exits 1 with the install command in the message" case_opencode_not_on_path

case_opencode_missing_config() {
    oc_setup
    rm "$RZ_PROFILE_DIR/opencode.json"
    rz_run fx review
    cz_expect_rc 1
    cz_expect_stderr "$(OC_CONFIG_MISSING "$RZ_PROFILE_DIR/opencode.json")"
    rz_expect_notify 1 critical "$CRIT_TITLE" "$(printf 'Claude Code has no settings file for this profile.\nfix  ./install.sh\nlog  %s' "$LOG")"
}
cz_case "opencode: a missing opencode.json exits 1 and the toast reuses the settings-file text" case_opencode_missing_config

case_opencode_rehearsal_wall() {
    oc_setup
    rz_wall
    cz_set MAINTAINER_POST off
    rz_run fx review
    cz_expect_rc 0
    rz_expect_b_env opencode OPENCODE_CONFIG "$RZ_PROFILE_DIR/opencode-rehearsal.json"
    rz_expect_b_env opencode MAINTAINER_SETTINGS "$RZ_PROFILE_DIR/opencode-rehearsal.json"
}
cz_case "opencode: POST=off hands opencode the rehearsal config" case_opencode_rehearsal_wall

case_opencode_post_off_no_wall() {
    oc_setup
    cz_set MAINTAINER_POST off
    rz_run fx review
    cz_expect_rc 78
    cz_expect_stderr "run.sh: POST=off but backend 'opencode' has no rehearsal wall rendered for 'fx'
        re-run ./install.sh, which renders it beside the live wall"
}
cz_case "opencode: POST=off with no rehearsal config exits 78" case_opencode_post_off_no_wall

case_opencode_output_to_log() {
    oc_setup
    rz_set_backend_out "opencode says hi"
    printf 'opencode stderr line\n' > "$CZ_CASE/b/err"
    rz_run fx review
    cz_expect_rc 0
    rz_log_line "opencode says hi"
    rz_log_line "opencode stderr line"
}
cz_case "opencode: stdout and stderr both go to the log" case_opencode_output_to_log

# Pins current behaviour: the whole prompt is one argument and Linux refuses a
# single argument over 131072 bytes, so a long task prompt cannot reach opencode.
# bash reports "Argument list too long", the stub never runs, and the run goes on
# as a backend failure. No plan decision yet.
case_opencode_arg_too_long() {
    oc_setup
    head -c 140000 /dev/zero | tr '\0' 'x' > "$RZ_PROFILE_DIR/prompts/review.md"
    printf '\n' >> "$RZ_PROFILE_DIR/prompts/review.md"
    rz_run fx review
    cz_expect_rc 0
    rz_expect_b_not_called opencode
    cz_expect_stderr_has "opencode exited non-zero for $RZ_RUNID. See $LOG"
    rz_log_has "opencode: Argument list too long"
}
cz_case "opencode: a prompt over 131072 bytes cannot be passed (Argument list too long) and counts as a backend failure" case_opencode_arg_too_long

# --- cursor --------------------------------------------------------------------------

cursor_setup() {
    setup
    rz_wall
    cz_set MAINTAINER_BACKEND cursor
}

case_cursor_refuses_review() {
    cursor_setup
    rz_run fx review
    local msg="backend 'cursor' may only run: readonly-review (refused 'review')"
    cz_expect_rc 78
    cz_expect_stdout_empty
    cz_expect_stderr "$msg"
    rz_expect_helper_count "failed review" 1
    rz_expect_notify 1 critical "$CRIT_TITLE" "$(printf '%s\nlog  %s' "$msg" "$RZ_LOGS/$RZ_STAMP-review.log")"
    cz_expect_no_file "$CZ_CASE/flock.calls"
    rz_expect_b_not_called cursor-agent
    rz_expect_gh
}
cz_case "cursor: any task but readonly-review is refused with exit 78 before the lock" case_cursor_refuses_review

# Pins plan decision F7: readonly-review is the only task cursor may run, and a
# hyphenated task name dies on the model lookup (see run-start.sh), so the cursor
# backend cannot run anything today.
case_cursor_only_task_unrunnable() {
    cursor_setup
    rz_profile_add 'TASKS="review readonly-review"'
    rz_run fx readonly-review
    cz_expect_rc 1
    cz_expect_matches stderr "run.sh: line [0-9]+: MODEL_readonly-review: invalid variable name\$"
    rz_expect_b_not_called cursor-agent
}
cz_case "cursor: its one allowed task, readonly-review, dies on the model lookup, exit 1 (plan decision F7)" case_cursor_only_task_unrunnable

case_cursor_not_on_path_first() {
    cursor_setup
    rm "$CZ_CASE/bin/cursor-agent"
    rz_run fx review
    cz_expect_rc 1
    cz_expect_stderr "backend cursor unusable: cursor-agent not on PATH"
}
cz_case "cursor: the PATH check comes before the task check, so a missing binary exits 1 and not 78" case_cursor_not_on_path_first

case_cursor_no_wall() {
    cursor_setup
    rm -rf "$RZ_PROFILE_DIR/cursor"
    rz_run fx review
    cz_expect_rc 1
    cz_expect_stderr "backend cursor unusable: no cursor wall at $RZ_PROFILE_DIR/cursor; run ./install.sh"
}
cz_case "cursor: a missing wall directory exits 1 naming it" case_cursor_no_wall

case_cursor_preview_refused() {
    cursor_setup
    rz_run --show-prompt fx review
    local msg="backend 'cursor' may only run: readonly-review (refused 'review')"
    cz_expect_rc 78
    cz_expect_stdout_empty
    cz_expect_stderr "$msg"
    rz_expect_helper "$(cz_argv failed review "$msg" /dev/null)"
}
cz_case "cursor: the preview of a refused task exits 78 too, through the alert path with /dev/null as the log" case_cursor_preview_refused

# The cursor backend's own argv, reached by sourcing the file, because run.sh
# never gets as far as calling it (see the two cases above).
case_cursor_argv_driver() {
    setup
    rz_wall
    printf 'the prompt text\nsecond line\n' > "$CZ_CASE/prompt.txt"
    : > "$CZ_CASE/driven.log"
    rz_drive '. "$RZ_TREE/lib/backends/cursor.sh"; backend_run "$CZ_CASE_DIR/prompt.txt" opus "$CZ_CASE_DIR/driven.log" "$CZ_CASE_DIR/state"'
    cz_expect_rc 0
    rz_expect_b_argv cursor-agent "-p --output-format text -m opus \$'the prompt text\\nsecond line'"
    rz_expect_b_env cursor-agent CURSOR_CONFIG_DIR "$RZ_PROFILE_DIR/cursor"
    cz_check "stdin is empty" "$(wc -c < "$(rz_b cursor-agent.stdin)" | tr -d ' ')" 0
}
cz_case "cursor: backend_run calls cursor-agent -p --output-format text -m MODEL <prompt> with CURSOR_CONFIG_DIR and no --force" case_cursor_argv_driver

case_cursor_argv_rehearsal_dir() {
    setup
    rz_wall
    printf 'p\n' > "$CZ_CASE/prompt.txt"
    : > "$CZ_CASE/driven.log"
    cz_set MAINTAINER_CURSOR_DIR "$RZ_PROFILE_DIR/cursor-rehearsal"
    rz_drive '. "$RZ_TREE/lib/backends/cursor.sh"; backend_run "$CZ_CASE_DIR/prompt.txt" opus "$CZ_CASE_DIR/driven.log" x'
    cz_expect_rc 0
    rz_expect_b_env cursor-agent CURSOR_CONFIG_DIR "$RZ_PROFILE_DIR/cursor-rehearsal"
}
cz_case "cursor: MAINTAINER_CURSOR_DIR chooses the wall directory" case_cursor_argv_rehearsal_dir

case_cursor_output_driver() {
    setup
    rz_wall
    printf 'p\n' > "$CZ_CASE/prompt.txt"
    : > "$CZ_CASE/driven.log"
    rz_set_backend_out "cursor says hi"
    printf 'cursor stderr line\n' > "$CZ_CASE/b/err"
    rz_drive '. "$RZ_TREE/lib/backends/cursor.sh"; backend_run "$CZ_CASE_DIR/prompt.txt" opus "$CZ_CASE_DIR/driven.log" x'
    cz_expect_stdout_empty
    cz_expect_stderr_empty
    cz_check "driven log" "$(cat "$CZ_CASE/driven.log")" "cursor says hi
cursor stderr line"
}
cz_case "cursor: stdout and stderr both go to the log" case_cursor_output_driver

# The wall each backend asks for, and what each declares.
wall_driver() {  # $1 = backend file, $2 = shell code run after sourcing it
    setup
    rz_drive ". \"\$RZ_TREE/lib/backends/$1.sh\"; $2"
}

case_wall_claude() {
    wall_driver claude 'backend_rehearsal_wall; echo "rc=$? settings=${MAINTAINER_SETTINGS:-<unset>}"'
    cz_expect_stdout "rc=1 settings=<unset>"
    rz_wall
    rz_drive '. "$RZ_TREE/lib/backends/claude.sh"; backend_rehearsal_wall; echo "rc=$? settings=${MAINTAINER_SETTINGS:-<unset>}"'
    cz_expect_stdout "rc=0 settings=$RZ_PROFILE_DIR/settings-rehearsal.json"
}
cz_case "claude: backend_rehearsal_wall fails with no wall and exports MAINTAINER_SETTINGS when it is rendered" case_wall_claude

case_wall_opencode() {
    wall_driver opencode 'backend_rehearsal_wall; echo "rc=$? settings=${MAINTAINER_SETTINGS:-<unset>}"'
    cz_expect_stdout "rc=1 settings=<unset>"
    rz_wall
    rz_drive '. "$RZ_TREE/lib/backends/opencode.sh"; backend_rehearsal_wall; echo "rc=$? settings=${MAINTAINER_SETTINGS:-<unset>}"'
    cz_expect_stdout "rc=0 settings=$RZ_PROFILE_DIR/opencode-rehearsal.json"
}
cz_case "opencode: backend_rehearsal_wall fails with no wall and exports MAINTAINER_SETTINGS when it is rendered" case_wall_opencode

case_wall_cursor() {
    wall_driver cursor 'backend_rehearsal_wall; echo "rc=$? dir=${MAINTAINER_CURSOR_DIR:-<unset>}"'
    cz_expect_stdout "rc=1 dir=<unset>"
    rz_wall
    rz_drive '. "$RZ_TREE/lib/backends/cursor.sh"; backend_rehearsal_wall; echo "rc=$? dir=${MAINTAINER_CURSOR_DIR:-<unset>}"'
    cz_expect_stdout "rc=0 dir=$RZ_PROFILE_DIR/cursor-rehearsal"
}
cz_case "cursor: backend_rehearsal_wall fails with no wall and exports MAINTAINER_CURSOR_DIR when it is rendered" case_wall_cursor

case_backend_declarations() {
    setup
    local b out
    for b in claude codex cursor opencode; do
        rz_drive ". \"\$RZ_TREE/lib/backends/$b.sh\"; printf 'name=%s rehearsal=' \"\$(backend_name)\"; if declare -F backend_rehearsal >/dev/null; then backend_rehearsal; else printf none; fi; printf ' allowed='; if declare -F backend_allowed_tasks >/dev/null; then backend_allowed_tasks; else printf any; fi; echo"
        out="$(cat "$CZ_CASE/stdout")"
        case "$b" in
            claude)   cz_check "$b declarations" "$out" "name=claude rehearsal=settings allowed=any" ;;
            codex)    cz_check "$b declarations" "$out" "name=codex rehearsal=none allowed=any" ;;
            cursor)   cz_check "$b declarations" "$out" "name=cursor rehearsal=config-dir allowed=readonly-review" ;;
            opencode) cz_check "$b declarations" "$out" "name=opencode rehearsal=config allowed=any" ;;
        esac
    done
}
cz_case "backends: each declares its name, whether it can rehearse, and the tasks it may run" case_backend_declarations

# --- choosing a backend ----------------------------------------------------------------

case_backend_unknown() {
    setup
    rz_profile_add 'BACKEND=nosuch'
    rz_run fx review
    local msg="no backend 'nosuch'"
    cz_expect_rc 64
    cz_expect_stdout_empty
    cz_expect_stderr_has "$msg"
    cz_expect_matches stderr "nosuch.sh: No such file or directory"
    rz_expect_helper_count "failed review" 1
    rz_expect_gh
    rz_expect_notify 1 critical "$CRIT_TITLE" "$(printf '%s\nlog  %s' "$msg" "$RZ_LOGS/$RZ_STAMP-review.log")"
}
cz_case "backend: an unknown BACKEND exits 64 with bash's source error and the alert" case_backend_unknown

case_backend_from_profile() {
    setup
    rz_profile_add 'BACKEND=codex'
    rz_run fx review
    cz_expect_rc 0
    rz_expect_b_not_called claude
    rz_expect_b_argv codex "exec --sandbox workspace-write -C $RZ_STATE/checkout -m opus --skip-git-repo-check -"
}
cz_case "backend: the profile's BACKEND chooses the backend file" case_backend_from_profile

case_backend_names_are_files() {
    setup
    cz_set MAINTAINER_BACKEND "../backends/codex"
    rz_run fx review
    cz_expect_rc 0
    rz_expect_b_argv codex "exec --sandbox workspace-write -C $RZ_STATE/checkout -m opus --skip-git-repo-check -"
    # The provenance line and the log header name the backend by what the file
    # says it is, not by the string in BACKEND.
    rz_expect_file_has "$(rz_b codex.stdin)" "task review, backend codex, started"
    rz_log_line "maintainer=9.9.9 backend=codex model=opus log=$LOG"
}
# Pins current behaviour: BACKEND is part of a path with no check, so a relative
# path still resolves. No plan decision yet.
cz_case "backend: BACKEND is joined into a path unchecked, so ../backends/codex still resolves (no plan decision yet)" case_backend_names_are_files

cz_finish
