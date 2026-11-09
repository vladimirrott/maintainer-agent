#!/usr/bin/env bash
# Characterization: prompt assembly. The bytes `run.sh --show-prompt` prints and
# the same bytes a real run hands a backend, for two tasks, a profile override,
# both POST states, a missing file, and the temp file the assembly leaves behind.
# Each expected prompt is composed in the test from literals (rz_want_prompt in
# lib-run.sh), so the test shares no code with the program.
#
# Pins current behaviour. Plan decision F6 covers the leaked temp file.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib-run.sh"
cz_init
rz_init

# --- --show-prompt -------------------------------------------------------------------

case_show_review() {
    rz_setup
    rz_run --show-prompt fx review
    cz_expect_rc 0
    cz_expect_stderr_empty
    rz_want_prompt "$CZ_CASE/want.prompt" review claude on "$RZ_PREVIEW_CONTEXT"
    cz_expect_file_equals "$CZ_CASE/stdout" "$CZ_CASE/want.prompt" "the review prompt"
}
cz_case "show-prompt: review assembles provenance, preamble, doctrine, prose, posting notice, task and context, byte for byte" case_show_review

case_show_issues() {
    rz_setup
    rz_run --show-prompt fx issues
    cz_expect_rc 0
    cz_expect_stderr_empty
    rz_want_prompt "$CZ_CASE/want.prompt" issues claude on "$RZ_PREVIEW_CONTEXT"
    cz_expect_file_equals "$CZ_CASE/stdout" "$CZ_CASE/want.prompt" "the issues prompt"
}
cz_case "show-prompt: a second task takes its own task file and name in the provenance line" case_show_issues

case_show_touches_nothing() {
    rz_setup
    rz_last_ran review 60
    rz_run --show-prompt fx review
    cz_expect_rc 0
    rz_expect_helper
    rz_expect_gh
    rz_expect_no_logs_dir
    cz_expect_no_file "$RZ_STATE/run.lock"
    cz_expect_no_file "$CZ_CASE/flock.calls"
    cz_expect_no_file "$CZ_CASE/notify.calls"
    rz_expect_b_not_called claude
    cz_expect_no_file "$RZ_STATE/leases"
}
cz_case "show-prompt: leaves no log, lock, lease, helper call, gh call or toast" case_show_touches_nothing

# Pins plan decision F6: the prompt temp file is removed by a RETURN trap, and the
# preview leaves through `exit 0`, so the file stays behind.
case_show_leaks_tempfile() {
    rz_setup
    rz_run --show-prompt fx review
    cz_expect_rc 0
    cz_check "files left in TMPDIR" "$(rz_tmp_count)" 1
    local f; f="$(ls "$RZ_TMP")"
    cz_expect_file_equals "$RZ_TMP/$f" "$CZ_CASE/stdout" "the leaked temp file"
    cz_check "temp file mode" "$(stat -c %a "$RZ_TMP/$f")" 600
}
cz_case "show-prompt: leaves its prompt temp file in TMPDIR, mode 600 (plan decision F6)" case_show_leaks_tempfile

case_run_success_no_leak() {
    rz_setup
    rz_run fx review
    cz_expect_rc 0
    cz_check "files left in TMPDIR" "$(rz_tmp_count)" 0
}
cz_case "show-prompt: a run that reaches the end of the script removes its prompt temp file" case_run_success_no_leak

# Pins plan decision F6 again: a run that leaves through `exit 1` after the prompt
# was written keeps the file, so every aborted run leaks one.
case_run_failure_leaks() {
    rz_setup
    printf '1' > "$CZ_CASE/h/finish.rc"
    rz_run fx review
    cz_expect_rc 1
    cz_check "files left in TMPDIR" "$(rz_tmp_count)" 1
}
cz_case "show-prompt: a run that exits 1 after assembly leaves its prompt temp file behind (plan decision F6)" case_run_failure_leaks

case_refusal_before_assembly_no_leak() {
    rz_setup
    cz_gh_rz api-user "someone-else" 0
    rz_run fx review
    cz_expect_rc 1
    cz_check "files left in TMPDIR" "$(rz_tmp_count)" 0
}
cz_case "show-prompt: a refusal before the prompt is assembled leaves nothing in TMPDIR" case_refusal_before_assembly_no_leak

