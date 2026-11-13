#!/usr/bin/env bash
# Characterization: platform/posix/install-cron.sh, platform/macos/install-launchd.sh
# and platform/linux/{alert.sh,run-instance.sh}, plus the text of the two unit
# files that wire the alert (plan decision F7: the %n instance mismatch).
#
# crontab, launchctl, systemctl and notify-send are stubs. A case deploys a real
# install into a scratch HOME first, because both installers read the deployed
# profile.env.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib-inst.sh"
ci_init

deployed() { ci_fixture_profiles; ci_deploy; }
cron() { cz_set MAINTAINER_PROFILE "$1"; shift; ci_cron "$@"; cz_unset MAINTAINER_PROFILE; }

# --- install-cron.sh ---------------------------------------------------------------------

case_cron_no_profile() {
    deployed
    ci_cron
    cz_expect_rc 64
    cz_expect_stdout_empty
    cz_expect_stderr "install-cron: no profile name given. Set MAINTAINER_PROFILE=<name>." \
        "              deployed here: magent sysknife "
    ci_expect_calls crontab.calls
}
ci_case "cron: no profile exits 64 and lists the deployed profiles, template excluded" case_cron_no_profile

case_cron_no_profile_nothing_deployed() {
    ci_cron
    cz_expect_rc 64
    cz_expect_stderr "install-cron: no profile name given. Set MAINTAINER_PROFILE=<name>." "              deployed here: "
}
ci_case "cron: no profile and nothing deployed lists nothing" case_cron_no_profile_nothing_deployed

case_cron_no_runsh() {
    ci_fixture_profiles
    cron sysknife
    cz_expect_rc 1
    cz_expect_stderr "install-cron: $CZ_SHARE/run.sh not found; run ./install.sh first"
}
ci_case "cron: a missing deployed run.sh exits 1" case_cron_no_runsh

case_cron_no_crontab() {
    deployed; ci_drop_tool crontab
    cron sysknife
    cz_expect_rc 1
    cz_expect_stderr "install-cron: no crontab on this system"
}
ci_case "cron: no crontab on PATH exits 1" case_cron_no_crontab

case_cron_unknown_profile() {
    deployed
    cron zzz
    cz_expect_rc 1
    cz_expect_stderr "install-cron: no deployed profile 'zzz'"
    ci_expect_calls crontab.calls
}
ci_case "cron: a profile that is not deployed exits 1 before any crontab call" case_cron_unknown_profile

case_cron_dry_sysknife() {
    deployed
    cron sysknife --dry-run
    cz_expect_rc 0
    cz_expect_stderr_empty
    ci_golden_stream stdout cron-dry-run-sysknife.txt
    ci_expect_calls crontab.calls "-l"
}
ci_case "cron dry run: sysknife prints the golden block and only reads the crontab" case_cron_dry_sysknife

case_cron_dry_magent() {
    deployed
    cron magent --dry-run
    ci_golden_stream stdout cron-dry-run-magent.txt
}
ci_case "cron dry run: magent prints two entries at 09:17 and 10:17" case_cron_dry_magent

case_cron_install() {
    deployed
    cron sysknife
    cz_expect_rc 0
    ci_golden_stream stdout cron-install-sysknife.txt
    ci_expect_calls crontab.calls "-l" "-"
    ci_norm "$CZ_CASE/crontab.store" > "$CZ_CASE/norm.store"
    ci_expect_golden_file cron-store-fresh.txt "$CZ_CASE/norm.store"
}
ci_case "cron install: with no crontab the store is a blank line then the block, and three lines are printed" case_cron_install

case_cron_idempotent() {
    deployed
    cron sysknife; cp "$CZ_CASE/crontab.store" "$CZ_CASE/store1"
    cron sysknife
    cz_expect_rc 0
    cmp -s "$CZ_CASE/store1" "$CZ_CASE/crontab.store" || cz_note_fail "the crontab changed on the second install: $(diff "$CZ_CASE/store1" "$CZ_CASE/crontab.store" | head -4 | tr '\n' '|')"
}
ci_case "cron install: running it twice does not change the crontab after the first run" case_cron_idempotent

case_cron_keeps_foreign() {
    deployed
    printf '0 1 * * * /usr/bin/backup\n' > "$CZ_CASE/crontab.store"
    cron magent; cron sysknife
    grep -qx '0 1 \* \* \* /usr/bin/backup' "$CZ_CASE/crontab.store" || cz_note_fail "the foreign entry is gone"
    cz_check "magent blocks" "$(grep -c '^# maintainer-agent (magent)$' "$CZ_CASE/crontab.store")" "1"
    cz_check "sysknife blocks" "$(grep -c '^# maintainer-agent (sysknife)$' "$CZ_CASE/crontab.store")" "1"
    cz_check "first line" "$(head -1 "$CZ_CASE/crontab.store")" "0 1 * * * /usr/bin/backup"
}
ci_case "cron install: foreign entries and other profiles' blocks are kept" case_cron_keeps_foreign

