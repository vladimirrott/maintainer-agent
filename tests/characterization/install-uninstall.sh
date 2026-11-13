#!/usr/bin/env bash
# Characterization: install.sh --uninstall. The guard against removing live
# timers, --dry-run, what is removed and what is kept, the scheduler steps
# (systemd, launchd, cron), and the way failed steps are reported.
#
# Every case runs against stubs for systemctl, crontab and launchctl in a scratch
# HOME. Each case first deploys a real install into that HOME (fixture profiles),
# then empties the call logs.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib-inst.sh"
ci_init

deployed() { ci_fixture_profiles; ci_deploy --timers; }
timers_live() { printf 'maintainer@magent-review.timer   n/a  n/a\nmaintainer@sysknife-ci.timer   n/a n/a\n' > "$CZ_CASE/systemctl.timers"; }

# --- dry run ------------------------------------------------------------------------

case_dry_golden() {
    deployed
    ci_install --uninstall --dry-run
    cz_expect_rc 0
    cz_expect_stderr_empty
    ci_golden_stream stdout uninstall-dry-run.txt
}
ci_case "uninstall dry run: the output is the golden file and exits 0" case_dry_golden

case_dry_changes_nothing() {
    deployed
    ci_snap "$CZ_HOME" > "$CZ_CASE/home.before"; ci_snap "$CZ_TREE" > "$CZ_CASE/tree.before"
    ci_install --uninstall --dry-run
    ci_snap "$CZ_HOME" > "$CZ_CASE/home.after"; ci_snap "$CZ_TREE" > "$CZ_CASE/tree.after"
    ci_expect_same_snap "home" "$CZ_CASE/home.before" "$CZ_CASE/home.after"
    ci_expect_same_snap "tree" "$CZ_CASE/tree.before" "$CZ_CASE/tree.after"
    ci_expect_calls systemctl.calls "--user show-environment"
    ci_expect_calls crontab.calls
    ci_expect_calls launchctl.calls
}
ci_case "uninstall dry run: nothing is removed and systemctl is only asked whether a session exists" case_dry_changes_nothing

case_dry_skips_guard() {
    deployed; timers_live
    ci_install --uninstall --dry-run
    cz_expect_rc 0
    ci_expect_calls systemctl.calls "--user show-environment"
}
ci_case "uninstall dry run: live timers do not stop it and list-timers is never asked" case_dry_skips_guard

# --- the guard against live timers ------------------------------------------------------

case_guard_refuses() {
    deployed; timers_live
    ci_snap "$CZ_HOME" > "$CZ_CASE/home.before"
    ci_install --uninstall
    cz_expect_rc 3
    cz_expect_stdout_empty
    cz_check "stderr" "$(cat "$CZ_CASE/stderr")" "install.sh: 2 maintainer timer(s) are enabled on this machine.
            Removing them stops every profile, including any that
            maintains a repository other than this one.

            Re-run with MAINTAINER_UNINSTALL_YES=1 to go ahead, or
            --dry-run to see what would be removed."
    ci_snap "$CZ_HOME" > "$CZ_CASE/home.after"
    ci_expect_same_snap "home" "$CZ_CASE/home.before" "$CZ_CASE/home.after"
    ci_expect_calls systemctl.calls "--user show-environment" "--user list-timers maintainer@\\* --no-pager"
}
ci_case "uninstall guard: enabled timers exit 3 with the six-line message and remove nothing" case_guard_refuses

case_guard_counts_lines() {
    deployed
    printf 'maintainer@a.timer\nsomething else\nmaintainer@b.timer maintainer@c.timer\n' > "$CZ_CASE/systemctl.timers"
    ci_install --uninstall
    cz_expect_rc 3
    cz_expect_stderr_first "install.sh: 2 maintainer timer(s) are enabled on this machine."
}
ci_case "uninstall guard: the count is the number of listing lines that name maintainer@" case_guard_counts_lines

case_guard_no_timers_listed() {
    deployed
    printf 'NEXT LEFT LAST PASSED UNIT ACTIVATES\n0 timers listed.\n' > "$CZ_CASE/systemctl.timers"
    ci_install --uninstall
    cz_expect_rc 0
}
ci_case "uninstall guard: a listing with no maintainer@ line lets the uninstall run" case_guard_no_timers_listed