# --- the profile's own settings ------------------------------------------------------

case_prose_raw() {
    rz_setup
    cz_set MAINTAINER_PROSE_STYLE raw
    rz_run --show-prompt fx review
    cz_expect_rc 0
    rz_want_prompt "$CZ_CASE/want.prompt" review claude on "$RZ_PREVIEW_CONTEXT" no
    cz_expect_file_equals "$CZ_CASE/stdout" "$CZ_CASE/want.prompt" "the raw prompt"
}
cz_case "profile override: PROSE_STYLE=raw drops the prose section" case_prose_raw

case_prose_other_value() {
    rz_setup
    cz_set MAINTAINER_PROSE_STYLE whatever
    rz_run --show-prompt fx review
    cz_expect_rc 0
    rz_want_prompt "$CZ_CASE/want.prompt" review claude on "$RZ_PREVIEW_CONTEXT" yes
    cz_expect_file_equals "$CZ_CASE/stdout" "$CZ_CASE/want.prompt" "the prompt"
}
cz_case "profile override: any PROSE_STYLE other than raw keeps the prose section" case_prose_other_value

case_prose_missing_file() {
    rz_setup
    rm "$RZ_TREE/lib/prose-style.md"
    rz_run --show-prompt fx review
    cz_expect_rc 0
    cz_expect_stderr_empty
    rz_want_prompt "$CZ_CASE/want.prompt" review claude on "$RZ_PREVIEW_CONTEXT" no
    cz_expect_file_equals "$CZ_CASE/stdout" "$CZ_CASE/want.prompt" "the prompt"
}
cz_case "profile override: a missing prose-style.md is skipped without a word" case_prose_missing_file

case_name_unset() {
    rz_setup
    rz_profile_add 'unset MAINTAINER_NAME'
    rz_run --show-prompt fx review
    cz_expect_rc 0
    rz_want_prompt "$CZ_CASE/want.prompt" review claude on "$RZ_PREVIEW_CONTEXT" yes "the maintainer"
    cz_expect_file_equals "$CZ_CASE/stdout" "$CZ_CASE/want.prompt" "the prompt"
}
cz_case "profile override: with no MAINTAINER_NAME the doctrine says 'the maintainer'" case_name_unset

# Pins current behaviour: the name goes into a sed replacement, where & means the
# matched text. A name with & comes out with the placeholder inside it. No plan
# decision yet.
case_name_ampersand() {
    rz_setup
    rz_profile_add 'MAINTAINER_NAME="A&B"'
    rz_run --show-prompt fx review
    cz_expect_rc 0
    rz_want_prompt "$CZ_CASE/want.prompt" review claude on "$RZ_PREVIEW_CONTEXT" yes "A__MAINTAINER__B"
    cz_expect_file_equals "$CZ_CASE/stdout" "$CZ_CASE/want.prompt" "the prompt"
}
cz_case "profile override: an & in the maintainer name expands to the placeholder (no plan decision yet)" case_name_ampersand

# Pins current behaviour: | is the sed delimiter, so a name holding one breaks the
# doctrine step. sed complains, the doctrine section is empty, the preview still
# exits 0. No plan decision yet.
case_name_pipe() {
    rz_setup
    rz_profile_add 'MAINTAINER_NAME="A|B"'
    rz_run --show-prompt fx review
    cz_expect_rc 0
    cz_expect_matches stderr "^sed: -e expression #1, char [0-9]+: unknown option to .s'\$"
    rz_want_prompt "$CZ_CASE/want.prompt" review claude on "$RZ_PREVIEW_CONTEXT" yes
    sed -i '/^CORE doctrine/d' "$CZ_CASE/want.prompt"
    cz_expect_file_equals "$CZ_CASE/stdout" "$CZ_CASE/want.prompt" "the prompt without its doctrine line"
}
cz_case "profile override: a | in the maintainer name breaks the doctrine step, sed complains, exit 0 (no plan decision yet)" case_name_pipe

