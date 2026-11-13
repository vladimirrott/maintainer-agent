#!/usr/bin/env bash
# Characterization: bin/maintainer-doctor, the back of the report. The Sandbox
# probe (the hardened transient unit that extracts a tree), the Audit trail
# (run reports, receipts that outlived their pull request, forgotten leases,
# the writable state directory, the pinned-token scan, tasks that stopped
# running) and Deployed code (VERSION against the tree it came from).
#
# Ages are read from file times and from clocks, so each case places its
# fixtures a known whole number of hours, plus a margin, in the past. The pinned
# token is a fake string. systemd-run, gh and podman are stubs.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib-dr.sh"
dr_init

UNIT_REL=".config/systemd/user/maintainer@.service"
TOKEN="ghp_FAKEFAKEFAKEFAKEFAKE0000"
epoch_ago() { printf '%s' "$(( $(date +%s) - $1 * 3600 - 1200 ))"; }   # HOURS hours and 20 minutes ago

# --- Sandbox ----------------------------------------------------------------------

# dr_unit: the installed unit, with eleven directives the probe must apply and
# four lines it must not (an indented one, a comment, two other settings).
dr_unit() {
    cat > "$DR_HOME/$UNIT_REL" <<'UNIT'
[Service]
Type=oneshot
ExecStart=/bin/true
NoNewPrivileges=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=read-only
RestrictSUIDSGID=yes
RestrictNamespaces=yes
RestrictAddressFamilies=AF_UNIX
SystemCallFilter=@system-service
SystemCallArchitectures=native
ReadWritePaths=/var/tmp
  PrivateDevices=yes
#ProtectKernelTunables=yes
Nice=5
UNIT
}
sandbox_ready() {
    dr_install
    dr_unit
    dr_present maintainer-merge
    dr_ans systemd-run-bare "" 0
    dr_ans systemd-run-probe "" 0
}

case_sb_no_unit_file() {
    dr_install
    dr_doctor
    dr_has_finding ok "no systemd user unit to probe on this machine"
    dr_expect_calls systemd-run
}
dr_case "sandbox: no installed maintainer@.service means nothing to probe, and systemd-run is never called" case_sb_no_unit_file

case_sb_no_systemd_run() {
    sandbox_ready
    dr_absent systemd-run
    dr_doctor
    cz_expect_rc 0
    dr_has_finding ok "no systemd user unit to probe on this machine"
}
dr_case "sandbox: no systemd-run on PATH reads the same as no unit" case_sb_no_systemd_run

case_sb_darwin() {
    sandbox_ready
    dr_os Darwin ""
    dr_doctor
    dr_has_finding ok "no systemd user unit to probe on this machine"
    dr_expect_calls systemd-run
}
dr_case "sandbox: on Darwin the probe is skipped even when a unit file exists" case_sb_darwin

case_sb_no_directives() {
    sandbox_ready
    printf '[Service]\nExecStart=/bin/true\nNice=5\n' > "$DR_HOME/$UNIT_REL"
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "no hardening directive found in $DR_HOME/$UNIT_REL (grep exited 1)" "the sandbox probe has nothing to apply; read the unit by hand"
    dr_expect_calls systemd-run
}
dr_case "sandbox: a unit with no hardening directive warns with grep's exit code and runs nothing" case_sb_no_directives

case_sb_no_merge() {
    sandbox_ready
    dr_absent maintainer-merge
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "maintainer-merge is not on PATH, so the sandbox probe cannot run" "./install.sh"
    dr_expect_calls systemd-run
}
dr_case "sandbox: no maintainer-merge on PATH warns and runs nothing" case_sb_no_merge

case_sb_no_transient() {
    sandbox_ready
    dr_ans systemd-run-bare "" 1
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "systemd-run --user cannot start a transient unit, so the sandbox is unprobed" "log in to a user session, then re-run"
    dr_expect_calls systemd-run "--user --wait --pipe --quiet true"
}
dr_case "sandbox: a bare transient unit that cannot start warns and the hardened probe is not tried" case_sb_no_transient

case_sb_repo_fails() {
    sandbox_ready
    dr_stub_file git <<STUB
#!/usr/bin/env bash
case "\${1:-}" in init) exit 1 ;; esac
exec "$DR_REAL_GIT" "\$@"
STUB
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "could not build the probe repository" "check git and $CZ_CASE/tmp"
    dr_expect_calls systemd-run "--user --wait --pipe --quiet true"
    cz_check "probe directories left in TMPDIR" "$(ls "$CZ_CASE/tmp" | wc -l)" "0"
}
dr_case "sandbox: a probe repository that cannot be built warns, names TMPDIR, and leaves no directory behind" case_sb_repo_fails

