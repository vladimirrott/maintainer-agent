#!/usr/bin/env bash
# Characterization: the GitHub identity pin, the scrub guard that removes the
# pinned token from what a run leaves behind, and the provisioning of the review
# checkout. Exit codes by value: 1 for a refusal, 75 when the run could not ask.
#
# Pins current behaviour. Plan decisions are named where one applies.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib-run.sh"
cz_init
rz_init

LOGPATH() { printf '%s/%s-review.log' "$RZ_LOGS" "$RZ_STAMP"; }

# A refusal as run.sh gives one: the message on stderr (through tee) and in the log,
# the marker recorded with the helper, a toast, and the exit code by value.
# $1 = exit code, $2 = message, $3 = toast urgency, $4 = toast title, $5 = toast body (no log line)
expect_alert() {
    local log; log="$(LOGPATH)"
    cz_expect_rc "$1"
    cz_expect_stdout_empty
    cz_expect_stderr "$2"
    rz_log_has "$2"
    rz_expect_helper_count "failed review" 1
    grep -qxF -- "$(cz_argv failed review "$2" "$log")" "$CZ_CASE/h/calls" || cz_note_fail "helper was not told: failed review '$2' $log"
    rz_expect_notify_count 1
    rz_expect_notify 1 "$3" "$4" "$(printf '%s\nlog  %s' "$5" "$log")"
}
CRIT_TITLE='maintainer · fx review · FAILED'
LOW_TITLE='maintainer · fx review · will retry'

# --- the account check ---------------------------------------------------------------

case_switch_argv() {
    rz_setup
    rz_run fx review
    cz_expect_rc 0
    rz_expect_gh \
        'auth switch --hostname github.com --user fxacct' \
        'api user --jq .login' \
        'auth token --user fxacct' \
        'api user --jq .login'
}
cz_case "identity: gh is called as auth switch, api user, auth token, api user, in that order, with these arguments" case_switch_argv

case_switch_failure_ignored() {
    rz_setup
    cz_gh_rz auth-switch "" 1
    printf 'no such account\n' > "$CZ_CASE/gh/auth-switch.err"
    rz_run fx review
    cz_expect_rc 0
    cz_expect_stderr_empty
    rz_log_has "no such account"
}
cz_case "identity: a failing gh auth switch is ignored and its output goes to the log" case_switch_failure_ignored

case_wrong_account() {
    rz_setup
    cz_gh_rz api-user "someone-else" 0
    rz_run fx review
    local log; log="$(LOGPATH)"
    expect_alert 1 "gh is authenticated as 'someone-else', not fxacct; refusing to run. See $log" critical "$CRIT_TITLE" \
        "$(printf "gh is authenticated as 'someone-else', not fxacct; refusing to run. See %s\nfix  gh auth switch --user fxacct" "$log")"
    rz_expect_gh 'auth switch --hostname github.com --user fxacct' 'api user --jq .login'
    rz_expect_b_not_called claude
    rz_expect_helper_count "start review" 0
}
cz_case "identity: a different account exits 1 on the first answer, no retry, no token call, no backend" case_wrong_account

case_wrong_account_case_insensitive() {
    rz_setup
    cz_gh_rz api-user "FXAcct" 0
    rz_run fx review
    cz_expect_rc 0
    rz_log_has "gh identity: FXAcct"
}
cz_case "identity: the login is compared case-insensitively and logged as GitHub spelled it" case_wrong_account_case_insensitive

case_wrong_account_profile_case() {
    rz_setup
    rz_profile_add 'GH_ACCOUNT="FxAcct"'
    rz_run fx review
    cz_expect_rc 0
    rz_log_has "gh identity: fxacct"
}
cz_case "identity: the profile's account is compared case-insensitively too" case_wrong_account_profile_case

case_empty_answer() {
    rz_setup
    cz_gh_rz api-user "" 0
    rz_run fx review
    local log; log="$(LOGPATH)"
    expect_alert 75 "gh could not reach GitHub in 3 tries, so the identity was never verified and nothing ran. Check the network, not the token. See $log" low "$LOW_TITLE" \
        "gh could not reach GitHub in 3 tries, so the identity was never verified and nothing ran. Check the network, not the token. See $log"
    rz_expect_gh 'auth switch --hostname github.com --user fxacct' 'api user --jq .login' 'api user --jq .login' 'api user --jq .login'
    rz_log_line "gh api user gave no answer (try 1 of 3); retrying"
    rz_log_line "gh api user gave no answer (try 2 of 3); retrying"
    rz_log_lacks "try 3 of 3"
}
cz_case "identity: an empty answer is tried 3 times then exits 75 as transient, low-urgency toast" case_empty_answer