case_missing_task_file() {
    rz_setup
    rm "$RZ_PROFILE_DIR/prompts/review.md"
    rz_run --show-prompt fx review
    cz_expect_rc 0
    cz_expect_stderr "cat: $RZ_PROFILE_DIR/prompts/review.md: No such file or directory"
    rz_want_prompt "$CZ_CASE/want.prompt" review claude on "$RZ_PREVIEW_CONTEXT"
    sed -i '/^TASK review body$/d' "$CZ_CASE/want.prompt"
    cz_expect_file_equals "$CZ_CASE/stdout" "$CZ_CASE/want.prompt" "the prompt without its task"
}
# Pins current behaviour: the error is cat's and the prompt goes ahead without the task.
cz_case "missing file: a missing task file is cat's error on stderr and the prompt carries on without it, exit 0" case_missing_task_file

case_missing_preamble_file() {
    rz_setup
    rm "$RZ_PROFILE_DIR/prompts/common-preamble.md"
    rz_run --show-prompt fx review
    cz_expect_rc 0
    cz_expect_stderr "cat: $RZ_PROFILE_DIR/prompts/common-preamble.md: No such file or directory"
    rz_want_prompt "$CZ_CASE/want.prompt" review claude on "$RZ_PREVIEW_CONTEXT"
    sed -i -e '/^COMMON-PREAMBLE for fx$/d' -e '/^second preamble line$/d' "$CZ_CASE/want.prompt"
    cz_expect_file_equals "$CZ_CASE/stdout" "$CZ_CASE/want.prompt" "the prompt without its preamble"
}
cz_case "missing file: a missing profile preamble is cat's error on stderr and the prompt carries on, exit 0" case_missing_preamble_file

# Pins current behaviour: even a preview reports a missing doctrine through the
# alert path, so it calls the helper's failed verb with /dev/null as the log and
# raises a toast.
case_missing_core_preview() {
    rz_setup
    rm "$RZ_TREE/lib/preamble-core.md"
    rz_run --show-prompt fx review
    local msg="preamble-core.md is missing; refusing to run without the doctrine"
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr "$msg"
    rz_expect_helper "$(cz_argv failed review "$msg" /dev/null)"
    rz_expect_notify_count 1
    rz_expect_notify 1 critical "maintainer · fx review · FAILED" "$(printf '%s\nlog  /dev/null' "$msg")"
}
cz_case "missing file: no preamble-core.md exits 1 even for a preview, with a marker and a toast" case_missing_core_preview

case_missing_core_run() {
    rz_setup
    rm "$RZ_TREE/lib/preamble-core.md"
    rz_run fx review
    local msg="preamble-core.md is missing; refusing to run without the doctrine"
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr "$msg"
    rz_expect_helper_count "start review" 1
    rz_expect_helper_count "failed review" 1
    rz_expect_helper_count "finish" 0
    rz_expect_b_not_called claude
}
cz_case "missing file: in a real run the missing doctrine is found after the helper's start and before the backend, exit 1" case_missing_core_run

case_version_unstamped() {
    rz_setup
    rm "$RZ_TREE/VERSION"
    rz_run --show-prompt fx review
    cz_expect_rc 0
    cz_expect_stdout_has "Provenance for this run: maintainer unstamped (commit unknown), profile fx, task review, backend claude, started $RZ_ISO."
}
cz_case "provenance: a tree with no VERSION file stamps itself 'unstamped' and 'unknown'" case_version_unstamped

case_version_no_commit() {
    rz_setup
    printf 'version=1.2.3\n' > "$RZ_TREE/VERSION"
    rz_run --show-prompt fx review
    cz_expect_rc 0
    cz_expect_stdout_has "Provenance for this run: maintainer 1.2.3 (commit unknown), profile fx, task review, backend claude, started $RZ_ISO."
}
cz_case "provenance: a VERSION file with no commit line gives 'unknown' for the commit only" case_version_no_commit

case_version_in_log_header() {
    rz_setup
    printf 'version=1.2.3\ncommit=fedcba9\n' > "$RZ_TREE/VERSION"
    rz_run fx review
    cz_expect_rc 0
    rz_log_line "maintainer=1.2.3 backend=claude model=opus log=$RZ_LOGS/$RZ_RUNID.log"
    rz_expect_b_not_called codex
}
cz_case "provenance: the log header carries the version from VERSION" case_version_in_log_header