case_sb_ok() {
    sandbox_ready
    dr_doctor
    cz_expect_rc 0
    dr_has_finding ok "verify extracts a tree under the unit's hardening (11 directive(s) applied)"
    local mm="$CZ_CASE/bin/maintainer-merge" got
    got="$(sed -n 2p "$CZ_CASE/calls/systemd-run" | sed "s#$CZ_CASE/tmp/tmp\\.[A-Za-z0-9]*#SB#g")"
    cz_check "the hardened probe call" "$got" "$(cz_argv --user --wait --pipe --quiet \
        -p NoNewPrivileges=yes -p LockPersonality=yes -p MemoryDenyWriteExecute=yes -p PrivateTmp=yes \
        -p ProtectSystem=strict -p ProtectHome=read-only -p RestrictSUIDSGID=yes -p RestrictNamespaces=yes \
        -p RestrictAddressFamilies=AF_UNIX -p SystemCallFilter=@system-service -p SystemCallArchitectures=native \
        -E MAINTAINER_REPO=SB/r -E MAINTAINER_STATE=SB/s \
        bash -c '. "$1" && extract_tree HEAD "$2"' _ "$mm" SB/x)"
    cz_check "systemd-run call count" "$(wc -l < "$CZ_CASE/calls/systemd-run")" "2"
    cz_check "probe directories left in TMPDIR" "$(ls "$CZ_CASE/tmp" | wc -l)" "0"
}
dr_case "sandbox: the hardened probe applies the eleven directive lines in file order, sources maintainer-merge, and cleans up" case_sb_ok

case_sb_fails() {
    sandbox_ready
    dr_ans systemd-run-probe "$(printf 'line one\nline two\nline three')" 1
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "verify cannot extract a tree under the unit's hardening: line one line two " "a directive in $DR_HOME/$UNIT_REL blocks a call the extraction needs; every unattended verify fails until it is fixed"
    dr_lacks "line three"
    cz_check "probe directories left in TMPDIR" "$(ls "$CZ_CASE/tmp" | wc -l)" "0"
}
dr_case "sandbox: a failing hardened probe is a FAIL quoting its first two output lines" case_sb_fails

# --- Audit trail: state ------------------------------------------------------------

case_au_no_state_dir_name() {
    dr_install
    dr_p_unset STATE_DIR
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "the profile names no STATE_DIR" "set it in profiles/magent/profile.env"
    dr_lacks "state directory writable"
}
dr_case "audit: a profile with no STATE_DIR fails and the rest of the audit trail is skipped" case_au_no_state_dir_name

case_au_no_state() {
    dr_install
    dr_p STATE_DIR "$CZ_CASE/nowhere"
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "no state yet; the first run creates it"
    dr_lacks "run report(s)"
}
dr_case "audit: a state directory that does not exist yet is a warning with no fix line" case_au_no_state

case_au_state_is_file() {
    dr_install
    printf 'x\n' > "$CZ_CASE/statefile"
    dr_p STATE_DIR "$CZ_CASE/statefile"
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "no state yet; the first run creates it"
    dr_lacks "state directory writable"
}
dr_case "audit: a STATE_DIR that is a regular file counts as no state yet" case_au_state_is_file

case_au_counts() {
    dr_install
    mkdir -p "$CZ_STATE/runs" "$CZ_STATE/receipts"
    : > "$CZ_STATE/runs/a.md"; : > "$CZ_STATE/runs/b.md"; : > "$CZ_STATE/runs/c.md"
    printf '{}\n' > "$CZ_STATE/receipts/5.json"; printf '{}\n' > "$CZ_STATE/receipts/7.json"
    cz_gh pr-view.5 OPEN; cz_gh pr-view.7 OPEN
    dr_doctor
    cz_expect_rc 0
    dr_has_finding ok "3 run report(s), 2 open receipt(s)"
    dr_has_finding ok "no receipt outlives its pull request"
}
dr_case "audit: runs/ and receipts/ entries are counted as report(s) and open receipt(s)" case_au_counts