case_guard_yes() {
    deployed; timers_live
    cz_set MAINTAINER_UNINSTALL_YES 1
    ci_install --uninstall
    cz_expect_rc 0
    cz_expect_stderr_empty
    ci_expect_calls systemctl.calls "--user show-environment" "--user disable --now maintainer@magent-issues.timer" \
        "--user disable --now maintainer@magent-review.timer" "--user disable --now maintainer@sysknife-audit.timer" \
        "--user disable --now maintainer@sysknife-ci.timer" "--user disable --now maintainer@sysknife-issues.timer" \
        "--user disable --now maintainer@sysknife-review.timer" "--user daemon-reload"
    cz_expect_no_file "$CZ_SHARE"
}
ci_case "uninstall guard: MAINTAINER_UNINSTALL_YES=1 skips the question and removes everything" case_guard_yes

case_guard_only_one_counts() {
    local v
    for v in yes true 0 ""; do
        deployed; timers_live
        cz_set MAINTAINER_UNINSTALL_YES "$v"
        ci_install --uninstall
        cz_check "exit code with MAINTAINER_UNINSTALL_YES='$v'" "$CZ_RC" "3"
        cz_expect_file "$CZ_SHARE/VERSION"
        ci_sandbox_new
    done
}
ci_case "uninstall guard: only the value 1 answers the question" case_guard_only_one_counts

case_guard_no_session() {
    deployed; timers_live; : > "$CZ_CASE/systemctl.noenv"
    ci_install --uninstall
    cz_expect_rc 0
    ci_expect_calls systemctl.calls "--user show-environment" "--user show-environment"
}
ci_case "uninstall guard: with no systemd user session the question is not asked" case_guard_no_session

case_guard_ignores_busy_lock() {
    deployed
    mkdir -p "$CZ_HOME/.local/state/sysknife-maint"; : > "$CZ_HOME/.local/state/sysknife-maint/run.lock"
    printf '1' > "$CZ_CASE/flock.rc"
    ci_install --uninstall
    cz_expect_rc 0
    ci_expect_calls flock.calls
}
ci_case "uninstall: a held run lock is not looked at" case_guard_ignores_busy_lock

# --- what a full uninstall does ------------------------------------------------------------

case_removed_golden() {
    deployed
    ci_install --uninstall
    cz_expect_rc 0
    cz_expect_stderr_empty
    ci_golden_stream stdout uninstall-linux.txt
}
ci_case "uninstall: the output is the golden file and exits 0" case_removed_golden

case_removed_systemctl_calls() {
    deployed
    ci_install --uninstall
    ci_expect_calls systemctl.calls "--user show-environment" "--user list-timers maintainer@\\* --no-pager" \
        "--user show-environment" "--user disable --now maintainer@magent-issues.timer" \
        "--user disable --now maintainer@magent-review.timer" "--user disable --now maintainer@sysknife-audit.timer" \
        "--user disable --now maintainer@sysknife-ci.timer" "--user disable --now maintainer@sysknife-issues.timer" \
        "--user disable --now maintainer@sysknife-review.timer" "--user daemon-reload"
}
ci_case "uninstall: the systemctl calls are the guard, the session probe, one disable per timer, then daemon-reload" case_removed_systemctl_calls

case_removed_files() {
    deployed
    ci_install --uninstall
    cz_expect_no_file "$CZ_SHARE"
    local f
    for f in maintainer maintainer-merge maintainer-doctor maintainer-repo; do cz_expect_no_file "$CZ_HOME/.local/bin/$f"; done
    ls "$CZ_HOME/.config/systemd/user" > "$CZ_CASE/units.left"
    cz_check "unit files left" "$(cat "$CZ_CASE/units.left")" ""
}
ci_case "uninstall: the share directory, four commands and every unit file are removed" case_removed_files

# Pins current behaviour. The removal loop names four commands and install.sh
# deploys five, so maintainer-mcp stays, while the closing message says "the
# four commands".
case_removed_mcp_stays() {
    deployed
    ci_install --uninstall
    cz_expect_file "$CZ_HOME/.local/bin/maintainer-mcp"
}
ci_case "uninstall: maintainer-mcp is left behind in ~/.local/bin (pins current behaviour)" case_removed_mcp_stays

