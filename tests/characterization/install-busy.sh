#!/usr/bin/env bash
# Characterization: install.sh refuses to run while a run is in flight, and
# writes nothing when it refuses.
#
# The check asks the lock: for each profile whose STATE_DIR holds a run.lock it
# runs `flock -n <lock> true`, and a non-zero answer means a run holds it. Most
# cases use a flock stub whose exit code a case sets ("held" is 1). One case uses
# the real flock against a lock held by another process.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib-inst.sh"
ci_init

LOCK_S() { printf '%s' "$CZ_HOME/.local/state/sysknife-maint/run.lock"; }
LOCK_M() { printf '%s' "$CZ_HOME/.local/state/magent-maint/run.lock"; }
mklock() { mkdir -p "$(dirname "$1")"; : > "$1"; }
held() { printf '1' > "$CZ_CASE/flock.rc"; }

REFUSAL_TAIL() {
    printf '%s\n' \
        "            This replaces $CZ_SHARE/profiles, which that run reads for" \
        "            the whole of its pass." \
        "" \
        "            Wait for it (maintainer status), or --force if you are sure."
}

case_busy_refusal() {
    ci_fixture_profiles; mklock "$(LOCK_S)"; held
    ci_install
    cz_expect_rc 69
    cz_expect_stdout_empty
    local want; want="$(printf '%s\n' "install.sh: a run is in flight for: sysknife"; REFUSAL_TAIL)"
    cz_check "stderr" "$(cat "$CZ_CASE/stderr")" "$want"
    cz_check "stderr line count" "$(wc -l < "$CZ_CASE/stderr" | tr -d ' ')" "5"
}
ci_case "busy: a held lock exits 69 with the five-line message naming the profile" case_busy_refusal

case_busy_writes_nothing() {
    ci_fixture_profiles; mklock "$(LOCK_S)"
    ci_install || true
    cz_expect_rc 0
    ci_reset_logs
    held
    ci_snap "$CZ_HOME" > "$CZ_CASE/home.before"; ci_snap "$CZ_TREE" > "$CZ_CASE/tree.before"
    ci_manifest "$CZ_HOME" > "$CZ_CASE/man.before"
    ci_install
    cz_expect_rc 69
    ci_snap "$CZ_HOME" > "$CZ_CASE/home.after"; ci_snap "$CZ_TREE" > "$CZ_CASE/tree.after"
    ci_manifest "$CZ_HOME" > "$CZ_CASE/man.after"
    ci_expect_same_snap "home (paths, modes, sizes, mtimes)" "$CZ_CASE/home.before" "$CZ_CASE/home.after"
    ci_expect_same_snap "tree" "$CZ_CASE/tree.before" "$CZ_CASE/tree.after"
    ci_expect_same_snap "file contents" "$CZ_CASE/man.before" "$CZ_CASE/man.after"
    ci_expect_calls systemctl.calls
}
ci_case "busy: a refused install over an existing deployment changes no file, mtime or directory" case_busy_writes_nothing

case_busy_writes_nothing_fresh() {
    ci_fixture_profiles; mklock "$(LOCK_S)"; held
    ci_snap "$CZ_HOME" > "$CZ_CASE/home.before"
    ci_install --timers
    cz_expect_rc 69
    ci_snap "$CZ_HOME" > "$CZ_CASE/home.after"
    ci_expect_same_snap "home" "$CZ_CASE/home.before" "$CZ_CASE/home.after"
    cz_expect_no_file "$CZ_SHARE"
    cz_expect_no_file "$CZ_HOME/.local/bin"
    cz_expect_no_file "$CZ_HOME/.config"
    ci_expect_calls systemctl.calls
}
ci_case "busy: on a machine with nothing deployed the refusal creates no directory, not even ~/.local/share/maintainer" case_busy_writes_nothing_fresh

case_busy_flock_argv() {
    ci_fixture_profiles; mklock "$(LOCK_S)"; held
    ci_install
    ci_expect_calls flock.calls "-n $(LOCK_S) true"
}
ci_case "busy: the lock is asked with flock -n <state>/run.lock true" case_busy_flock_argv

