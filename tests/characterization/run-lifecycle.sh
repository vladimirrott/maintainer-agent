#!/usr/bin/env bash
# Characterization: the life of a run once the identity is pinned. The helper's
# start and finish, the log and its rename, what each failure writes and says,
# the toast text for each failure shape, the alert hook, and the digest. Exit
# codes by value: 0, 1 and 75.
#
# Pins current behaviour. Plan decisions are named where one applies: F6 for the
# log-stem mismatch.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib-run.sh"
cz_init
rz_init

LOG="" HELPER_PATH=""
setup() {
    rz_setup
    LOG="$RZ_LOGS/$RZ_RUNID.log"
    HELPER_PATH="$RZ_HOME/.local/bin/maintainer"
}
CRIT_TITLE='maintainer · fx review · FAILED'
LOW_TITLE='maintainer · fx review · will retry'

# expect_marker MESSAGE: the helper was told `failed review MESSAGE LOG`.
expect_marker() {
    grep -qxF -- "$(cz_argv failed review "$1" "$LOG")" "$CZ_CASE/h/calls" \
        || cz_note_fail "helper was not told: failed review '$1' $LOG (calls: $(tr '\n' '|' < "$CZ_CASE/h/calls" | cut -c1-500))"
}
# expect_toast N URGENCY TITLE BODY: the Nth toast, with the log line added.
expect_toast() { rz_expect_notify "$1" "$2" "$3" "$(printf '%s\nlog  %s' "$4" "$LOG")"; }

# --- the success path ---------------------------------------------------------------

case_success_shape() {
    setup
    rz_run fx review
    cz_expect_rc 0
    cz_expect_stdout_empty
    cz_expect_stderr_empty
    rz_log_line "=== run.sh fx/review $RZ_ISO ==="
    rz_log_line "maintainer=9.9.9 backend=claude model=opus log=$LOG"
    rz_log_line "gh identity: fxacct"
    rz_log_line "=== done $RZ_ISO ==="
    cz_check "last log line" "$(tail -1 "$LOG")" "=== done $RZ_ISO ==="
    cz_check "first log line" "$(head -1 "$LOG")" "=== run.sh fx/review $RZ_ISO ==="
}
cz_case "success: nothing on stdout or stderr, a header and a done line in the log, exit 0" case_success_shape

case_success_log_order() {
    setup
    rz_run fx review
    cz_expect_rc 0
    local want="$CZ_CASE/want.log"
    {
        printf '=== run.sh fx/review %s ===\n' "$RZ_ISO"
        printf 'maintainer=9.9.9 backend=claude model=opus log=%s\n' "$LOG"
        printf 'gh identity: fxacct\n'
        printf 'gh identity pinned by token for the whole run: fxacct\n'
        printf '=== maintainer %s ===\nskill        fixture-skill\n' "$RZ_RUNID"
        printf 'agent says hello\n'
        printf 'finished %s\n' "$RZ_RUNID"
        printf '\n=== digest ===\ndigest-line-from-helper\n'
        printf '=== done %s ===\n' "$RZ_ISO"
    } > "$want"
    cz_expect_file_equals "$LOG" "$want" "the log"
}
cz_case "success: the log holds exactly the header, pin lines, helper start, agent text, finish, digest and done, in that order" case_success_log_order

case_digest_notice() {
    setup
    printf 'line one\nline two\n' > "$CZ_CASE/h/digest.out"
    rz_run fx review
    cz_expect_rc 0
    rz_expect_notify_count 1
    rz_expect_notify 1 normal "maintainer · fx review" "$(printf 'line one\nline two')"
    rz_log_line "=== digest ==="
}
cz_case "success: the digest becomes one normal-urgency toast titled with profile and task" case_digest_notice

case_digest_empty() {
    setup
    : > "$CZ_CASE/h/digest.out"
    rz_run fx review
    cz_expect_rc 0
    rz_expect_notify_count 0
    rz_log_lacks "=== digest ==="
}
cz_case "success: an empty digest sends no toast and writes no digest section" case_digest_empty

case_digest_fails() {
    setup
    printf 'half a digest\n' > "$CZ_CASE/h/digest.out"
    printf '1' > "$CZ_CASE/h/digest.rc"
    rz_run fx review
    cz_expect_rc 0
    rz_expect_notify_count 0
    rz_log_lacks "half a digest"
    rz_expect_helper_count "digest $RZ_RUNID --compact" 1
}
cz_case "success: a failing digest is dropped without a toast and the run still exits 0" case_digest_fails