case_au_writable() {
    dr_install
    dr_doctor
    dr_has_finding ok "state directory writable"
}
dr_case "audit: a writable state directory is ok" case_au_writable

if [ "$DR_ME" = 0 ]; then
    echo "SKIP  audit: a read-only state directory (root ignores the write bit)"
else
    case_au_not_writable() {
        dr_install
        chmod 555 "$CZ_STATE"
        dr_doctor
        chmod 755 "$CZ_STATE"
        cz_expect_rc 1
        dr_has_finding fail "state directory not writable" "chown it"
    }
    dr_case "audit: a state directory without the write bit is a FAIL with the chown fix" case_au_not_writable
fi

# --- Audit trail: receipts ------------------------------------------------------------

case_re_stale() {
    dr_install
    mkdir -p "$CZ_STATE/receipts"
    local n; for n in 5 7 10; do printf '{}\n' > "$CZ_STATE/receipts/$n.json"; done
    cz_gh pr-view.5 MERGED; cz_gh pr-view.7 OPEN; cz_gh pr-view.10 CLOSED
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "receipt(s) for an already merged pull request: 10 (CLOSED) 5 (MERGED)" "rm $CZ_STATE/receipts/<pr>.json once you have checked the work really landed"
    dr_lacks "no receipt outlives"
    cz_expect_gh_line "$(cz_argv pr view 5 --repo o/r --json state --jq .state)"
    cz_expect_gh_line "$(cz_argv pr view 10 --repo o/r --json state --jq .state)"
}
dr_case "receipts: merged and closed pull requests are listed in file-name order, open ones are not" case_re_stale

case_re_lookup_fails() {
    dr_install
    mkdir -p "$CZ_STATE/receipts"
    printf '{}\n' > "$CZ_STATE/receipts/5.json"
    cz_gh pr-view.5 "" 1
    dr_doctor
    cz_expect_rc 0
    dr_has_finding ok "no receipt outlives its pull request"
}
dr_case "receipts: a pull request gh cannot look up is skipped, so the receipt reads as open" case_re_lookup_fails

case_re_non_numeric() {
    dr_install
    mkdir -p "$CZ_STATE/receipts"
    printf '{}\n' > "$CZ_STATE/receipts/notes.json"; printf '{}\n' > "$CZ_STATE/receipts/12a.json"
    printf '{}\n' > "$CZ_STATE/receipts/-1.json"; printf 'x\n' > "$CZ_STATE/receipts/9.txt"
    dr_doctor
    cz_expect_rc 0
    dr_has_finding ok "0 run report(s), 4 open receipt(s)"
    cz_expect_gh_count "pr view" 0
}
dr_case "receipts: files whose name is not a pull request number are never looked up" case_re_non_numeric

# --- Audit trail: leases ------------------------------------------------------------------

lease() {  # $1 = pr, $2 = hours since renewal
    mkdir -p "$CZ_STATE/leases"
    printf '{"acquired": 1, "holder": "h", "pr": %s, "renewed": %s, "ttl_seconds": 3600}\n' "$1" "$(epoch_ago "$2")" > "$CZ_STATE/leases/pr-$1.json"
}

case_le_forgotten() {
    dr_install
    lease 7 13
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "lease(s) nobody has renewed for over 12h: #7 (renewed 13h ago)" "maintainer lease release 7 "
}
dr_case "leases: a lease not renewed for 13h is a warning with a release command" case_le_forgotten

case_le_two() {
    dr_install
    lease 7 13; lease 9 20
    dr_doctor
    dr_has_finding warn "lease(s) nobody has renewed for over 12h: #7 (renewed 13h ago), #9 (renewed 20h ago)" "maintainer lease release 7 9 "
}
dr_case "leases: two forgotten leases are listed in order and the fix releases both" case_le_two

case_le_fresh() {
    dr_install
    lease 7 2
    dr_doctor
    cz_expect_rc 0
    dr_has_finding ok "no lease has gone 12h without a renewal"
}
dr_case "leases: a lease renewed 2h ago is ok" case_le_fresh

case_le_unreadable() {
    dr_install
    mkdir -p "$CZ_STATE/leases"
    printf 'not json\n' > "$CZ_STATE/leases/pr-3.json"
    printf '{"x": 1}\n' > "$CZ_STATE/leases/pr-4.json"
    printf '{"renewed": "soon"}\n' > "$CZ_STATE/leases/pr-5.json"
    dr_doctor
    dr_has_finding warn "lease(s) nobody has renewed for over 12h: #3 (unreadable), #4 (unreadable), #5 (unreadable)" "maintainer lease release 3 4 5 "
}
dr_case "leases: a lease file that is not JSON, lacks 'renewed' or holds a non-number is reported as unreadable" case_le_unreadable