case_busy_two_profiles() {
    ci_fixture_profiles; mklock "$(LOCK_S)"; mklock "$(LOCK_M)"; held
    ci_install
    cz_expect_rc 69
    cz_expect_stderr_first "install.sh: a run is in flight for: magent sysknife"
    ci_expect_calls flock.calls "-n $(LOCK_M) true" "-n $(LOCK_S) true"
}
ci_case "busy: every profile with a held lock is named, in profile order" case_busy_two_profiles

case_busy_one_of_two() {
    ci_fixture_profiles; mklock "$(LOCK_M)"; held
    ci_install
    cz_expect_rc 69
    cz_expect_stderr_first "install.sh: a run is in flight for: magent"
    ci_expect_calls flock.calls "-n $(LOCK_M) true"
}
ci_case "busy: a profile with no lock file is not asked" case_busy_one_of_two

case_busy_free_lock() {
    ci_fixture_profiles; mklock "$(LOCK_S)"
    ci_install
    cz_expect_rc 0
    cz_expect_stderr_empty
    ci_expect_calls flock.calls "-n $(LOCK_S) true"
    cz_expect_file "$CZ_SHARE/VERSION"
}
ci_case "busy: a lock file nobody holds does not stop the install" case_busy_free_lock

case_busy_no_lock_file() {
    ci_fixture_profiles; held
    ci_install
    cz_expect_rc 0
    ci_expect_calls flock.calls
}
ci_case "busy: with no lock file flock is never called, whatever it would answer" case_busy_no_lock_file

case_busy_force() {
    ci_fixture_profiles; mklock "$(LOCK_S)"; held
    ci_install --force
    cz_expect_rc 0
    cz_expect_stderr_empty
    ci_expect_calls flock.calls
    cz_expect_file "$CZ_SHARE/VERSION"
}
ci_case "busy: --force installs over a held lock without asking it" case_busy_force

case_busy_dry_run() {
    ci_fixture_profiles; mklock "$(LOCK_S)"; held
    ci_install --dry-run
    cz_expect_rc 0
    cz_expect_stderr_empty
    ci_expect_calls flock.calls
}
ci_case "busy: a dry run does not look at the lock" case_busy_dry_run

# Pins current behaviour. A profile.env that fails before it sets STATE_DIR yields
# an empty STATE_DIR, the profile is skipped, and the lock it would have named goes
# unchecked. The check fails open for a profile it cannot read.
case_busy_unreadable_profile() {
    ci_fixture_profiles; mklock "$(LOCK_S)"; held
    printf ')\nSTATE_DIR="$HOME/.local/state/sysknife-maint"\n' > "$CZ_TREE/profiles/sysknife/profile.env"
    ci_install
    cz_expect_rc 0
    ci_expect_calls flock.calls
}
ci_case "busy: a profile.env that breaks before STATE_DIR is skipped and the install goes ahead (pins current behaviour)" case_busy_unreadable_profile

# A file is run one command at a time, so a syntax error AFTER the assignment
# still leaves STATE_DIR set and the lock is asked.
case_busy_late_syntax_error() {
    ci_fixture_profiles; mklock "$(LOCK_S)"; held
    printf 'STATE_DIR="$HOME/.local/state/sysknife-maint"\n)\n' > "$CZ_TREE/profiles/sysknife/profile.env"
    ci_install
    cz_expect_rc 69
    cz_expect_stderr_first "install.sh: a run is in flight for: sysknife"
}
ci_case "busy: a syntax error after STATE_DIR is set does not hide the lock" case_busy_late_syntax_error

case_busy_empty_state_dir() {
    ci_fixture_profiles; mklock "$(LOCK_S)"; held
    printf 'STATE_DIR=""\n' > "$CZ_TREE/profiles/sysknife/profile.env"
    ci_install
    cz_expect_rc 0
    ci_expect_calls flock.calls
}
ci_case "busy: a profile whose STATE_DIR is empty is skipped" case_busy_empty_state_dir

case_busy_profile_without_env() {
    ci_fixture_profiles; mklock "$(LOCK_S)"; held
    rm -f "$CZ_TREE/profiles/sysknife/profile.env"
    ci_install
    cz_expect_rc 0
    ci_expect_calls flock.calls
}
ci_case "busy: a profile directory with no profile.env is skipped" case_busy_profile_without_env

