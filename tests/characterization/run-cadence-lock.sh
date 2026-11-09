#!/usr/bin/env bash
# Characterization: the two gates that decide whether a run goes ahead at all
# (the cadence gate, consulted twice, and the run lock) and the run lease that
# labels the lock. Exit codes by value: 0 for a skip, 75 for a held lock.
#
# Pins current behaviour where bash does something odd. Plan decisions named in
# the comments; "no plan decision yet" where none covers it.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib-run.sh"
cz_init
rz_init

# --- the cadence gate ------------------------------------------------------------

skip_line() {  # $1 task, $2 age in hours, $3 minimum, $4 suffix (optional)
    printf 'skipped: %s last ran %sh ago, minimum is %sh%s (MAINTAINER_FORCE=1 overrides)' "$1" "$2" "$3" "${4:+, $4}"
}

case_skip() {
    rz_setup
    rz_last_ran review 3600
    rz_run fx review
    cz_expect_rc 0
    cz_expect_stdout "$(skip_line review 1 6)"
    cz_expect_stderr_empty
    rz_expect_helper
    rz_expect_gh
    rz_expect_no_logs_dir
    cz_expect_no_file "$RZ_STATE/run.lock"
    rz_expect_b_not_called claude
    rz_expect_notify_count 0
}
cz_case "cadence: a task that ran 1h ago with a 6h minimum is skipped, exit 0, message on stdout, nothing touched" case_skip

case_skip_floor() {
    rz_setup
    rz_last_ran review 21599
    rz_run fx review
    cz_expect_rc 0
    cz_expect_stdout "$(skip_line review 5 6)"
}
cz_case "cadence: the age is floored to whole hours, so 5h59m59s reads 5h and skips" case_skip_floor

case_boundary_runs() {
    rz_setup
    rz_last_ran review 21600
    rz_run fx review
    cz_expect_rc 0
    cz_expect_stdout_empty
    rz_expect_helper_count "start review" 1
}
cz_case "cadence: exactly the minimum age runs" case_boundary_runs

case_force() {
    rz_setup
    rz_last_ran review 3600
    cz_set MAINTAINER_FORCE 1
    rz_run fx review
    cz_expect_rc 0
    cz_expect_stdout_empty
    rz_expect_helper_count "start review" 1
}
cz_case "cadence: MAINTAINER_FORCE=1 overrides the gate" case_force

case_force_only_one() {
    rz_setup
    rz_last_ran review 3600
    cz_set MAINTAINER_FORCE true
    rz_run fx review
    cz_expect_rc 0
    cz_expect_stdout "$(skip_line review 1 6)"
    rz_expect_helper
}
cz_case "cadence: MAINTAINER_FORCE=true is not 1 and does not force" case_force_only_one

case_force_zero() {
    rz_setup
    rz_last_ran review 3600
    cz_set MAINTAINER_FORCE 0
    rz_run fx review
    cz_expect_rc 0
    cz_expect_stdout "$(skip_line review 1 6)"
}
cz_case "cadence: MAINTAINER_FORCE=0 does not force" case_force_zero

case_no_stamp() {
    rz_setup
    rz_run fx review
    cz_expect_rc 0
    cz_expect_stdout_empty
    rz_expect_helper_count "start review" 1
}
cz_case "cadence: no last-<task>.json means the task has never run, so it runs" case_no_stamp

case_min_zero() {
    rz_setup
    rz_profile_add 'MIN_HOURS_review=0'
    rz_last_ran review 60
    rz_run fx review
    cz_expect_rc 0
    cz_expect_stdout_empty
    rz_expect_helper_count "start review" 1
}
cz_case "cadence: a minimum of 0 turns the gate off" case_min_zero

case_min_unset() {
    rz_setup
    rz_profile_add 'unset MIN_HOURS_review'
    rz_last_ran review 60
    rz_run fx review
    cz_expect_rc 0
    cz_expect_stdout_empty
    rz_expect_helper_count "start review" 1
}
cz_case "cadence: a task with no MIN_HOURS_<task> has no gate" case_min_unset

case_min_zero_future_stamp() {
    rz_setup
    rz_profile_add 'MIN_HOURS_review=0'
    rz_last_ran review -7200
    rz_run fx review
    cz_expect_rc 0
    cz_expect_stdout_empty
    rz_expect_helper_count "start review" 1
}
# A stamp in the future gives a negative age; only the early return for a minimum
# of 0 keeps that from reading as "younger than the minimum".
cz_case "cadence: a minimum of 0 turns the gate off even for a stamp in the future" case_min_zero_future_stamp