case_notify_off() {
    setup
    cz_set MAINTAINER_NOTIFY off
    rz_run fx review
    cz_expect_rc 0
    rz_expect_notify_count 0
    cz_expect_no_file "$CZ_CASE/loginctl.calls"
}
cz_case "success: MAINTAINER_NOTIFY=off sends nothing and does not even ask loginctl" case_notify_off

case_notify_display_default() {
    setup
    rz_run fx review
    cz_expect_rc 0
    cz_check "loginctl calls" "$(tr '\n' '|' < "$CZ_CASE/loginctl.calls")" "show-user fixture-user -p Display --value|show-session '' -p Display --value|"
    rz_expect_notify 1 normal "maintainer · fx review" "digest-line-from-helper" ":0"
}
cz_case "notify: with no session answer and no DISPLAY the toast goes to :0, after two loginctl calls" case_notify_display_default

case_notify_display_env() {
    setup
    cz_set DISPLAY :7
    rz_run fx review
    cz_expect_rc 0
    rz_expect_notify 1 normal "maintainer · fx review" "digest-line-from-helper" ":7"
}
cz_case "notify: the caller's DISPLAY is used when loginctl says nothing" case_notify_display_env

case_notify_display_session() {
    setup
    cz_set DISPLAY :7
    printf ':9\n' > "$CZ_CASE/loginctl.out"
    rz_run fx review
    cz_expect_rc 0
    rz_expect_notify 1 normal "maintainer · fx review" "digest-line-from-helper" ":9"
    cz_check "second loginctl call" "$(sed -n '2p' "$CZ_CASE/loginctl.calls")" "show-session :9 -p Display --value"
}
cz_case "notify: the display loginctl reports wins over DISPLAY" case_notify_display_session

case_notify_no_user() {
    setup
    cz_unset USER
    rz_run fx review
    cz_expect_rc 0
    cz_check "first loginctl call" "$(sed -n '1p' "$CZ_CASE/loginctl.calls")" "show-user $(id -un) -p Display --value"
    rz_expect_notify_count 1
}
cz_case "notify: with USER unset the user name comes from id -un" case_notify_no_user

# --- the helper's start --------------------------------------------------------------

case_start_fails() {
    setup
    printf '1' > "$CZ_CASE/h/start.rc"
    printf 'refresh exploded\n' > "$CZ_CASE/h/start.out"
    printf 'and a stderr line\n' > "$CZ_CASE/h/start.err"
    rz_run fx review
    local msg="refresh failed, no agent run started. See $LOG"
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr "$msg"
    rz_log_line "refresh exploded"
    rz_log_line "and a stderr line"
    expect_marker "$msg"
    expect_toast 1 critical "$CRIT_TITLE" "$(printf 'The checkout could not be refreshed, so no agent ran.\nfix  maintainer-doctor')"
    rz_expect_b_not_called claude
    rz_expect_helper_count "finish" 0
}
cz_case "start: a failing start exits 1 with the refresh message, its stdout and stderr in the log, the matching fix in the toast" case_start_fails

case_start_no_id() {
    setup
    printf 'no header here\n' > "$CZ_CASE/h/start.out"
    rz_run fx review
    local msg="could not parse a run id from '$HELPER_PATH start'. See $LOG"
    cz_expect_rc 1
    cz_expect_stderr "$msg"
    expect_marker "$msg"
    expect_toast 1 critical "$CRIT_TITLE" "$msg"
    rz_expect_b_not_called claude
}
cz_case "start: output without a === header === line exits 1 naming the helper" case_start_no_id

case_start_first_header_wins() {
    setup
    printf '=== note extra ===\n=== maintainer %s ===\n' "$RZ_RUNID" > "$CZ_CASE/h/start.out"
    rz_run fx review
    cz_expect_rc 0
    rz_expect_helper_count "run-lease review \\<ppid\\> extra" 1
    rz_expect_helper_count "finish extra" 1
}
# Pins current behaviour: the run id is whatever the first line shaped like
# "=== word ... ===" carries. No plan decision yet.
cz_case "start: the first line shaped like a header gives the run id, whatever its first word" case_start_first_header_wins