case_le_other_files() {
    dr_install
    mkdir -p "$CZ_STATE/leases"
    printf '{"renewed": 1}\n' > "$CZ_STATE/leases/notes.json"
    dr_doctor
    dr_has_finding ok "no lease has gone 12h without a renewal"
}
dr_case "leases: only pr-*.json files in leases/ are read" case_le_other_files

case_le_hours_env() {
    dr_install
    cz_set MAINTAINER_DOCTOR_LEASE_HOURS 1
    lease 7 2
    dr_doctor
    dr_has_finding warn "lease(s) nobody has renewed for over 1h: #7 (renewed 2h ago)" "maintainer lease release 7 "
}
dr_case "leases: MAINTAINER_DOCTOR_LEASE_HOURS sets the limit and the message" case_le_hours_env

# Pins current behaviour: when the lease reader itself fails, the doctor warns and
# then prints the ok line as well, with the bad value in it.
case_le_reader_fails() {
    dr_install
    mkdir -p "$CZ_STATE/leases"
    cz_set MAINTAINER_DOCTOR_LEASE_HOURS abc
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "could not read the leases under $CZ_STATE/leases, so forgotten ones are unknown" "python3 and a readable state directory"
    dr_has_finding ok "no lease has gone abch without a renewal"
}
dr_case "leases: a reader that fails warns and still prints the ok line (pins current behaviour)" case_le_reader_fails

# --- Audit trail: the pinned token ------------------------------------------------------------

case_tok_found() {
    dr_install
    mkdir -p "$CZ_STATE/logs"
    printf 'GH_TOKEN=%s\n' "$TOKEN" > "$CZ_STATE/logs/a.log"
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "the pinned token is on disk in 1 file(s), starting $CZ_STATE/logs/a.log" "rotate the token, then: $DR_SHARE/run.sh magent <task> rescrubs on exit"
    dr_lacks "$TOKEN"
    cz_expect_stderr_empty
}
dr_case "token: a file holding the token is a FAIL naming the file, and the token itself is never printed" case_tok_found

# Pins current behaviour, see plan decision F4: the scan runs `grep -rlaF -e TOKEN`
# and the token is therefore in grep's argv, visible to any process of the same user.
case_tok_in_argv() {
    dr_install
    mkdir -p "$CZ_STATE/logs" "$CZ_STATE/receipts"
    dr_doctor
    cz_expect_rc 0
    dr_expect_call_line grep "-rlaF -e $TOKEN $CZ_STATE/logs $CZ_STATE/receipts"
}
dr_case "token: the scan puts the token in grep's argv (pins current behaviour, plan decision F4)" case_tok_in_argv

case_tok_clean() {
    dr_install
    mkdir -p "$CZ_STATE/logs"
    printf 'nothing here\n' > "$CZ_STATE/logs/a.log"
    dr_doctor
    dr_has_finding ok "no pinned token left on disk by an earlier run"
}
dr_case "token: no file holding the token is ok" case_tok_clean

case_tok_binary() {
    dr_install
    mkdir -p "$CZ_STATE/runs"
    printf 'abc\0%s\0def' "$TOKEN" > "$CZ_STATE/runs/blob.bin"
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "the pinned token is on disk in 1 file(s), starting $CZ_STATE/runs/blob.bin" "rotate the token, then: $DR_SHARE/run.sh magent <task> rescrubs on exit"
}
dr_case "token: a binary file holding the token is found (grep -a)" case_tok_binary

# Pins current behaviour: with any of the five named subdirectories present, the
# state directory's own top level is not searched.
case_tok_top_level_skipped() {
    dr_install
    mkdir -p "$CZ_STATE/logs"
    printf '%s\n' "$TOKEN" > "$CZ_STATE/stray.txt"
    dr_doctor
    cz_expect_rc 0
    dr_has_finding ok "no pinned token left on disk by an earlier run"
}
dr_case "token: a token in the state directory's top level is missed once logs/ exists (pins current behaviour)" case_tok_top_level_skipped