case_no_stamp_huge_minimum() {
    rz_setup
    rz_profile_add 'MIN_HOURS_review=999999999'
    rz_run fx review
    cz_expect_rc 0
    cz_expect_stdout_empty
    rz_expect_helper_count "start review" 1
}
# Without a stamp the age would come out as hours since 1970; only the early
# return for a missing file keeps a very long minimum from skipping the task.
cz_case "cadence: a task with no stamp runs whatever the minimum is" case_no_stamp_huge_minimum

# Pins current behaviour. A non-numeric minimum makes the test itself fail, bash
# prints its complaint (the wording after "integer" differs between bash
# versions, so only the start of it is pinned), and the gate falls open: the run
# goes ahead. No plan decision yet.
case_min_non_numeric() {
    rz_setup
    rz_profile_add 'MIN_HOURS_review=soon'
    rz_last_ran review 3600
    rz_run fx review
    cz_expect_rc 0
    cz_expect_stdout_empty
    cz_expect_matches stderr "run.sh: line [0-9]+: \[: soon: integer"
    rz_expect_helper_count "start review" 1
}
cz_case "cadence: a non-numeric minimum falls open, the run goes ahead and bash complains on stderr" case_min_non_numeric

# Pins current behaviour: a stamp in the future gives a negative age, which is
# below any positive minimum, so the task is skipped with a negative age printed.
case_future_stamp() {
    rz_setup
    rz_last_ran review -36000
    rz_run fx review
    cz_expect_rc 0
    cz_expect_stdout "$(skip_line review -10 6)"
    rz_expect_helper
}
cz_case "cadence: a stamp in the future reads as a negative age and skips" case_future_stamp

case_other_task_own_minimum() {
    rz_setup
    rz_last_ran issues 36000
    rz_start_id "$RZ_STAMP-issues"
    rz_run fx issues
    cz_expect_rc 0
    cz_expect_stdout "$(skip_line issues 10 36)"
}
cz_case "cadence: each task reads its own MIN_HOURS_<task>" case_other_task_own_minimum

case_stamp_of_other_task() {
    rz_setup
    rz_last_ran issues 60
    rz_run fx review
    cz_expect_rc 0
    cz_expect_stdout_empty
    rz_expect_helper_count "start review" 1
}
cz_case "cadence: the stamp of another task does not gate this one" case_stamp_of_other_task

# Pins current behaviour. Only the keys in lib/defaults.env take a MAINTAINER_
# override; MIN_HOURS_<task> is a profile key, so the variable does nothing.
case_min_hours_not_overridable() {
    rz_setup
    rz_last_ran review 3600
    cz_set MAINTAINER_MIN_HOURS_review 0
    rz_run fx review
    cz_expect_rc 0
    cz_expect_stdout "$(skip_line review 1 6)"
}
cz_case "cadence: MAINTAINER_MIN_HOURS_review is not an override and the gate holds" case_min_hours_not_overridable

case_preview_ignores_gate() {
    rz_setup
    rz_last_ran review 60
    rz_run --show-prompt fx review
    cz_expect_rc 0
    cz_expect_stdout_has "TASK review body"
}
cz_case "cadence: a preview does not consult the gate" case_preview_ignores_gate

# The gate is read again after the lock. A run ahead of this one promotes the
# stamp while this one waits; the stub flock stamps the file with the fixture
# clock to stand for that.
case_second_gate() {
    rz_setup
    rz_last_ran review 72000
    printf '%s' "$RZ_STATE/state/last-review.json" > "$CZ_CASE/flock.touch"
    rz_run fx review
    cz_expect_rc 0
    cz_expect_stdout "$(skip_line review 0 6 'after waiting for the lock')"
    cz_expect_stderr_empty
    cz_check "flock calls" "$(cat "$CZ_CASE/flock.calls")" "-w 3600 9"
    cz_expect_file "$RZ_STATE/run.lock"
    rz_expect_helper
    rz_expect_gh
    rz_expect_b_not_called claude
}
cz_case "cadence: a stamp promoted while waiting for the lock skips the run after the lock, exit 0" case_second_gate

case_second_gate_forced() {
    rz_setup
    rz_last_ran review 72000
    printf '%s' "$RZ_STATE/state/last-review.json" > "$CZ_CASE/flock.touch"
    cz_set MAINTAINER_FORCE 1
    rz_run fx review
    cz_expect_rc 0
    cz_expect_stdout_empty
    rz_expect_helper_count "start review" 1
}
cz_case "cadence: MAINTAINER_FORCE=1 also passes the gate after the lock" case_second_gate_forced

# --- the lock ----------------------------------------------------------------------

lock_alert() {  # prints the lock-held message for a wait of $1 seconds
    printf 'another run held the lock for over %ss, so this one never started' "$1"
}