case_unreachable() {
    rz_setup
    cz_gh_rz api-user "" 1
    printf 'error connecting to api.github.com\n' > "$CZ_CASE/gh/api-user.err"
    rz_run fx review
    cz_expect_rc 75
    cz_expect_stdout_empty
    cz_expect_stderr_has "gh could not reach GitHub in 3 tries"
    rz_log_has "error connecting to api.github.com"
    rz_expect_helper_count "failed review" 1
}
cz_case "identity: gh failing without HTTP 401 is retried 3 times and exits 75, its stderr kept in the log" case_unreachable

case_tries_override() {
    rz_setup
    cz_gh_rz api-user "" 1
    cz_set MAINTAINER_GH_TRIES 1
    rz_run fx review
    cz_expect_rc 75
    cz_expect_stderr_has "gh could not reach GitHub in 1 tries"
    cz_check "api user calls" "$(grep -c '^api user' "$CZ_CASE/gh/calls")" 1
    rz_log_lacks "retrying"
}
cz_case "identity: MAINTAINER_GH_TRIES=1 makes one attempt and says so" case_tries_override

case_retry_then_ok() {
    rz_setup
    cz_gh_rz api-user.1 "" 1
    cz_gh_rz api-user.2 "fxacct" 0
    cz_gh_rz api-user.3 "fxacct" 0
    rz_run fx review
    cz_expect_rc 0
    rz_log_line "gh api user gave no answer (try 1 of 3); retrying"
    rz_log_line "gh identity: fxacct"
    cz_check "api user calls" "$(grep -c '^api user' "$CZ_CASE/gh/calls")" 3
}
cz_case "identity: a second answer that names the account is accepted and the run goes on" case_retry_then_ok

case_backoff_sleeps() {
    rz_setup
    cz_gh_rz api-user "" 1
    cz_set MAINTAINER_GH_BACKOFF 7
    rz_run fx review
    cz_expect_rc 75
    cz_check "sleep calls" "$(tr '\n' ' ' < "$CZ_CASE/sleep.calls")" "7 14 "
}
cz_case "identity: between tries run.sh sleeps backoff x attempt (7 then 14), and not after the last try" case_backoff_sleeps

case_backoff_default() {
    rz_setup
    cz_gh_rz api-user "" 1
    cz_unset MAINTAINER_GH_BACKOFF
    rz_run fx review
    cz_expect_rc 75
    cz_check "sleep calls" "$(tr '\n' ' ' < "$CZ_CASE/sleep.calls")" "20 40 "
}
cz_case "identity: the shipped GH_BACKOFF is 20 seconds, so the sleeps are 20 then 40" case_backoff_default

case_backoff_zero_no_sleep() {
    rz_setup
    cz_gh_rz api-user "" 1
    rz_run fx review
    cz_expect_rc 75
    cz_expect_no_file "$CZ_CASE/sleep.calls"
}
cz_case "identity: a backoff of 0 never calls sleep" case_backoff_zero_no_sleep

case_http_401() {
    rz_setup
    cz_gh_rz api-user '{"message": "Bad credentials"}' 1
    printf 'gh: Bad credentials (HTTP 401)\n' > "$CZ_CASE/gh/api-user.err"
    rz_run fx review
    local log msg; log="$(LOGPATH)"
    msg="GitHub rejected the stored token for fxacct (HTTP 401), so nothing ran. Log in again with: gh auth login -h github.com (as fxacct). See $log"
    expect_alert 1 "$msg" critical "$CRIT_TITLE" "$msg"
    cz_check "api user calls" "$(grep -c '^api user' "$CZ_CASE/gh/calls")" 1
    rz_log_has "gh: Bad credentials (HTTP 401)"
    rz_log_line '{"message": "Bad credentials"}'
}
cz_case "identity: an HTTP 401 exits 1 at once with the re-login instruction, the error body in the log, no retry" case_http_401

# --- the token pin -------------------------------------------------------------------