# Pins current behaviour. The scaffolding profile is asked too, under its
# placeholder state directory.
case_busy_template_is_asked() {
    ci_fixture_profiles
    mklock "$CZ_HOME/.local/state/__PROFILE__-maint/run.lock"; held
    ci_install
    cz_expect_rc 69
    cz_expect_stderr_first "install.sh: a run is in flight for: _template"
}
ci_case "busy: profiles/_template is checked like a profile (pins current behaviour)" case_busy_template_is_asked

# Pins current behaviour. profile.env reads MAINTAINER_STATE_DIR from the caller's
# environment, so with it set every profile resolves to the same directory.
case_busy_state_dir_override() {
    ci_fixture_profiles
    mklock "$CZ_HOME/elsewhere/run.lock"; held
    cz_set MAINTAINER_STATE_DIR "$CZ_HOME/elsewhere"
    ci_install
    cz_expect_rc 69
    cz_expect_stderr_first "install.sh: a run is in flight for: _template magent sysknife"
    ci_expect_calls flock.calls "-n $CZ_HOME/elsewhere/run.lock true" "-n $CZ_HOME/elsewhere/run.lock true" "-n $CZ_HOME/elsewhere/run.lock true"
}
ci_case "busy: MAINTAINER_STATE_DIR in the environment redirects every profile's lock (pins current behaviour)" case_busy_state_dir_override

# Pins current behaviour. With no flock on PATH the call fails, which reads as
# "held": the install refuses. It fails closed by accident.
case_busy_flock_missing() {
    ci_fixture_profiles; mklock "$(LOCK_S)"
    ci_drop_tool flock
    ci_install
    cz_expect_rc 69
    cz_expect_stderr_first "install.sh: a run is in flight for: sysknife"
}
ci_case "busy: without flock on PATH an existing lock file reads as held (pins current behaviour)" case_busy_flock_missing

case_busy_flock_missing_no_lock() {
    ci_fixture_profiles
    ci_drop_tool flock
    ci_install
    cz_expect_rc 0
}
ci_case "busy: without flock and without a lock file the install goes ahead" case_busy_flock_missing_no_lock

# The real flock against a lock another process holds. The holder is python3
# started on its own, so $! is its pid, and the case reads /proc to prove it.
case_busy_real_lock() {
    ci_fixture_profiles; mklock "$(LOCK_S)"
    rm -f "$CZ_CASE/bin/flock"
    local ready="$CZ_CASE/holder.ready" pid exe
    python3 -I -c 'import fcntl, sys, time
f = open(sys.argv[1], "a")
fcntl.flock(f, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(60)' "$(LOCK_S)" "$ready" &
    pid=$!
    exe="$(readlink "/proc/$pid/exe")"
    case "$exe" in *python*) ;; *) cz_note_fail "the lock holder's pid $pid is $exe, not python"; kill "$pid" 2>/dev/null; return ;; esac
    for _ in $(seq 1 50); do [ -e "$ready" ] && break; sleep 0.1; done
    if [ ! -e "$ready" ]; then cz_note_fail "the lock holder never took the lock"; kill "$pid" 2>/dev/null; return; fi
    ci_install
    local rc_busy="$CZ_RC"; cp "$CZ_CASE/stderr" "$CZ_CASE/stderr.busy"
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    cz_check "exit code while another process holds the real lock" "$rc_busy" "69"
    cz_check "first stderr line while held" "$(head -1 "$CZ_CASE/stderr.busy")" "install.sh: a run is in flight for: sysknife"
    ci_install
    cz_expect_rc 0
    cz_expect_file "$CZ_SHARE/VERSION"
}
ci_case "busy: the real flock refuses while another process holds the lock and allows the install after it lets go" case_busy_real_lock

case_busy_real_flock_free() {
    ci_fixture_profiles; mklock "$(LOCK_S)"
    rm -f "$CZ_CASE/bin/flock"
    ci_install
    cz_expect_rc 0
}
ci_case "busy: the real flock on an unheld lock file allows the install" case_busy_real_flock_free

cz_finish