case_lock_held() {
    rz_setup
    printf '1' > "$CZ_CASE/flock.rc"
    rz_run fx review
    local log="$RZ_LOGS/$RZ_STAMP-review.log" msg; msg="$(lock_alert 3600)"
    cz_expect_rc 75
    cz_expect_stdout_empty
    cz_expect_stderr "$msg"
    cz_check "flock calls" "$(cat "$CZ_CASE/flock.calls")" "-w 3600 9"
    rz_log_has "$msg"
    rz_expect_helper "$(cz_argv failed review "$msg" "$log")"
    rz_expect_notify_count 1
    rz_expect_notify 1 low "maintainer · fx review · will retry" \
        "$(printf 'Another run held the shared tree for over 3600s.\nfix  maintainer status, then wait or kill it\nlog  %s' "$log")"
    rz_expect_gh
    rz_expect_b_not_called claude
}
cz_case "lock: a held lock exits 75, message on stderr and in the log, marker recorded, low-urgency toast" case_lock_held

case_lock_wait_override() {
    rz_setup
    printf '1' > "$CZ_CASE/flock.rc"
    cz_set MAINTAINER_LOCK_WAIT 5
    rz_run fx review
    cz_expect_rc 75
    cz_expect_stderr "$(lock_alert 5)"
    cz_check "flock calls" "$(cat "$CZ_CASE/flock.calls")" "-w 5 9"
}
cz_case "lock: MAINTAINER_LOCK_WAIT sets the wait and the wording" case_lock_wait_override

# Pins current behaviour: any non-zero from flock, not only a timeout, reads as
# "held". A flock that is not installed is the same exit 75. No plan decision yet.
case_flock_missing() {
    rz_setup
    rm "$CZ_CASE/bin/flock"
    rz_run fx review
    cz_expect_rc 75
    cz_expect_stdout_empty
    cz_expect_matches stderr "run.sh: line [0-9]+: flock: command not found"
    cz_expect_stderr_has "$(lock_alert 3600)"
    rz_expect_helper_count "failed review" 1
}
cz_case "lock: flock missing from PATH is reported as a held lock, exit 75" case_flock_missing

case_flock_other_failure() {
    rz_setup
    printf '2' > "$CZ_CASE/flock.rc"
    rz_run fx review
    cz_expect_rc 75
    cz_expect_stderr_has "$(lock_alert 3600)"
}
cz_case "lock: a flock exit status other than 1 is also a held lock, exit 75" case_flock_other_failure

# Pins current behaviour: when the lock file cannot be opened, `exec 9>` fails
# but the script goes on, and the flock that follows fails on the missing
# descriptor, so the run reports a held lock. No plan decision yet.
case_lock_file_unopenable() {
    rz_setup
    ln -sf "$RZ_REAL_FLOCK" "$CZ_CASE/bin/flock"
    mkdir -p "$RZ_STATE/run.lock"
    rz_run fx review
    cz_expect_rc 75
    cz_expect_stdout_empty
    cz_expect_matches stderr "run.sh: line [0-9]+: $RZ_STATE/run.lock: Is a directory"
    cz_expect_stderr_has "$(lock_alert 3600)"
    rz_expect_helper_count "failed review" 1
}
cz_case "lock: a run.lock that cannot be opened ends as a held lock, exit 75 (no plan decision yet)" case_lock_file_unopenable

case_real_lock_held() {
    rz_setup
    ln -sf "$RZ_REAL_FLOCK" "$CZ_CASE/bin/flock"
    cz_set MAINTAINER_LOCK_WAIT 1
    exec 8>"$RZ_STATE/run.lock"
    if ! "$RZ_REAL_FLOCK" -n 8; then cz_note_fail "the test could not take the lock itself"; fi
    rz_run fx review
    exec 8>&-
    cz_expect_rc 75
    cz_expect_stdout_empty
    cz_expect_stderr "$(lock_alert 1)"
    rz_expect_helper_count "failed review" 1
    rz_expect_helper_count "start review" 0
    rz_expect_gh
}
cz_case "lock: with the real flock and the lock taken by another process, the run waits LOCK_WAIT and exits 75" case_real_lock_held

case_real_lock_free() {
    rz_setup
    ln -sf "$RZ_REAL_FLOCK" "$CZ_CASE/bin/flock"
    rz_run fx review
    cz_expect_rc 0
    cz_expect_stdout_empty
    cz_expect_stderr_empty
    cz_expect_file "$RZ_STATE/run.lock"
}
cz_case "lock: with the real flock and a free lock the run goes ahead" case_real_lock_free