case_no_token() {
    rz_setup
    cz_gh_rz auth-token "" 0
    rz_run fx review
    local log msg; log="$(LOGPATH)"
    msg="could not pin a token for fxacct, so this run's identity is not guaranteed for the whole pass; refusing rather than risk posting as another account. See $log"
    expect_alert 1 "$msg" critical "$CRIT_TITLE" "$msg"
    rz_expect_helper_count "start review" 0
    rz_expect_b_not_called claude
}
cz_case "token: no token for the account exits 1 and the run never starts" case_no_token

case_token_command_fails() {
    rz_setup
    cz_gh_rz auth-token "" 1
    printf 'no oauth token\n' > "$CZ_CASE/gh/auth-token.err"
    rz_run fx review
    cz_expect_rc 1
    cz_expect_stderr_has "could not pin a token for fxacct"
    rz_log_has "no oauth token"
}
cz_case "token: a failing gh auth token is the same refusal, its stderr kept in the log" case_token_command_fails

case_token_exported() {
    rz_setup
    rz_run fx review
    cz_expect_rc 0
    local calls; calls="$(cat "$CZ_CASE/gh/envlog")"
    cz_check "first api user" "$(sed -n '1p' <<<"$calls")" "auth switch GH_TOKEN=unset GITHUB_TOKEN=unset"
    cz_check "second api user" "$(sed -n '4p' <<<"$calls")" "api user GH_TOKEN=match GITHUB_TOKEN=unset"
    rz_expect_b_env claude GH_TOKEN match
    cz_check "helper start sees the token" "$(grep -c '^start GH_TOKEN=match$' "$CZ_CASE/h/envlog")" 1
}
cz_case "token: GH_TOKEN is exported after the pin and seen by gh, the helper and the backend" case_token_exported

case_github_token_unset() {
    rz_setup
    cz_set GITHUB_TOKEN other-token
    rz_run fx review
    cz_expect_rc 0
    local calls; calls="$(cat "$CZ_CASE/gh/envlog")"
    cz_check "gh before the pin" "$(sed -n '1p' <<<"$calls")" "auth switch GH_TOKEN=unset GITHUB_TOKEN=set"
    cz_check "gh after the pin" "$(sed -n '4p' <<<"$calls")" "api user GH_TOKEN=match GITHUB_TOKEN=unset"
    rz_expect_b_env claude GITHUB_TOKEN "<unset>"
}
cz_case "token: GITHUB_TOKEN from the caller reaches gh until the pin and is unset after it" case_github_token_unset

# Pins current behaviour: the caller's GH_TOKEN is not removed before the first
# gh calls, so the identity check runs under it, not under the keyring. No plan
# decision yet.
case_inherited_gh_token() {
    rz_setup
    cz_set GH_TOKEN caller-token-value
    rz_run fx review
    cz_expect_rc 0
    local calls; calls="$(cat "$CZ_CASE/gh/envlog")"
    cz_check "gh before the pin" "$(sed -n '1p' <<<"$calls")" "auth switch GH_TOKEN=other GITHUB_TOKEN=unset"
    cz_check "gh after the pin" "$(sed -n '4p' <<<"$calls")" "api user GH_TOKEN=match GITHUB_TOKEN=unset"
}
cz_case "token: a GH_TOKEN inherited from the caller reaches the first gh calls and is replaced by the pin" case_inherited_gh_token

case_pinned_mismatch() {
    rz_setup
    cz_gh_rz api-user.1 "fxacct" 0
    cz_gh_rz api-user.2 "someone-else" 0
    rz_plant_leak "$RZ_STATE/leak.txt"
    rz_run fx review
    local log msg; log="$(LOGPATH)"
    msg="the pinned token resolves to 'someone-else', not fxacct; refusing to run. See $log"
    expect_alert 1 "$msg" critical "$CRIT_TITLE" "$msg"
    rz_expect_helper_count "start review" 0
    rz_expect_file_lacks "$RZ_STATE/leak.txt" "$RZ_TOKEN"
}
cz_case "token: a pinned token that resolves to another account exits 1, and the exit scrub already runs" case_pinned_mismatch

case_pinned_error() {
    rz_setup
    cz_gh_rz api-user.2 "" 3
    printf 'dial tcp: lookup api.github.com\n' > "$CZ_CASE/gh/api-user.2.err"
    rz_run fx review
    local log msg; log="$(LOGPATH)"
    msg="the pinned token could not be resolved to an account (gh exited 3), so this run's identity was never confirmed and nothing ran. See $log"
    expect_alert 75 "$msg" low "$LOW_TITLE" "$msg"
    rz_log_has "dial tcp: lookup api.github.com"
    rz_expect_helper_count "start review" 0
}
cz_case "token: the second api user failing exits 75 as transient and names gh's exit status" case_pinned_error