# The shipped doctrine: every placeholder is replaced, and the substituted text is
# the shipped file with the two names filled in, which python does independently.
case_shipped_doctrine() {
    rz_setup
    cp "$MX_TREE/lib/preamble-core.md" "$RZ_TREE/lib/preamble-core.md"
    rz_run --show-prompt fx review
    cz_expect_rc 0
    python3 - "$MX_TREE/lib/preamble-core.md" "$CZ_CASE/stdout" <<'PYEOF' || cz_note_fail "the shipped doctrine is not in the prompt with its two names substituted"
import sys
core = open(sys.argv[1]).read().replace("__MAINTAINER__", "Fixture Maintainer").replace("__SLUG__", "fx/repo")
out = open(sys.argv[2]).read()
assert "__MAINTAINER__" not in out and "__SLUG__" not in out
assert core + "\n\n" in out
PYEOF
}
cz_case "doctrine: the shipped preamble-core.md appears whole with __MAINTAINER__ and __SLUG__ replaced" case_shipped_doctrine

# --- POST=off ---------------------------------------------------------------------------

case_show_post_off_with_wall() {
    rz_setup
    rz_wall
    cz_set MAINTAINER_POST off
    rz_run --show-prompt fx review
    cz_expect_rc 0
    cz_expect_stderr_empty
    rz_want_prompt "$CZ_CASE/want.prompt" review claude off "$RZ_PREVIEW_CONTEXT"
    cz_expect_file_equals "$CZ_CASE/stdout" "$CZ_CASE/want.prompt" "the rehearsal prompt"
}
cz_case "POST=off: the preview swaps the posting notice for the rehearsal notice" case_show_post_off_with_wall

case_show_post_off_no_wall() {
    rz_setup
    cz_set MAINTAINER_POST off
    rz_run --show-prompt fx review
    cz_expect_rc 0
    cz_expect_stderr "run.sh: (preview) no rehearsal wall is rendered in this tree; a real
        run would refuse here. ./install.sh renders it."
    rz_want_prompt "$CZ_CASE/want.prompt" review claude off "$RZ_PREVIEW_CONTEXT"
    cz_expect_file_equals "$CZ_CASE/stdout" "$CZ_CASE/want.prompt" "the rehearsal prompt"
}
cz_case "POST=off: a preview with no rehearsal wall rendered warns on stderr and still prints the prompt, exit 0" case_show_post_off_no_wall

case_run_post_off_no_wall() {
    rz_setup
    cz_set MAINTAINER_POST off
    rz_run fx review
    cz_expect_rc 78
    cz_expect_stdout_empty
    cz_expect_stderr "run.sh: POST=off but backend 'claude' has no rehearsal wall rendered for 'fx'
        re-run ./install.sh, which renders it beside the live wall"
    rz_expect_helper
    rz_expect_gh
    rz_expect_notify_count 0
    # The logs directory is made before the wall is checked; the log file is not.
    cz_expect_file "$RZ_LOGS"
    rz_expect_no_log
}
cz_case "POST=off: a real run with no wall exits 78 before the lock, with two stderr lines, no marker and no toast" case_run_post_off_no_wall

case_post_off_backend_gets_wall() {
    rz_setup
    rz_wall
    cz_set MAINTAINER_POST off
    rz_run fx review
    cz_expect_rc 0
    cz_expect_stderr_empty
    rz_expect_b_env claude MAINTAINER_POST off
    rz_expect_b_env claude MAINTAINER_SETTINGS "$RZ_PROFILE_DIR/settings-rehearsal.json"
    rz_expect_b_argv claude "-p --settings $RZ_PROFILE_DIR/settings-rehearsal.json --permission-mode bypassPermissions --model opus --add-dir $RZ_STATE --output-format stream-json --verbose"
    rz_expect_helper_count "start review" 1
    cz_check "helper sees POST" "$(rz_helper_env start MAINTAINER_POST)" off
    rz_want_prompt "$CZ_CASE/want.prompt" review claude off "$(printf '=== maintainer %s ===\nskill        fixture-skill' "$RZ_RUNID")"
    cz_expect_file_equals "$(rz_b claude.stdin)" "$CZ_CASE/want.prompt" "the prompt the backend read"
}
cz_case "POST=off: the run passes the rehearsal wall to the backend and exports MAINTAINER_POST=off" case_post_off_backend_gets_wall