# The descriptor is inheritable on purpose: the backend, and whatever it starts,
# keep the lock after run.sh itself is gone. The stub backend reports where its
# fd 9 points.
case_fd9_inherited() {
    rz_setup
    ln -sf "$RZ_REAL_FLOCK" "$CZ_CASE/bin/flock"
    rz_run fx review
    cz_expect_rc 0
    rz_expect_b_env claude fd9 "$RZ_STATE/run.lock"
}
cz_case "lock: the backend inherits fd 9, open on run.lock, so a child holds the lock" case_fd9_inherited

case_fd9_inherited_codex() {
    rz_setup
    ln -sf "$RZ_REAL_FLOCK" "$CZ_CASE/bin/flock"
    cz_set MAINTAINER_BACKEND codex
    rz_run fx review
    cz_expect_rc 0
    rz_expect_b_env codex fd9 "$RZ_STATE/run.lock"
}
cz_case "lock: a codex backend inherits fd 9 too" case_fd9_inherited_codex

case_lock_file_created() {
    rz_setup
    rz_run fx review
    cz_expect_rc 0
    cz_expect_file "$RZ_STATE/run.lock"
    cz_check "flock calls" "$(cat "$CZ_CASE/flock.calls")" "-w 3600 9"
}
cz_case "lock: a run creates STATE_DIR/run.lock and asks flock for it on fd 9 with the wait" case_lock_file_created

case_preview_takes_no_lock() {
    rz_setup
    rz_run --show-prompt fx review
    cz_expect_rc 0
    cz_expect_no_file "$RZ_STATE/run.lock"
    cz_expect_no_file "$CZ_CASE/flock.calls"
}
cz_case "lock: a preview takes no lock" case_preview_takes_no_lock

# --- the run lease -------------------------------------------------------------------

case_lease_sequence() {
    rz_setup
    rz_run fx review
    cz_expect_rc 0
    rz_expect_helper \
        'run-lease review \<ppid\>' \
        'start review' \
        "run-lease review \\<ppid\\> $RZ_RUNID" \
        "finish $RZ_RUNID" \
        "digest $RZ_RUNID --compact" \
        'run-lease --clear'
}
cz_case "lease: the helper is called in order: lease, start, lease with run id, finish, digest, clear" case_lease_sequence

case_lease_write_fails() {
    rz_setup
    printf '1' > "$CZ_CASE/h/run-lease.rc"
    printf 'lease broke\n' > "$CZ_CASE/h/run-lease.err"
    rz_run fx review
    cz_expect_rc 0
    cz_expect_stdout_empty
    cz_expect_stderr_empty
    rz_log_has "run-lease: could not write leases/run.json; the run goes on without it"
    rz_log_has "run-lease: could not add the run id to leases/run.json"
    rz_log_has "lease broke"
    rz_expect_helper_count "start review" 1
}
cz_case "lease: a failing run-lease is logged twice and never stops the run, exit 0, helper stderr in the log" case_lease_write_fails

case_lease_cleared_once_success() {
    rz_setup
    rz_run fx review
    cz_expect_rc 0
    rz_expect_helper_count "run-lease --clear" 1
}
cz_case "lease: a finished run clears the lease exactly once" case_lease_cleared_once_success

case_lease_cleared_once_refusal_early() {
    rz_setup
    cz_gh_rz api-user "someone-else" 0
    rz_run fx review
    cz_expect_rc 1
    rz_expect_helper_count "run-lease --clear" 1
}
cz_case "lease: a refusal before the token pin clears the lease exactly once (trap from the lease)" case_lease_cleared_once_refusal_early

case_lease_cleared_once_refusal_late() {
    rz_setup
    cz_gh_rz api-user.2 "someone-else" 0
    cz_gh_rz api-user.1 "fxacct" 0
    rz_run fx review
    cz_expect_rc 1
    rz_expect_helper_count "run-lease --clear" 1
}
cz_case "lease: a refusal after the token pin clears the lease exactly once (trap from the scrub)" case_lease_cleared_once_refusal_late

case_lease_clear_failure_ignored() {
    rz_setup
    printf '1' > "$CZ_CASE/h/run-lease.rc"
    rz_run fx review
    cz_expect_rc 0
    rz_expect_helper_count "run-lease --clear" 1
}
cz_case "lease: a failing run-lease --clear does not change the exit status" case_lease_clear_failure_ignored

case_lease_clear_keeps_failure_status() {
    rz_setup
    printf '1' > "$CZ_CASE/h/finish.rc"
    rz_run fx review
    cz_expect_rc 1
    rz_expect_helper_count "run-lease --clear" 1
}
cz_case "lease: the trap that clears the lease keeps a failing exit status" case_lease_clear_keeps_failure_status

cz_finish