case_pinned_empty() {
    rz_setup
    cz_gh_rz api-user.2 "" 0
    rz_run fx review
    local log msg; log="$(LOGPATH)"
    msg="the pinned token could not be resolved to an account (gh exited 0), so this run's identity was never confirmed and nothing ran. See $log"
    expect_alert 75 "$msg" low "$LOW_TITLE" "$msg"
}
cz_case "token: the second api user answering nothing with status 0 exits 75 and says gh exited 0" case_pinned_empty

case_pinned_log_line() {
    rz_setup
    rz_run fx review
    cz_expect_rc 0
    rz_log_line "gh identity pinned by token for the whole run: fxacct"
}
cz_case "token: the log records the pin only after the second check passed" case_pinned_log_line

case_preview_no_gh() {
    rz_setup
    rz_run --show-prompt fx review
    cz_expect_rc 0
    rz_expect_gh
}
cz_case "identity: a preview makes no gh call" case_preview_no_gh

# --- the scrub guard -----------------------------------------------------------------

sess_dir() { printf '%s/.claude/projects/%s' "$RZ_HOME" "$(printf '%s' "$RZ_STATE/checkout" | tr '/.' '--')"; }

case_scrub_success() {
    rz_setup
    rz_plant_leak "$RZ_STATE/leak.txt"
    rz_plant_leak "$(sess_dir)/session.jsonl"
    rz_backend_behave <<'B'
printf 'agent printed %s\n' "$GH_TOKEN" >> "$CZ_CASE_DIR/home/.local/state/fx-maint/backend-note.txt"
B
    rz_run fx review
    cz_expect_rc 0
    cz_expect_stdout_empty
    cz_expect_stderr_empty
    rz_expect_file_lacks "$RZ_STATE/leak.txt" "$RZ_TOKEN"
    rz_expect_file_has "$RZ_STATE/leak.txt" "before $RZ_MASK after"
    rz_expect_file_lacks "$RZ_STATE/backend-note.txt" "$RZ_TOKEN"
    rz_expect_file_has "$RZ_STATE/backend-note.txt" "agent printed $RZ_MASK"
    rz_expect_file_lacks "$(sess_dir)/session.jsonl" "$RZ_TOKEN"
    rz_expect_file_has "$(sess_dir)/session.jsonl" "before $RZ_MASK after"
    rz_log_has "scrubbed the pinned token from $RZ_STATE/leak.txt"
    rz_log_has "scrubbed the pinned token from $(sess_dir)/session.jsonl"
    rz_log_has "scrubbed the pinned token from $RZ_STATE/backend-note.txt"
}
cz_case "scrub: on success the token is removed from state files and the Claude session directory, and the log says so" case_scrub_success

case_scrub_backend_failure() {
    rz_setup
    rz_plant_leak "$RZ_STATE/leak.txt"
    printf '1' > "$CZ_CASE/b/rc"
    rz_run fx review
    cz_expect_rc 0
    rz_expect_file_lacks "$RZ_STATE/leak.txt" "$RZ_TOKEN"
    rz_expect_file_has "$RZ_STATE/leak.txt" "$RZ_MASK"
}
cz_case "scrub: when the backend fails the token is still removed" case_scrub_backend_failure

case_scrub_finish_failure() {
    rz_setup
    rz_plant_leak "$RZ_STATE/leak.txt"
    printf '1' > "$CZ_CASE/h/finish.rc"
    rz_run fx review
    cz_expect_rc 1
    rz_expect_file_lacks "$RZ_STATE/leak.txt" "$RZ_TOKEN"
}
cz_case "scrub: when finish refuses the report (exit 1) the token is still removed" case_scrub_finish_failure

case_scrub_signal() {
    rz_setup
    rz_plant_leak "$RZ_STATE/leak.txt"
    rz_backend_behave <<'B'
kill -TERM "$PPID"
B
    rz_run fx review
    cz_expect_rc 143
    rz_expect_file_lacks "$RZ_STATE/leak.txt" "$RZ_TOKEN"
    rz_expect_file_has "$RZ_STATE/leak.txt" "$RZ_MASK"
    rz_expect_helper_count "run-lease --clear" 1
    rz_expect_helper_count "finish" 0
    rz_expect_helper_count "digest" 0
}
cz_case "scrub: SIGTERM during the backend ends the run with 143, the exit trap scrubs the token and clears the lease, finish never runs" case_scrub_signal