case_cron_replaces_block() {
    deployed
    cron sysknife
    sed -i 's/ci audit/ci/; s/^TASKS=.*/TASKS="review"/' "$CZ_SHARE/profiles/sysknife/profile.env"
    cron sysknife
    cz_check "run.sh lines" "$(grep -c 'run.sh' "$CZ_CASE/crontab.store")" "1"
    cz_expect_stdout_has "  installed 1 cron entries for profile 'sysknife'"
}
ci_case "cron install: a changed task list replaces the block, it does not append" case_cron_replaces_block

case_cron_remove() {
    deployed
    printf '0 1 * * * /usr/bin/backup\n' > "$CZ_CASE/crontab.store"
    cron sysknife; cron magent
    cron sysknife --remove
    cz_expect_rc 0
    cz_expect_stdout "  maintainer entries removed"
    cz_check "sysknife blocks" "$(grep -c 'maintainer-agent (sysknife)' "$CZ_CASE/crontab.store")" "0"
    cz_check "magent blocks" "$(grep -c 'maintainer-agent (magent)$' "$CZ_CASE/crontab.store")" "1"
}
ci_case "cron remove: takes out one profile's block and prints one line" case_cron_remove

case_cron_bad_mode() {
    deployed
    cron sysknife --bogus
    cz_expect_rc 64
    cz_expect_stderr "usage: install-cron.sh [--dry-run|--remove]"
    cz_expect_stdout_empty
    ci_expect_calls crontab.calls "-l"
}
ci_case "cron: an unknown mode exits 64 after reading the crontab, and writes nothing" case_cron_bad_mode

case_cron_write_fails() {
    deployed; echo 1 > "$CZ_CASE/crontab.w.rc"
    cron sysknife
    cz_expect_rc 1
    cz_expect_lacks stdout "installed"
}
ci_case "cron install: a crontab that cannot be written exits 1 without the success lines" case_cron_write_fails

# --- install-launchd.sh --------------------------------------------------------------------

case_launchd_no_profile() {
    deployed
    ci_launchd
    cz_expect_rc 64
    cz_expect_stderr "install-launchd: no profile name given. Pass it as an argument or set MAINTAINER_PROFILE." \
        "                 deployed here: magent sysknife "
}
ci_case "launchd: no profile exits 64 and lists the deployed profiles" case_launchd_no_profile

case_launchd_unknown() {
    deployed
    ci_launchd nope
    cz_expect_rc 1
    cz_expect_stderr "install-launchd: no deployed profile 'nope'; run ./install.sh first"
    cz_expect_no_file "$CZ_HOME/Library"
}
ci_case "launchd: a profile that is not deployed exits 1 and creates nothing" case_launchd_unknown

case_launchd_load() {
    deployed
    ci_launchd sysknife
    cz_expect_rc 0
    cz_expect_stderr_empty
    ci_golden_stream stdout launchd-load-sysknife.txt
    local a="$CZ_HOME/Library/LaunchAgents" calls=() t
    for t in review issues ci audit; do
        calls+=("unload $a/dev.maintainer.sysknife.$t.plist" "load $a/dev.maintainer.sysknife.$t.plist")
    done
    ci_expect_calls launchctl.calls "${calls[@]}"
    cz_expect_file "$CZ_HOME/.local/state/sysknife-maint/logs"
}
ci_case "launchd: each task is unloaded then loaded, in TASKS order, and the log directory is made" case_launchd_load

case_launchd_plists() {
    deployed
    ci_launchd sysknife
    local t
    for t in review issues ci audit; do
        ci_dump "$CZ_HOME/Library/LaunchAgents" "dev.maintainer.sysknife.$t.plist"
    done > "$CZ_CASE/dump"
    ci_golden_path launchd-plists-sysknife.txt "$CZ_CASE/dump"
}
ci_case "launchd: the four plists are the golden text" case_launchd_plists

case_launchd_env_profile() {
    deployed
    cz_set MAINTAINER_PROFILE magent
    ci_launchd
    cz_expect_rc 0
    cz_expect_stdout_has "  loaded dev.maintainer.magent.review (fires daily at 09:17; runs when 6h have passed)"
}
ci_case "launchd: the profile can come from MAINTAINER_PROFILE" case_launchd_env_profile