case_tok_no_subdirs() {
    dr_install
    printf '%s\n' "$TOKEN" > "$CZ_STATE/stray.txt"
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "the pinned token is on disk in 1 file(s), starting $CZ_STATE/stray.txt" "rotate the token, then: $DR_SHARE/run.sh magent <task> rescrubs on exit"
    dr_expect_call_line grep "-rlaF -e $TOKEN $CZ_STATE"
}
dr_case "token: with none of the five subdirectories the whole state directory is searched" case_tok_no_subdirs

case_tok_session() {
    dr_install
    local sess; sess="$DR_HOME/.claude/projects/$(printf '%s' "$CZ_REPO" | tr '/.' '--')"
    mkdir -p "$sess"
    printf '%s\n' "$TOKEN" > "$sess/transcript.jsonl"
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "the pinned token is on disk in 1 file(s), starting $sess/transcript.jsonl" "rotate the token, then: $DR_SHARE/run.sh magent <task> rescrubs on exit"
    dr_expect_call_line grep "-rlaF -e $TOKEN $sess"
}
dr_case "token: the Claude session directory of REPO_PATH is searched, and replaces the state directory when no subdirectory exists" case_tok_session

case_tok_five_files() {
    dr_install
    mkdir -p "$CZ_STATE/logs"
    local i; for i in 1 2 3 4 5 6 7; do printf '%s\n' "$TOKEN" > "$CZ_STATE/logs/f$i.log"; done
    dr_doctor
    cz_expect_rc 1
    cz_expect_matches stdout "the pinned token is on disk in 5 file\\(s\\), starting $CZ_STATE/logs/f[1-7]\\.log"
}
dr_case "token: seven files holding the token are reported as 5 (the scan keeps the first five)" case_tok_five_files

case_tok_short() {
    dr_install
    cz_gh auth-token "shorttoken12345"
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "cannot read the pinned token, so nothing checked whether one was left on disk" "gh auth switch --user testuser"
    local g; g="$(cat "$CZ_CASE/calls/grep")"
    if grep -qF -- "-rlaF" <<<"$g"; then cz_note_fail "the token scan ran on a 15-character answer"; fi
}
dr_case "token: a 15-character answer is too short to be a token, so nothing is scanned" case_tok_short

case_tok_sixteen() {
    dr_install
    cz_gh auth-token "abcdefghijklmnop"
    dr_doctor
    dr_has_finding ok "no pinned token left on disk by an earlier run"
}
dr_case "token: a 16-character answer is scanned" case_tok_sixteen

case_tok_gh_fails() {
    dr_install
    cz_gh auth-token "" 1
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "cannot read the pinned token, so nothing checked whether one was left on disk" "gh auth switch --user testuser"
}
dr_case "token: a gh auth token that fails and prints nothing is a warning" case_tok_gh_fails

# Pins current behaviour: the failure is swallowed by `|| true` but its stdout is
# kept, so a long enough error text is scanned as though it were the token.
case_tok_error_text() {
    dr_install
    cz_gh auth-token "no oauth token found for github.com" 1
    dr_doctor
    cz_expect_rc 0
    dr_has_finding ok "no pinned token left on disk by an earlier run"
}
dr_case "token: stdout of a failing gh auth token is scanned as if it were the token (pins current behaviour)" case_tok_error_text

case_tok_no_account() {
    dr_install
    dr_p_unset GH_ACCOUNT
    cz_gh auth-token "" 1
    dr_doctor
    dr_has_finding warn "cannot read the pinned token, so nothing checked whether one was left on disk" "gh auth switch --user <account>"
    cz_expect_gh_line "$(cz_argv auth token --user '')"
}
dr_case "token: with no GH_ACCOUNT the fix says <account> and gh is asked for an empty user" case_tok_no_account

# --- Audit trail: tasks that stopped running ---------------------------------------------------

task_failed() {  # $1 = task, $2 = hours ago, $3 = file content (default: a reason)
    mkdir -p "$CZ_STATE/state"
    printf '%s\n' "${3-{\"reason\": \"network down\"\}}" > "$CZ_STATE/state/failed-$1.json"
    touch -d "@$(epoch_ago "$2")" "$CZ_STATE/state/failed-$1.json"
}
task_last() {
    mkdir -p "$CZ_STATE/state"
    printf '{}\n' > "$CZ_STATE/state/last-$1.json"
    touch -d "@$(epoch_ago "$2")" "$CZ_STATE/state/last-$1.json"
}
RUN_FIX() { printf '%s/run.sh magent %s' "$DR_SHARE" "$1"; }