case_post_on_env() {
    rz_setup
    rz_run fx review
    cz_expect_rc 0
    rz_expect_b_env claude MAINTAINER_POST on
    rz_expect_b_env claude MAINTAINER_SETTINGS "<unset>"
    rz_expect_b_argv claude "-p --settings $RZ_PROFILE_DIR/settings.json --permission-mode bypassPermissions --model opus --add-dir $RZ_STATE --output-format stream-json --verbose"
}
cz_case "POST=on: the live wall is used and MAINTAINER_SETTINGS stays unset" case_post_on_env

# Pins current behaviour: only the exact value "off" is a rehearsal; any other
# value reads as posting, and the prompt prints the value it was given. No plan
# decision yet.
case_post_other_value() {
    rz_setup
    cz_set MAINTAINER_POST maybe
    rz_run --show-prompt fx review
    cz_expect_rc 0
    rz_want_prompt "$CZ_CASE/want.prompt" review claude maybe "$RZ_PREVIEW_CONTEXT"
    cz_expect_file_equals "$CZ_CASE/stdout" "$CZ_CASE/want.prompt" "the prompt"
}
cz_case "POST=off: a POST value other than off posts, and the prompt quotes the value (no plan decision yet)" case_post_other_value

# --- the prompt a real run hands the backend -----------------------------------------------

case_run_prompt_bytes() {
    rz_setup
    rz_run fx review
    cz_expect_rc 0
    rz_want_prompt "$CZ_CASE/want.prompt" review claude on "$(printf '=== maintainer %s ===\nskill        fixture-skill' "$RZ_RUNID")"
    cz_expect_file_equals "$(rz_b claude.stdin)" "$CZ_CASE/want.prompt" "the prompt on the backend's stdin"
}
cz_case "run prompt: the backend reads the same prompt on stdin with the helper's start output as the context" case_run_prompt_bytes

case_run_prompt_context_trailing_newlines() {
    rz_setup
    printf '=== maintainer %s ===\nlast line\n\n\n' "$RZ_RUNID" > "$CZ_CASE/h/start.out"
    rz_run fx review
    cz_expect_rc 0
    rz_want_prompt "$CZ_CASE/want.prompt" review claude on "$(printf '=== maintainer %s ===\nlast line' "$RZ_RUNID")"
    cz_expect_file_equals "$(rz_b claude.stdin)" "$CZ_CASE/want.prompt" "the prompt on the backend's stdin"
}
cz_case "run prompt: trailing blank lines of the helper's output are dropped from the context" case_run_prompt_context_trailing_newlines

case_run_prompt_context_stderr() {
    rz_setup
    printf 'a warning from start\n' > "$CZ_CASE/h/start.err"
    rz_run fx review
    cz_expect_rc 0
    rz_want_prompt "$CZ_CASE/want.prompt" review claude on "$(printf '=== maintainer %s ===\nskill        fixture-skill\na warning from start' "$RZ_RUNID")"
    cz_expect_file_equals "$(rz_b claude.stdin)" "$CZ_CASE/want.prompt" "the prompt on the backend's stdin"
}
cz_case "run prompt: the helper's stderr is merged into the context, after its stdout" case_run_prompt_context_stderr

case_run_prompt_issues() {
    rz_setup
    rz_start_id "$RZ_STAMP-issues"
    rz_run fx issues
    cz_expect_rc 0
    rz_want_prompt "$CZ_CASE/want.prompt" issues claude on "$(printf '=== maintainer %s-issues ===\nskill        fixture-skill' "$RZ_STAMP")"
    cz_expect_file_equals "$(rz_b claude.stdin)" "$CZ_CASE/want.prompt" "the prompt on the backend's stdin"
    rz_expect_helper_count "start issues" 1
    rz_expect_b_env claude MAX_THINKING_TOKENS 16000
}
cz_case "run prompt: the issues task assembles its own prompt and takes its own thinking budget" case_run_prompt_issues

cz_finish