case_launchd_arg_beats_env() {
    deployed
    cz_set MAINTAINER_PROFILE magent
    ci_launchd sysknife
    cz_expect_stdout_has "dev.maintainer.sysknife.review"
    cz_expect_lacks stdout "dev.maintainer.magent"
}
ci_case "launchd: an argument wins over MAINTAINER_PROFILE" case_launchd_arg_beats_env

case_launchd_missing_min_hours() {
    deployed
    sed -i 's/^TASKS=.*/TASKS="review nomin"/' "$CZ_SHARE/profiles/magent/profile.env"
    ci_launchd magent
    cz_expect_stdout_has "  loaded dev.maintainer.magent.nomin (fires daily at 10:17; runs when 0h have passed)"
}
ci_case "launchd: a task with no MIN_HOURS value prints 0h" case_launchd_missing_min_hours

case_launchd_remove() {
    deployed
    ci_launchd sysknife; ci_reset_logs
    : > "$CZ_HOME/Library/LaunchAgents/dev.maintainer.magent.review.plist"; : > "$CZ_HOME/Library/LaunchAgents/other.plist"
    ci_launchd --remove sysknife
    cz_expect_rc 0
    cz_expect_stdout "  removed dev.maintainer.sysknife.audit.plist" "  removed dev.maintainer.sysknife.ci.plist" \
        "  removed dev.maintainer.sysknife.issues.plist" "  removed dev.maintainer.sysknife.review.plist"
    cz_expect_file "$CZ_HOME/Library/LaunchAgents/dev.maintainer.magent.review.plist"
    cz_expect_file "$CZ_HOME/Library/LaunchAgents/other.plist"
    cz_check "unload calls" "$(grep -c '^unload ' "$CZ_CASE/launchctl.calls")" "4"
}
ci_case "launchd remove: unloads and deletes one profile's plists in name order and nothing else" case_launchd_remove

case_launchd_remove_no_profile() {
    deployed
    ci_launchd --remove
    cz_expect_rc 64
}
ci_case "launchd remove: --remove without a profile exits 64" case_launchd_remove_no_profile

case_launchd_load_fails() {
    deployed; : > "$CZ_CASE/launchctl.fail.load"
    ci_launchd sysknife
    cz_expect_rc 1
    cz_expect_lacks stdout "loaded"
    cz_expect_file "$CZ_HOME/Library/LaunchAgents/dev.maintainer.sysknife.review.plist"
    cz_expect_no_file "$CZ_HOME/Library/LaunchAgents/dev.maintainer.sysknife.issues.plist"
}
ci_case "launchd: a failing load stops at the first plist with exit 1 (pins current behaviour)" case_launchd_load_fails

case_launchd_unload_fails() {
    deployed; : > "$CZ_CASE/launchctl.fail.unload"
    ci_launchd sysknife
    cz_expect_rc 0
    cz_expect_stdout_has "  done. list with: launchctl list | grep dev.maintainer.sysknife"
}
ci_case "launchd: a failing unload of a plist that was not loaded is ignored" case_launchd_unload_fails

# --- alert.sh ---------------------------------------------------------------------------------

MSG="the run unit failed before it could report; systemd killed or refused it"
LOGLINE() { printf '2026-01-01T00:00:00+00:00  ALERT %s: %s\n' "$1" "$MSG"; }
state() { mkdir -p "$CZ_HOME/.local/state/$1-maint"; }
alerts() { cat "$CZ_HOME/.local/state/$1-maint/logs/alerts.log" 2>/dev/null; }

case_alert_own_profile() {
    state sysknife; state magent
    ci_alert sysknife-ci
    cz_expect_rc 0
    cz_expect_stdout_empty
    cz_check "sysknife alerts.log" "$(alerts sysknife)" "$(LOGLINE sysknife-ci)"
    cz_expect_no_file "$CZ_HOME/.local/state/magent-maint/logs"
}
ci_case "alert: the line goes to the failing profile's directory and to no other" case_alert_own_profile

case_alert_hyphenated_profile() {
    state my-repo; state my
    ci_alert my-repo-review
    cz_check "my-repo alerts.log" "$(alerts my-repo)" "$(LOGLINE my-repo-review)"
    cz_expect_no_file "$CZ_HOME/.local/state/my-maint/logs"
}
ci_case "alert: the profile is everything before the last hyphen" case_alert_hyphenated_profile