case_tk_never() {
    dr_install
    task_failed review 9
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "review has never completed; its only record is a failure 9h ago: network down" "$(RUN_FIX review)"
    dr_lacks "every task has completed"
}
dr_case "tasks: a failure with no success on record is 'has never completed' with the age and the reason" case_tk_never

case_tk_reason_missing() {
    dr_install
    task_failed review 9 '{"other": 1}'
    dr_doctor
    dr_has_finding fail "review has never completed; its only record is a failure 9h ago: no reason recorded in failed-review.json" "$(RUN_FIX review)"
}
dr_case "tasks: a failure file with no reason says 'no reason recorded'" case_tk_reason_missing

case_tk_reason_garbage() {
    dr_install
    task_failed review 9 'not json'
    dr_doctor
    dr_has_finding fail "review has never completed; its only record is a failure 9h ago: no reason recorded in failed-review.json" "$(RUN_FIX review)"
}
dr_case "tasks: an unparseable failure file still reports the failure, with 'no reason recorded'" case_tk_reason_garbage

case_tk_reason_empty() {
    dr_install
    task_failed review 9 '{"reason": null}'
    dr_doctor
    dr_has_finding fail "review has never completed; its only record is a failure 9h ago: no reason recorded in failed-review.json" "$(RUN_FIX review)"
}
dr_case "tasks: a null reason also says 'no reason recorded'" case_tk_reason_empty

case_tk_newer_failure() {
    dr_install
    task_last review 20
    task_failed review 9
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "review failed 9h ago and has not completed since: network down" "$(RUN_FIX review)"
}
dr_case "tasks: a failure newer than the last success is 'has not completed since'" case_tk_newer_failure

case_tk_recovered() {
    dr_install
    task_failed review 9
    task_last review 2
    dr_doctor
    cz_expect_rc 0
    dr_has_finding ok "every task has completed since its last failure"
    dr_lacks "review failed"
}
dr_case "tasks: a success newer than the failure counts as recovered" case_tk_recovered

case_tk_tie() {
    dr_install
    task_failed review 9
    task_last review 9
    touch -r "$CZ_STATE/state/failed-review.json" "$CZ_STATE/state/last-review.json"
    dr_doctor
    cz_expect_rc 0
    dr_has_finding ok "every task has completed since its last failure"
}
dr_case "tasks: a failure and a success with the same timestamp count as recovered" case_tk_tie

case_tk_inside_interval() {
    dr_install
    dr_p MIN_HOURS_review 6
    task_last review 2
    task_failed review 1
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "review failed 1h ago, but it completed 2h ago and its interval is 6h: network down" "nothing is overdue; read the log if you want to know why that attempt died"
}
dr_case "tasks: a failure after a success younger than the task's MIN_HOURS is a warning, not a FAIL" case_tk_inside_interval

case_tk_outside_interval() {
    dr_install
    dr_p MIN_HOURS_review 2
    task_last review 2
    task_failed review 1
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "review failed 1h ago and has not completed since: network down" "$(RUN_FIX review)"
}
dr_case "tasks: a success exactly as old as MIN_HOURS no longer excuses the failure" case_tk_outside_interval

case_tk_interval_zero() {
    dr_install
    dr_p MIN_HOURS_review 0
    task_last review 2
    task_failed review 1
    dr_doctor
    dr_has_finding fail "review failed 1h ago and has not completed since: network down" "$(RUN_FIX review)"
}
dr_case "tasks: MIN_HOURS=0 never excuses a failure" case_tk_interval_zero

case_tk_two() {
    dr_install
    task_failed review 9
    task_failed issues 30 '{"reason": "quota"}'
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "issues has never completed; its only record is a failure 30h ago: quota" "$(RUN_FIX issues)"
    dr_has_finding fail "review has never completed; its only record is a failure 9h ago: network down" "$(RUN_FIX review)"
    dr_lacks "every task has completed"
    local a b
    a="$(grep -n "issues has never" "$CZ_CASE/stdout" | cut -d: -f1)"; b="$(grep -n "review has never" "$CZ_CASE/stdout" | cut -d: -f1)"
    [ "${a:-0}" -lt "${b:-0}" ] || cz_note_fail "tasks are not listed in file-name order (issues line $a, review line $b)"
}
dr_case "tasks: two stopped tasks print two FAIL lines in file-name order and no 'every task' line" case_tk_two