case_scrub_hangup() {
    rz_setup
    rz_plant_leak "$RZ_STATE/leak.txt"
    rz_backend_behave <<'B'
kill -HUP "$PPID"
B
    rz_run fx review
    cz_expect_rc 129
    rz_expect_file_lacks "$RZ_STATE/leak.txt" "$RZ_TOKEN"
    rz_expect_helper_count "run-lease --clear" 1
    rz_expect_helper_count "finish" 0
}
cz_case "scrub: SIGHUP during the backend ends the run with 129 and still scrubs" case_scrub_hangup

case_scrub_not_before_pin() {
    rz_setup
    cz_gh_rz api-user "someone-else" 0
    rz_plant_leak "$RZ_STATE/leak.txt"
    rz_run fx review
    cz_expect_rc 1
    rz_expect_file_has "$RZ_STATE/leak.txt" "$RZ_TOKEN"
    rz_expect_file_lacks "$RZ_STATE/leak.txt" "$RZ_MASK"
}
cz_case "scrub: a refusal before the token is pinned scrubs nothing (the trap is not set yet)" case_scrub_not_before_pin

case_scrub_binary() {
    rz_setup
    printf 'bin\0%s\0' "$RZ_TOKEN" > "$RZ_STATE/disk.img"
    rz_run fx review
    cz_expect_rc 0
    rz_expect_file_has "$RZ_STATE/disk.img" "$RZ_TOKEN"
    rz_log_has "$RZ_STATE/disk.img  BINARY, not modified: rotate the secret"
}
cz_case "scrub: a file with a NUL byte is left alone and reported as BINARY" case_scrub_binary

case_scrub_skips_dirs() {
    rz_setup
    local d
    for d in .git node_modules target ctargets; do rz_plant_leak "$RZ_STATE/$d/inside.txt"; done
    rz_plant_leak "$RZ_STATE/other/inside.txt"
    rz_run fx review
    cz_expect_rc 0
    for d in .git node_modules target ctargets; do
        rz_expect_file_has "$RZ_STATE/$d/inside.txt" "$RZ_TOKEN"
    done
    rz_expect_file_lacks "$RZ_STATE/other/inside.txt" "$RZ_TOKEN"
}
cz_case "scrub: .git, node_modules, target and ctargets are skipped, any other directory is walked" case_scrub_skips_dirs

case_scrub_reach() {
    rz_setup
    rz_plant_leak "$RZ_HOME/elsewhere/leak.txt"
    rz_plant_leak "$RZ_HOME/.claude/projects/-some-other-project/leak.jsonl"
    rz_run fx review
    cz_expect_rc 0
    rz_expect_file_has "$RZ_HOME/elsewhere/leak.txt" "$RZ_TOKEN"
    rz_expect_file_has "$RZ_HOME/.claude/projects/-some-other-project/leak.jsonl" "$RZ_TOKEN"
}
cz_case "scrub: only STATE_DIR and this repository's own session directory are walked" case_scrub_reach

case_scrub_session_name() {
    rz_setup
    mkdir -p "$RZ_HOME/work.dir/repo/.git"
    cz_set MAINTAINER_REPO_PATH "$RZ_HOME/work.dir/repo"
    local want wrong
    want="$RZ_HOME/.claude/projects/$(printf '%s' "$RZ_HOME/work.dir/repo" | tr '/.' '--')"
    wrong="$RZ_HOME/.claude/projects/$(printf '%s' "$RZ_HOME/work.dir/repo" | tr '/' '-')"
    rz_plant_leak "$want/s.jsonl"
    rz_plant_leak "$wrong/s.jsonl"
    rz_run fx review
    cz_expect_rc 0
    rz_expect_file_lacks "$want/s.jsonl" "$RZ_TOKEN"
    rz_expect_file_has "$wrong/s.jsonl" "$RZ_TOKEN"
}
cz_case "scrub: the session directory name turns every / and . of the repository path into -" case_scrub_session_name