case_start_header_needs_lowercase_word() {
    setup
    printf '=== Maintainer %s ===\n' "$RZ_RUNID" > "$CZ_CASE/h/start.out"
    rz_run fx review
    cz_expect_rc 1
    cz_expect_stderr_has "could not parse a run id"
}
cz_case "start: a header whose first word has a capital letter is not a run id" case_start_header_needs_lowercase_word

# --- the log name ---------------------------------------------------------------------

case_log_renamed() {
    setup
    rz_start_id "2026-02-02T02-02-review"
    rz_run fx review
    cz_expect_rc 0
    local new="$RZ_LOGS/2026-02-02T02-02-review.log"
    cz_expect_no_file "$RZ_LOGS/$RZ_RUNID.log"
    cz_expect_file "$new"
    rz_expect_file_has "$new" "log renamed to match run id 2026-02-02T02-02-review"
    cz_check "first line kept" "$(head -1 "$new")" "=== run.sh fx/review $RZ_ISO ==="
    rz_expect_helper_count "run-lease review \\<ppid\\> 2026-02-02T02-02-review" 1
    cz_expect_file "$RZ_LOGS/2026-02-02T02-02-review.commands"
}
cz_case "log: a run id different from the start-time name renames the log, keeps its lines, and the commands file follows the new name" case_log_renamed

case_log_folded() {
    setup
    rz_start_id "2026-02-02T02-02-review"
    mkdir -p "$RZ_LOGS"
    printf 'an earlier run wrote this\n' > "$RZ_LOGS/2026-02-02T02-02-review.log"
    rz_run fx review
    cz_expect_rc 0
    local new="$RZ_LOGS/2026-02-02T02-02-review.log"
    cz_expect_no_file "$RZ_LOGS/$RZ_RUNID.log"
    cz_check "first line is the earlier run's" "$(head -1 "$new")" "an earlier run wrote this"
    rz_expect_file_has "$new" "=== run.sh fx/review $RZ_ISO ==="
    rz_expect_file_has "$new" "log renamed to match run id 2026-02-02T02-02-review"
}
cz_case "log: an existing log under the run id is never replaced, this run's lines are appended to it" case_log_folded

# Pins plan decision F6. The helper names a second run of the same minute
# "<stamp>-<task>.2" and looks for logs and commands under "<stamp>-<task>"; run.sh
# renames its log to the full run id, so the two disagree.
case_log_stem_mismatch() {
    setup
    rz_start_id "$RZ_RUNID.2"
    rz_run fx review
    cz_expect_rc 0
    cz_expect_file "$RZ_LOGS/$RZ_RUNID.2.log"
    cz_expect_no_file "$RZ_LOGS/$RZ_RUNID.log"
    cz_expect_file "$RZ_LOGS/$RZ_RUNID.2.commands"
    cz_expect_no_file "$RZ_LOGS/$RZ_RUNID.commands"
}
cz_case "log: a run id with a .2 suffix names the log <id>.2.log, not the stem the helper reads (plan decision F6)" case_log_stem_mismatch

# --- the failure paths ---------------------------------------------------------------

case_finish_fails() {
    setup
    printf '1' > "$CZ_CASE/h/finish.rc"
    printf 'error: report is empty\n' > "$CZ_CASE/h/finish.out"
    rz_run fx review
    local msg="$RZ_RUNID produced no report; the run is not auditable. See $LOG"
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr "$msg"
    rz_log_line "error: report is empty"
    expect_marker "$msg"
    expect_toast 1 critical "$CRIT_TITLE" "$(printf 'The run ended without writing a report, so it is not auditable.\nfix  read the log below')"
    grep -qxF -- "$(cz_argv abort "$RZ_RUNID" "no report; unclassified: error: report is empty")" "$CZ_CASE/h/calls" \
        || cz_note_fail "abort was not called with the classified cause: $(tr '\n' '|' < "$CZ_CASE/h/calls")"
    rz_expect_helper_count "digest" 0
    rz_log_lacks "=== done"
}
cz_case "failure: finish refusing an empty report exits 1, aborts the run with the classified cause, alerts critical" case_finish_fails

case_finish_stderr_in_log() {
    setup
    printf 'finish stdout line\n' > "$CZ_CASE/h/finish.out"
    printf 'finish stderr line\n' > "$CZ_CASE/h/finish.err"
    rz_run fx review
    cz_expect_rc 0
    cz_expect_stderr_empty
    rz_log_line "finish stdout line"
    rz_log_line "finish stderr line"
}
cz_case "success: the helper's stderr from finish is kept in the log beside its stdout, and nothing reaches the terminal" case_finish_stderr_in_log