# Pins current behaviour. The stamp files --timers wrote live outside the share
# directory and nothing removes them.
case_removed_stamps_stay() {
    deployed
    ci_install --uninstall
    local n; n="$(find "$CZ_HOME/.local/share/systemd/timers" -type f | wc -l | tr -d ' ')"
    cz_check "stamp files left" "$n" "6"
}
ci_case "uninstall: the six timer stamp files are left behind (pins current behaviour)" case_removed_stamps_stay

# Pins current behaviour. The receipt key sits in the share directory, which goes.
case_removed_key_goes() {
    deployed
    ci_install --uninstall
    cz_expect_no_file "$CZ_SHARE/receipt.key"
}
ci_case "uninstall: the receipt key is removed with the share directory (pins current behaviour)" case_removed_key_goes

case_removed_unit_globs() {
    deployed
    local u="$CZ_HOME/.config/systemd/user"
    : > "$u/other.service"; : > "$u/mine.timer"; : > "$u/maintainer-custom.service"; : > "$u/maintainer@x-y.timer"
    ci_install --uninstall
    cz_expect_file "$u/other.service"
    cz_expect_file "$u/mine.timer"
    cz_expect_no_file "$u/maintainer-custom.service"
    cz_expect_no_file "$u/maintainer@x-y.timer"
}
ci_case "uninstall: units are matched by maintainer*.service and maintainer@*.timer, other units stay" case_removed_unit_globs

case_removed_audit_trail_kept() {
    deployed
    local s="$CZ_HOME/.local/state/sysknife-maint"; mkdir -p "$s/logs"
    printf 'published a comment\n' > "$s/audit.log"; printf 'x\n' > "$s/logs/run.log"
    ci_manifest "$s" > "$CZ_CASE/trail.before"
    ci_install --uninstall
    ci_manifest "$s" > "$CZ_CASE/trail.after"
    ci_expect_same_snap "the audit trail" "$CZ_CASE/trail.before" "$CZ_CASE/trail.after"
    cz_expect_stdout_has "  kept:    the audit trail. Delete it yourself if you want it gone:"
}
ci_case "uninstall: the state directory with the audit trail is not touched" case_removed_audit_trail_kept

case_removed_checkout_untouched() {
    deployed
    ci_manifest "$CZ_TREE" > "$CZ_CASE/tree.before"
    ci_install --uninstall
    ci_manifest "$CZ_TREE" > "$CZ_CASE/tree.after"
    ci_expect_same_snap "the checkout" "$CZ_CASE/tree.before" "$CZ_CASE/tree.after"
}
ci_case "uninstall: the checkout being uninstalled from is not changed" case_removed_checkout_untouched

# Pins current behaviour. The "kept:" lines come from the profiles in the
# checkout, not the deployed ones, and print the STATE_DIR line with the sed
# below applied: the ${MAINTAINER_STATE_DIR:-...} wrapper stays in the text.
case_removed_kept_lines() {
    deployed
    ci_install --uninstall
    cz_expect_stdout_has "           \${MAINTAINER_STATE_DIR:-$CZ_HOME/.local/state/magent-maint}"
    cz_expect_stdout_has "           \${MAINTAINER_STATE_DIR:-$CZ_HOME/.local/state/__PROFILE__-maint}"
}
ci_case "uninstall: the kept-trail lines come from the checkout's profiles, template included, wrapper text included (pins current behaviour)" case_removed_kept_lines

case_removed_kept_line_no_state_dir() {
    deployed
    printf 'TASKS="review"\n' > "$CZ_TREE/profiles/magent/profile.env"
    ci_install --uninstall
    cz_expect_rc 0
    cz_expect_matches stdout '^           $'
}
ci_case "uninstall: a profile with no STATE_DIR line prints an empty kept-trail line" case_removed_kept_line_no_state_dir

case_nothing_deployed() {
    ci_fixture_profiles
    ci_install --uninstall
    cz_expect_rc 0
    cz_expect_stderr_empty
    ci_golden_stream stdout uninstall-nothing-deployed.txt
    ci_expect_calls systemctl.calls "--user show-environment" "--user list-timers maintainer@\\* --no-pager" \
        "--user show-environment" "--user daemon-reload"
    ci_expect_calls crontab.calls
}
ci_case "uninstall: on a machine with nothing deployed it still prints the removal summary and exits 0" case_nothing_deployed