# Pins current behaviour (the same class as plan decision F7, a task name with a
# hyphen): the interval lookup `${!_mv:-0}` names MIN_HOURS_read-only, which is not
# a valid variable name. Bash writes an error and drops the rest of that task's
# checks, so a task that stopped is neither reported nor counted, and the
# "every task has completed" line is withheld because the dead count is 1.
case_tk_hyphen_name() {
    dr_install
    task_last read-only 2
    task_failed read-only 1
    dr_doctor
    cz_expect_rc 0
    dr_lacks "read-only"
    dr_lacks "every task has completed"
    cz_expect_stderr_has "MIN_HOURS_read-only: invalid variable name"
    dr_summary 31 0 0
}
dr_case "tasks: a failed task with a hyphen in its name and a success on record is dropped silently, with an error on stderr (pins current behaviour)" case_tk_hyphen_name

# --- Deployed code -----------------------------------------------------------------------------

case_dc_no_stamp() {
    dr_install
    rm -f "$DR_SHARE/VERSION"
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "VERSION does not record what was installed or where from" "reinstall with ./install.sh so the stamp is written"
}
dr_case "deployed: a missing VERSION file is a warning" case_dc_no_stamp

case_dc_half_stamp() {
    dr_install
    printf 'commit=%s\n' "$DR_SHORT" > "$DR_SHARE/VERSION"
    dr_doctor
    dr_has_finding warn "VERSION does not record what was installed or where from" "reinstall with ./install.sh so the stamp is written"
}
dr_case "deployed: a VERSION with a commit and no installed_from is a warning" case_dc_half_stamp

case_dc_source_gone() {
    dr_install
    printf 'commit=%s\ninstalled_from=%s\n' "$DR_SHORT" "$CZ_CASE/gone" > "$DR_SHARE/VERSION"
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "the tree it was installed from is gone: $CZ_CASE/gone" "reinstall from a checkout so drift can be measured"
}
dr_case "deployed: an installed_from with no .git is a warning that names the path" case_dc_source_gone

case_dc_dirty() {
    dr_install
    printf 'x\n' > "$CZ_REPO/new.txt"
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "deployed matches HEAD, but $CZ_REPO has 1 uncommitted change(s)" "commit them, then ./install.sh, or the next run uses neither version"
    dr_has_finding warn "1 uncommitted change(s); a run will refuse to start" "commit or stash"
    dr_summary 30 2 0
}
dr_case "deployed: the right commit with an uncommitted file is a warning that says neither version runs" case_dc_dirty

case_dc_behind() {
    dr_install
    # shellcheck disable=SC2034  # named by cz_commit
    local x
    cz_write two.txt 2; cz_commit two x
    local head; head="$(cz_git rev-parse --short HEAD)"
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "deployed $DR_SHORT is 1 commit(s) behind $CZ_REPO ($head); every timer is running old code" "cd $CZ_REPO && ./install.sh"
    dr_has_finding warn "1 commit(s) ahead of origin/main" "push or reset"
    dr_summary 30 1 1
}
dr_case "deployed: a stamp one commit behind HEAD is a FAIL with the commit count and the reinstall fix" case_dc_behind

case_dc_unknown_commit() {
    dr_install
    printf 'commit=deadbee\ninstalled_from=%s\n' "$CZ_REPO" > "$DR_SHARE/VERSION"
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "deployed deadbee is ? commit(s) behind $CZ_REPO ($DR_SHORT); every timer is running old code" "cd $CZ_REPO && ./install.sh"
}
dr_case "deployed: a stamp the source tree has never seen is '? commit(s) behind'" case_dc_unknown_commit

# Pins current behaviour: the comparison is against the 7-character short hash, so a
# full 40-character stamp for the very same commit reads as old code.
case_dc_full_hash() {
    dr_install
    printf 'commit=%s\ninstalled_from=%s\n' "$(cz_git rev-parse HEAD)" "$CZ_REPO" > "$DR_SHARE/VERSION"
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "deployed $(cz_git rev-parse HEAD) is 0 commit(s) behind $CZ_REPO ($DR_SHORT); every timer is running old code" "cd $CZ_REPO && ./install.sh"
}
dr_case "deployed: a full-length stamp for HEAD reads as '0 commit(s) behind' and fails (pins current behaviour)" case_dc_full_hash

cz_finish