case_alert_appends() {
    state sysknife
    ci_alert sysknife-ci; ci_alert sysknife-issues
    cz_check "alerts.log" "$(alerts sysknife)" "$(LOGLINE sysknife-ci)
$(LOGLINE sysknife-issues)"
}
ci_case "alert: a second alert appends to alerts.log" case_alert_appends

case_alert_fallback_all() {
    state sysknife; state magent
    ci_alert ghost-review
    cz_check "sysknife" "$(alerts sysknife)" "$(LOGLINE ghost-review)"
    cz_check "magent" "$(alerts magent)" "$(LOGLINE ghost-review)"
}
ci_case "alert: with no directory for the profile, every *-maint directory gets the line" case_alert_fallback_all

case_alert_no_state() {
    ci_snap "$CZ_HOME" > "$CZ_CASE/home.before"
    ci_alert sysknife-ci
    cz_expect_rc 0
    ci_snap "$CZ_HOME" > "$CZ_CASE/home.after"
    ci_expect_same_snap "home" "$CZ_CASE/home.before" "$CZ_CASE/home.after"
}
ci_case "alert: with no *-maint directory at all nothing is written and it exits 0" case_alert_no_state

case_alert_no_argument() {
    state sysknife
    ci_alert
    cz_expect_rc 0
    cz_check "sysknife" "$(alerts sysknife)" "$(LOGLINE unknown)"
}
ci_case "alert: no argument reports the instance as unknown, through the fallback" case_alert_no_argument

case_alert_no_hyphen() {
    state solo
    ci_alert solo
    cz_check "solo" "$(alerts solo)" "$(LOGLINE solo)"
}
ci_case "alert: an instance with no hyphen is its own profile name" case_alert_no_hyphen

case_alert_notify() {
    state sysknife
    ci_alert sysknife-ci
    local uid; uid="$(id -u)"
    cz_check "notify-send" "$(cat "$CZ_CASE/notify.calls")" "argv: -u critical -a maintainer \$'maintainer \\302\\267 sysknife-ci \\302\\267 FAILED' \$'$MSG\\nfix    maintainer-doctor\\nthen   journalctl --user -u maintainer@sysknife-ci.service -n 40'
DISPLAY=:1
DBUS=unix:path=/run/user/$uid/bus"
}
ci_case "alert: notify-send gets a critical title and a body naming the journalctl command, with DISPLAY :1" case_alert_notify

case_alert_notify_env_kept() {
    state sysknife
    cz_set DISPLAY :7; cz_set DBUS_SESSION_BUS_ADDRESS unix:path=/x/bus
    ci_alert sysknife-ci
    cz_expect_matches stdout '^$'
    grep -qx 'DISPLAY=:7' "$CZ_CASE/notify.calls" || cz_note_fail "DISPLAY was not kept"
    grep -qx 'DBUS=unix:path=/x/bus' "$CZ_CASE/notify.calls" || cz_note_fail "the bus address was not kept"
}
ci_case "alert: DISPLAY and DBUS_SESSION_BUS_ADDRESS from the caller are passed on" case_alert_notify_env_kept

case_alert_notify_off() {
    state sysknife
    cz_set MAINTAINER_NOTIFY off
    ci_alert sysknife-ci
    cz_expect_rc 0
    ci_expect_calls notify.calls
    cz_check "alerts.log" "$(alerts sysknife)" "$(LOGLINE sysknife-ci)"
}
ci_case "alert: MAINTAINER_NOTIFY=off still writes the log and skips the popup" case_alert_notify_off

case_alert_notify_missing() {
    state sysknife; ci_drop_tool notify-send
    ci_alert sysknife-ci
    cz_expect_rc 0
    cz_expect_stderr_empty
    cz_check "alerts.log" "$(alerts sysknife)" "$(LOGLINE sysknife-ci)"
}
ci_case "alert: without notify-send it exits 0 and says nothing" case_alert_notify_missing

case_alert_notify_fails() {
    state sysknife; echo 1 > "$CZ_CASE/notify.rc"
    ci_alert sysknife-ci
    cz_expect_rc 0
}
ci_case "alert: a failing notify-send does not change the exit code" case_alert_notify_fails