case_timers_flag_ignored() {
    deployed
    ci_install --uninstall --timers --force
    cz_expect_rc 0
    cz_expect_no_file "$CZ_SHARE"
}
ci_case "uninstall: --timers and --force next to --uninstall change nothing" case_timers_flag_ignored

# --- no systemd user session ---------------------------------------------------------------

# Pins current behaviour. The unit files are removed inside the systemd branch, so
# with no session (or no systemctl) they stay while the rest is removed.
case_no_session_units_stay() {
    deployed; : > "$CZ_CASE/systemctl.noenv"
    ci_install --uninstall
    cz_expect_rc 0
    cz_expect_no_file "$CZ_SHARE"
    cz_expect_file "$CZ_HOME/.config/systemd/user/maintainer@.service"
    cz_expect_file "$CZ_HOME/.config/systemd/user/maintainer@sysknife-ci.timer"
    ci_expect_calls systemctl.calls "--user show-environment" "--user show-environment"
}
ci_case "uninstall: with no user session the unit files stay and the rest goes (pins current behaviour)" case_no_session_units_stay

case_no_systemctl_units_stay() {
    deployed; ci_drop_tool systemctl
    ci_install --uninstall
    cz_expect_rc 0
    cz_expect_no_file "$CZ_SHARE"
    cz_expect_file "$CZ_HOME/.config/systemd/user/maintainer@.service"
    cz_expect_stderr_empty
}
ci_case "uninstall: without systemctl the unit files stay and the rest goes (pins current behaviour)" case_no_systemctl_units_stay

# --- failed steps -----------------------------------------------------------------------------

case_failed_disable() {
    deployed; : > "$CZ_CASE/systemctl.fail.disable"
    ci_install --uninstall
    cz_expect_rc 0
    cz_expect_no_file "$CZ_SHARE"
    cz_expect_no_file "$CZ_HOME/.config/systemd/user/maintainer@.service"
    ci_golden_stream stdout uninstall-failed-disable-stdout.txt
    local text; text="$(grep -v '^stub systemctl' "$CZ_CASE/stderr")"
    cz_check "the failed-step list on stderr" "$text" "
  run systemctl --user disable --now maintainer@magent-issues.timer
  run systemctl --user disable --now maintainer@magent-review.timer
  run systemctl --user disable --now maintainer@sysknife-audit.timer
  run systemctl --user disable --now maintainer@sysknife-ci.timer
  run systemctl --user disable --now maintainer@sysknife-issues.timer
  run systemctl --user disable --now maintainer@sysknife-review.timer"
}
ci_case "uninstall: failed disable steps are listed on stderr, everything else is still removed, exit 0 (pins current behaviour)" case_failed_disable

case_failed_cron() {
    deployed; echo 1 > "$CZ_CASE/crontab.w.rc"
    ci_install --uninstall
    cz_expect_rc 0
    cz_expect_no_file "$CZ_SHARE"
    cz_expect_stdout_has "  SOME STEPS FAILED. This deployment is part-removed, and that is the"
    cz_expect_stdout_has "  state to fix rather than to leave:"
    cz_expect_lacks stdout "maintainer entries removed"
    local text; text="$(grep -v '^stub crontab' "$CZ_CASE/stderr")"
    cz_check "the failed-step list on stderr" "$text" "
  run env MAINTAINER_PROFILE=magent $CZ_TREE/platform/posix/install-cron.sh --remove
  run env MAINTAINER_PROFILE=sysknife $CZ_TREE/platform/posix/install-cron.sh --remove"
}
ci_case "uninstall: a crontab that cannot be written is listed as failed and the file removal still happens, exit 0 (pins current behaviour)" case_failed_cron

# --- cron ---------------------------------------------------------------------------------------