case_finish_refused_fixture() {
    setup
    printf '1' > "$CZ_CASE/h/finish.rc"
    printf 'this is a fixture rather than a report\n' > "$CZ_CASE/h/finish.out"
    rz_run fx review
    local msg="$RZ_RUNID wrote a report that finish refused (fixture rather than a report). Read runs/$RZ_RUNID.md and $LOG"
    cz_expect_rc 1
    cz_expect_stderr "$msg"
    expect_marker "$msg"
    expect_toast 1 critical "$CRIT_TITLE" "$msg"
    grep -qxF -- "$(cz_argv abort "$RZ_RUNID" "report refused by finish: fixture rather than a report (see runs/$RZ_RUNID.md)")" "$CZ_CASE/h/calls" \
        || cz_note_fail "abort was not called with the refusal: $(tr '\n' '|' < "$CZ_CASE/h/calls")"
}
cz_case "failure: a report finish calls a fixture is aborted with that reason and alerted as refused, exit 1" case_finish_refused_fixture

case_finish_fails_after_backend_failure() {
    setup
    printf '1' > "$CZ_CASE/b/rc"
    rz_set_backend_out 'something unknown broke'
    printf '1' > "$CZ_CASE/h/finish.rc"
    rz_run fx review
    local first="claude exited non-zero for $RZ_RUNID. See $LOG"
    local second="$RZ_RUNID produced no report, and the claude failure above is why. See $LOG"
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr "$first
$second"
    rz_log_has "$second"
    expect_marker "$first"
    rz_expect_helper_count "failed review" 1
    rz_expect_notify_count 1
    expect_toast 1 critical "$CRIT_TITLE" "$first"
}
cz_case "failure: a failed backend and no report give one alert and one plain line, not two alerts, exit 1" case_finish_fails_after_backend_failure

case_backend_failure_report_ok() {
    setup
    printf '1' > "$CZ_CASE/b/rc"
    rz_set_backend_out 'something unknown broke'
    rz_run fx review
    local msg="claude exited non-zero for $RZ_RUNID. See $LOG"
    cz_expect_rc 0
    cz_expect_stderr "$msg"
    expect_marker "$msg"
    rz_expect_helper_count "finish $RZ_RUNID" 1
    rz_expect_helper_count "digest" 1
    rz_log_has "=== done $RZ_ISO ==="
}
cz_case "failure: a failed backend whose report finish accepts alerts once and still exits 0" case_backend_failure_report_ok

case_backend_transient() {
    setup
    printf '1' > "$CZ_CASE/b/rc"
    rz_set_backend_out "You've hit your session limit, resets 10:10pm"
    rz_run fx review
    local msg="the claude backend stopped on something that clears itself (You've hit your session limit, resets 10:10pm); the next slot retries this task"
    cz_expect_rc 0
    cz_expect_stderr "$msg"
    expect_marker "$msg"
    expect_toast 1 low "$LOW_TITLE" "$msg"
}
cz_case "failure: a session-limit stop is reported as transient at low urgency, and a finished report keeps exit 0" case_backend_transient

case_backend_transient_no_report() {
    setup
    printf '1' > "$CZ_CASE/b/rc"
    rz_set_backend_out "You've hit your session limit, resets 10:10pm"
    printf '1' > "$CZ_CASE/h/finish.rc"
    rz_run fx review
    local why="You've hit your session limit, resets 10:10pm"
    local msg="$RZ_RUNID wrote no report: the claude backend stopped on $why"
    cz_expect_rc 75
    cz_expect_stderr_has "$msg"
    expect_marker "$msg"
    # The classifier reads the whole log, and the log already holds the alert for
    # the backend stop, which repeats the phrase. The last match is on that alert
    # line, and its trailing {0,60} takes the rest of the sentence with it.
    grep -qxF -- "$(cz_argv abort "$RZ_RUNID" "no report; transient/session-limit: $why); the next slot retries this task")" "$CZ_CASE/h/calls" \
        || cz_note_fail "abort did not carry the classification: $(tr '\n' '|' < "$CZ_CASE/h/calls")"
    rz_expect_notify_count 2
    expect_toast 2 low "$LOW_TITLE" "$msg"
}
cz_case "failure: a transient stop with no report aborts with the class and id, then exits 75" case_backend_transient_no_report