case_scrub_short_token() {
    rz_setup
    printf 'shorttoken\n' > "$CZ_CASE/token"
    cz_gh_rz auth-token "shorttoken" 0
    printf 'before shorttoken after\n' > "$RZ_STATE/leak.txt"
    rz_run fx review
    cz_expect_rc 0
    rz_expect_file_has "$RZ_STATE/leak.txt" "shorttoken"
    rz_log_lacks "scrubbed the pinned token"
}
# Pins current behaviour: a token shorter than 16 characters is refused by the
# scrubber, which returns 1; run.sh ignores that, so nothing is removed and nothing is logged.
cz_case "scrub: a pinned token under 16 characters is never scrubbed and the run does not notice" case_scrub_short_token

case_scrub_trap_keeps_status() {
    rz_setup
    printf '1' > "$CZ_CASE/b/rc"
    printf '1' > "$CZ_CASE/h/finish.rc"
    rz_run fx review
    cz_expect_rc 1
}
cz_case "scrub: the exit trap hands back the status the run was exiting with" case_scrub_trap_keeps_status

case_scrub_leaves_no_secret_in_argv() {
    rz_setup
    rz_backend_behave <<'B'
printf '%s\n' "$$" > "$CZ_CASE_DIR/b/pid"
B
    rz_run fx review
    cz_expect_rc 0
    local f
    for f in "$CZ_CASE"/gh/calls "$CZ_CASE"/h/calls "$CZ_CASE"/b/claude.argv "$CZ_CASE"/notify.calls; do
        [ -e "$f" ] || continue
        if grep -qF -- "$RZ_TOKEN" "$f"; then cz_note_fail "the token appears in an argv log: $f"; fi
    done
}
cz_case "scrub: the token never appears in the argv of gh, the helper, the backend or the toast" case_scrub_leaves_no_secret_in_argv

# --- the review checkout -------------------------------------------------------------

case_clone_origin() {
    rz_setup
    local origin="$CZ_CASE/origin"
    mkdir -p "$origin"
    ( cd "$origin" && git init -q -b main . && printf 'x\n' > f && git add f \
      && git -c user.name=t -c user.email=t@example.invalid commit -q -m init ) || cz_note_fail "could not build the origin"
    rm -rf "$RZ_STATE/checkout"
    cz_set MAINTAINER_REPO_ORIGIN "$origin"
    rz_run fx review
    cz_expect_rc 0
    cz_expect_file "$RZ_STATE/checkout/.git"
    cz_expect_file "$RZ_STATE/checkout/f"
    rz_log_has "provisioning review checkout: $origin -> $RZ_STATE/checkout"
    rz_expect_helper_count "start review" 1
}
cz_case "checkout: a missing checkout is cloned from REPO_ORIGIN and the log says so" case_clone_origin

case_clone_fails() {
    rz_setup
    rm -rf "$RZ_STATE/checkout"
    cz_set MAINTAINER_REPO_ORIGIN "$CZ_CASE/no-such-origin"
    rz_run fx review
    local log msg; log="$(LOGPATH)"
    msg="could not clone $CZ_CASE/no-such-origin into $RZ_STATE/checkout; no review checkout, nothing ran. See $log"
    expect_alert 1 "$msg" critical "$CRIT_TITLE" "$msg"
    rz_expect_helper_count "start review" 0
}
cz_case "checkout: a failing clone exits 1 with the alert" case_clone_fails

case_no_origin() {
    rz_setup
    rm -rf "$RZ_STATE/checkout"
    rz_run fx review
    local log msg; log="$(LOGPATH)"
    msg="$RZ_STATE/checkout is not a git checkout and the profile sets no REPO_ORIGIN to clone from; refusing to run. See $log"
    expect_alert 1 "$msg" critical "$CRIT_TITLE" "$msg"
    rz_expect_helper_count "start review" 0
}
cz_case "checkout: a missing checkout and no REPO_ORIGIN exits 1 with the alert" case_no_origin

case_checkout_is_dir_without_git() {
    rz_setup
    rm -rf "$RZ_STATE/checkout/.git"
    rz_run fx review
    cz_expect_rc 1
    cz_expect_stderr_has "is not a git checkout and the profile sets no REPO_ORIGIN"
}
cz_case "checkout: an existing directory with no .git counts as missing" case_checkout_is_dir_without_git

case_backend_cwd() {
    rz_setup
    rz_run fx review
    cz_expect_rc 0
    rz_expect_b_env claude PWD "$RZ_STATE/checkout"
}
cz_case "checkout: the backend runs with the review checkout as its working directory" case_backend_cwd

cz_finish