case_cron_blocks_removed() {
    deployed
    printf '0 1 * * * /usr/bin/backup\n' > "$CZ_CASE/crontab.store"
    cz_set MAINTAINER_PROFILE magent; ci_cron
    cz_set MAINTAINER_PROFILE sysknife; ci_cron
    cz_unset MAINTAINER_PROFILE
    cz_expect_rc 0
    grep -q '^# maintainer-agent (magent)$' "$CZ_CASE/crontab.store" || cz_note_fail "setup: no magent block in the crontab"
    grep -q '^# maintainer-agent (sysknife)$' "$CZ_CASE/crontab.store" || cz_note_fail "setup: no sysknife block in the crontab"
    ci_reset_logs
    ci_install --uninstall
    cz_expect_rc 0
    ci_expect_bytes "$CZ_CASE/crontab.store" $'0 1 * * * /usr/bin/backup\n'
    ci_expect_calls crontab.calls "-l" "-" "-l" "-"
    cz_expect_stdout_has "  maintainer entries removed"
}
ci_case "uninstall: each deployed profile's cron block is removed and a foreign entry is kept" case_cron_blocks_removed

# Pins current behaviour. The uninstall writes a crontab back even when it held no
# block, and so creates a (blank) crontab on a machine that had none.
case_cron_blank_crontab_created() {
    deployed
    ci_install --uninstall
    ci_expect_bytes "$CZ_CASE/crontab.store" $'\n'
}
ci_case "uninstall: a machine with no crontab gets a blank one written (pins current behaviour)" case_cron_blank_crontab_created

case_cron_no_crontab_tool() {
    deployed; ci_drop_tool crontab
    ci_install --uninstall
    cz_expect_rc 0
    cz_expect_lacks stdout "maintainer entries removed"
    cz_expect_stderr_empty
}
ci_case "uninstall: without crontab the cron step is skipped silently" case_cron_no_crontab_tool

case_cron_only_deployed_profiles() {
    deployed
    rm -rf "$CZ_SHARE/profiles/magent"
    ci_install --uninstall
    ci_expect_calls crontab.calls "-l" "-"
}
ci_case "uninstall: cron removal runs once per deployed profile.env, not per profile in the checkout" case_cron_only_deployed_profiles

# --- launchd ------------------------------------------------------------------------------------

case_darwin_plists() {
    ci_fixture_profiles; ci_uname Darwin; ci_deploy
    local a="$CZ_HOME/Library/LaunchAgents"; mkdir -p "$a"
    : > "$a/dev.maintainer.sysknife.review.plist"; : > "$a/dev.maintainer.magent.issues.plist"; : > "$a/com.other.plist"
    ci_install --uninstall
    cz_expect_rc 0
    cz_expect_no_file "$a/dev.maintainer.sysknife.review.plist"
    cz_expect_no_file "$a/dev.maintainer.magent.issues.plist"
    cz_expect_file "$a/com.other.plist"
    ci_expect_calls launchctl.calls "unload $a/dev.maintainer.magent.issues.plist" "unload $a/dev.maintainer.sysknife.review.plist"
}
ci_case "uninstall: on Darwin each dev.maintainer.*.plist is unloaded and removed, other agents stay" case_darwin_plists

case_linux_leaves_plists() {
    deployed
    local a="$CZ_HOME/Library/LaunchAgents"; mkdir -p "$a"; : > "$a/dev.maintainer.sysknife.review.plist"
    ci_install --uninstall
    cz_expect_file "$a/dev.maintainer.sysknife.review.plist"
    ci_expect_calls launchctl.calls
}
ci_case "uninstall: on Linux launchd agents are not looked at" case_linux_leaves_plists

case_darwin_dry_run() {
    ci_fixture_profiles; ci_uname Darwin; ci_deploy
    local a="$CZ_HOME/Library/LaunchAgents"; mkdir -p "$a"; : > "$a/dev.maintainer.sysknife.review.plist"
    ci_install --uninstall --dry-run
    cz_expect_file "$a/dev.maintainer.sysknife.review.plist"
    cz_expect_stdout_has "  would: launchctl unload $a/dev.maintainer.sysknife.review.plist"
    cz_expect_stdout_has "  would: rm -f $a/dev.maintainer.sysknife.review.plist"
    ci_expect_calls launchctl.calls
}
ci_case "uninstall dry run: on Darwin the launchctl and rm lines are printed and not run" case_darwin_dry_run

cz_finish