# Plan decision F7. systemd passes %n, the full unit name, as the instance, so
# alert.sh gets "maintainer@sysknife-ci.service" where it expects "sysknife-ci".
# The profile it derives is then "maintainer@sysknife", which has no state
# directory, so the alert lands in EVERY *-maint directory, and the popup names
# a unit that does not exist. Pinned here so the port reproduces it until the
# decision is made.
case_alert_f7_instance() {
    state sysknife; state magent
    ci_alert maintainer@sysknife-ci.service
    cz_check "sysknife alerts.log" "$(alerts sysknife)" "$(LOGLINE maintainer@sysknife-ci.service)"
    cz_check "magent alerts.log" "$(alerts magent)" "$(LOGLINE maintainer@sysknife-ci.service)"
    grep -qF 'journalctl --user -u maintainer@maintainer@sysknife-ci.service.service -n 40' "$CZ_CASE/notify.calls" \
        || cz_note_fail "the popup does not name the doubled unit"
}
ci_case "alert F7: the instance systemd passes lands the alert in every profile's log (pins current behaviour, plan decision F7)" case_alert_f7_instance

case_unit_text_f7() {
    grep -qx 'OnFailure=maintainer-alert@%n.service' "$CZ_TREE/platform/linux/maintainer@.service" || cz_note_fail "maintainer@.service no longer says OnFailure=maintainer-alert@%n.service"
    grep -qx 'ExecStart=%h/.local/share/maintainer/alert.sh %i' "$CZ_TREE/platform/linux/maintainer-alert@.service" || cz_note_fail "maintainer-alert@.service no longer passes %i"
    cz_check "OnFailure lines" "$(grep -c '^OnFailure=' "$CZ_TREE/platform/linux/maintainer@.service")" "1"
}
ci_case "alert F7: the run unit hands %n to the alert unit, which passes %i to alert.sh (pins current behaviour, plan decision F7)" case_unit_text_f7

# --- the unit files, as deployed -----------------------------------------------------------------

case_units_golden() {
    deployed
    ci_dump "$CZ_HOME/.config/systemd/user" > "$CZ_CASE/dump"
    ci_golden_path deployed-units-linux.txt "$CZ_CASE/dump"
}
ci_case "units: every deployed unit file is the golden text" case_units_golden

# --- run-instance.sh -------------------------------------------------------------------------------

mkinst() {  # a directory holding run-instance.sh and a run.sh that logs its argv
    mkdir -p "$CZ_CASE/inst"
    cp "$CZ_TREE/platform/linux/run-instance.sh" "$CZ_CASE/inst/run-instance.sh"
    cat > "$CZ_CASE/inst/run.sh" <<'RUN'
#!/usr/bin/env bash
printf '%s\n' "$#:$*" >> "${CZ_CASE_DIR:?}/run.calls"
exit "${RUN_RC:-0}"
RUN
    bash -n "$CZ_CASE/inst/run.sh"; chmod +x "$CZ_CASE/inst/run-instance.sh" "$CZ_CASE/inst/run.sh"
}

case_inst_split() {
    mkinst
    ci_run "$CZ_CASE/inst/run-instance.sh" sysknife-ci
    cz_expect_rc 0
    ci_expect_calls run.calls "2:sysknife ci"
}
ci_case "run-instance: sysknife-ci runs run.sh with the profile sysknife and the task ci" case_inst_split

case_inst_last_hyphen() {
    mkinst
    ci_run "$CZ_CASE/inst/run-instance.sh" my-repo-review
    ci_expect_calls run.calls "2:my-repo review"
}
ci_case "run-instance: the split is at the last hyphen" case_inst_last_hyphen

case_inst_no_hyphen() {
    mkinst
    ci_run "$CZ_CASE/inst/run-instance.sh" solo
    ci_expect_calls run.calls "2:solo solo"
}
ci_case "run-instance: an instance with no hyphen is both profile and task (pins current behaviour)" case_inst_no_hyphen

case_inst_exit_code() {
    mkinst; cz_set RUN_RC 75
    ci_run "$CZ_CASE/inst/run-instance.sh" a-b
    cz_expect_rc 75
}
ci_case "run-instance: the exit code is run.sh's, by exec" case_inst_exit_code

case_inst_no_argument() {
    mkinst
    ci_run "$CZ_CASE/inst/run-instance.sh"
    cz_expect_rc 1
    cz_expect_stderr_has "usage: run-instance.sh <profile>-<task>"
    ci_expect_calls run.calls
}
ci_case "run-instance: no argument exits 1 with the usage text and runs nothing" case_inst_no_argument

case_inst_symlink() {
    mkinst
    mkdir -p "$CZ_CASE/elsewhere"; ln -s "$CZ_CASE/inst/run-instance.sh" "$CZ_CASE/elsewhere/ri.sh"
    ci_run "$CZ_CASE/elsewhere/ri.sh" a-b
    cz_expect_rc 0
    ci_expect_calls run.calls "2:a b"
}
ci_case "run-instance: run.sh is found beside the script's real path, through a symlink" case_inst_symlink

cz_finish