human_case() {  # $1 backend output line, $2 expected cause text, $3 expected toast body, or "generic"
    setup
    printf '1' > "$CZ_CASE/b/rc"
    rz_set_backend_out "$1"
    rz_run fx review
    local msg="the claude backend stopped on something only you can clear ($2), and every slot after this one fails the same way until it is. See $LOG"
    cz_expect_rc 0
    cz_expect_stderr "$msg"
    expect_marker "$msg"
    if [ "$3" = generic ]; then
        expect_toast 1 critical "$CRIT_TITLE" "$(printf '%s\nfix  claude /login, then: maintainer-doctor' "$msg")"
    else
        expect_toast 1 critical "$CRIT_TITLE" "$3"
    fi
}
case_human_credit() { human_case "Your credit balance is too low to access the API" "Your credit balance is too low to access the API" \
    "$(printf 'The backend account is out of credit. No retry pays an invoice.\nfix  top up the account, then: maintainer-doctor')"; }
cz_case "failure: an empty credit balance is needs-human at critical with the top-up fix" case_human_credit

case_human_oauth() { human_case "OAuth session expired. Please log in" "OAuth session expired. Please log in" \
    "$(printf 'The backend login has expired, so every slot fails until you renew it.\nfix  claude /login')"; }
cz_case "failure: an expired OAuth session is needs-human with the login fix" case_human_oauth

case_human_failed_auth() { human_case "Failed to authenticate. API Error: 401" "Failed to authenticate. API Error: 401" \
    "$(printf 'The backend login has expired, so every slot fails until you renew it.\nfix  claude /login')"; }
cz_case "failure: 'Failed to authenticate' gets the same login fix" case_human_failed_auth

case_human_invalid_key() {
    local cause="Invalid API key. Fix external API key"
    human_case "$cause" "$cause" generic
}
cz_case "failure: any other needs-human cause gets the generic 'only you can clear' fix, with the whole message" case_human_invalid_key

case_human_unmatched_backend_text() {
    setup
    printf '1' > "$CZ_CASE/b/rc"
    rz_set_backend_out "nothing the table knows"
    rz_run fx review
    cz_expect_rc 0
    expect_toast 1 critical "$CRIT_TITLE" "claude exited non-zero for $RZ_RUNID. See $LOG"
}
cz_case "failure: an unclassified backend failure reaches the toast verbatim, with no fix line" case_human_unmatched_backend_text

# --- the toast text for each refusal --------------------------------------------------

case_toast_not_on_path() {
    setup
    rm "$CZ_CASE/bin/claude"
    rz_run fx review
    local msg="backend claude unusable: claude not on PATH"
    cz_expect_rc 1
    cz_expect_stderr "$msg"
    expect_marker "$msg"
    expect_toast 1 critical "$CRIT_TITLE" "$(printf '%s\nfix  install it, then: maintainer-doctor' "$msg")"
}
cz_case "toast: a backend not on PATH repeats the message and adds the install fix" case_toast_not_on_path

case_toast_missing_settings() {
    setup
    rm "$RZ_PROFILE_DIR/settings.json"
    rz_run fx review
    local msg="backend claude unusable: missing $RZ_PROFILE_DIR/settings.json"
    cz_expect_rc 1
    cz_expect_stderr "$msg"
    expect_toast 1 critical "$CRIT_TITLE" "$(printf 'Claude Code has no settings file for this profile.\nfix  ./install.sh')"
}
cz_case "toast: a missing settings file gets the install fix and not the path" case_toast_missing_settings

case_toast_codex_post_off() {
    setup
    cz_set MAINTAINER_BACKEND codex
    cz_set MAINTAINER_POST off
    rz_run fx review
    local msg="backend 'codex' cannot enforce POST=off (no per-command deny list); use claude or opencode"
    cz_expect_rc 78
    cz_expect_stderr "$msg"
    expect_marker "$msg"
    expect_toast 1 critical "$CRIT_TITLE" "$(printf '%s\nfix  set BACKEND=claude or BACKEND=opencode in profile.env' "$msg")"
}
cz_case "toast: POST=off on a backend without a deny list exits 78 with the profile.env fix" case_toast_codex_post_off

case_toast_lock_text() {
    setup
    printf '1' > "$CZ_CASE/flock.rc"
    rz_run fx review
    cz_expect_rc 75
    rz_expect_notify 1 low "$LOW_TITLE" "$(printf 'Another run held the shared tree for over 3600s.\nfix  maintainer status, then wait or kill it\nlog  %s' "$LOG")"
}
cz_case "toast: a held lock says how long it waited and what to run" case_toast_lock_text

case_toast_transient_verbatim() {
    setup
    cz_gh_rz api-user "" 1
    rz_run fx review
    local msg="gh could not reach GitHub in 3 tries, so the identity was never verified and nothing ran. Check the network, not the token. See $LOG"
    cz_expect_rc 75
    expect_toast 1 low "$LOW_TITLE" "$msg"
}
cz_case "toast: a message no shape matches reaches the toast verbatim" case_toast_transient_verbatim

# --- the alert hook ------------------------------------------------------------------

case_alert_cmd() {
    setup
    cz_gh_rz api-user "someone-else" 0
    cz_set MAINTAINER_ALERT_CMD 'printf "%s|%s|%s|%s\n" "$MAINTAINER_ALERT_TASK" "$MAINTAINER_ALERT_LOG" "$0" "$1" > "$CZ_CASE_DIR/alert.out"; echo hook-output'
    rz_run fx review
    local msg="gh is authenticated as 'someone-else', not fxacct; refusing to run. See $LOG"
    cz_expect_rc 1
    cz_check "alert hook record" "$(cat "$CZ_CASE/alert.out")" "fx/review|$LOG|$RZ_TREE/lib/run.sh|$msg"
    rz_log_line "hook-output"
}
cz_case "alert hook: MAINTAINER_ALERT_CMD runs under sh -c with the task, the log, run.sh as \$0 and the message as \$1, its output in the log" case_alert_cmd

case_alert_cmd_fails() {
    setup
    cz_gh_rz api-user "someone-else" 0
    cz_set MAINTAINER_ALERT_CMD 'exit 3'
    rz_run fx review
    cz_expect_rc 1
    rz_log_line "run.sh: MAINTAINER_ALERT_CMD failed; the marker and the log still stand"
    cz_expect_stderr_first "gh is authenticated as 'someone-else', not fxacct; refusing to run. See $LOG"
}
cz_case "alert hook: a failing hook is noted in the log and never changes the exit code" case_alert_cmd_fails

case_alert_cmd_not_for_transient() {
    setup
    printf '1' > "$CZ_CASE/flock.rc"
    cz_set MAINTAINER_ALERT_CMD 'echo ran > "$CZ_CASE_DIR/alert.out"'
    rz_run fx review
    cz_expect_rc 75
    cz_expect_no_file "$CZ_CASE/alert.out"
}
cz_case "alert hook: a transient failure does not call the hook" case_alert_cmd_not_for_transient

case_marker_fails() {
    setup
    cz_gh_rz api-user "someone-else" 0
    printf '1' > "$CZ_CASE/h/failed.rc"
    rz_run fx review
    cz_expect_rc 1
    cz_expect_stderr "gh is authenticated as 'someone-else', not fxacct; refusing to run. See $LOG
run.sh: could not even record the failure marker"
}
cz_case "alert: a helper that cannot record the marker adds one stderr line and the exit code stays 1" case_marker_fails

case_marker_fails_transient() {
    setup
    printf '1' > "$CZ_CASE/flock.rc"
    printf '1' > "$CZ_CASE/h/failed.rc"
    rz_run fx review
    cz_expect_rc 75
    cz_expect_stderr "another run held the lock for over 3600s, so this one never started
run.sh: could not even record the failure marker"
}
cz_case "alert: the same marker failure on a transient alert keeps exit 75" case_marker_fails_transient

case_marker_output_hidden() {
    setup
    cz_gh_rz api-user "someone-else" 0
    printf 'marker stdout\n' > "$CZ_CASE/h/failed.out"
    printf 'marker stderr\n' > "$CZ_CASE/h/failed.err"
    rz_run fx review
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr_lacks_marker
}
cz_expect_stderr_lacks_marker() { cz_expect_lacks stderr "marker std"; rz_log_lacks "marker std"; }
cz_case "alert: the helper's own output while recording the marker is discarded" case_marker_output_hidden

cz_finish
