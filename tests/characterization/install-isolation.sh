#!/usr/bin/env bash
# Characterization: the harness for the install family keeps the programs away
# from the machine they run on. These cases fail when a program reaches the
# ambient environment, a real scheduler tool or the real HOME.
#
# A decoy directory sits at the END of PATH holding a systemctl, crontab and
# launchctl that write a breach marker. The stubs come first, so a breach means a
# program ran a scheduler tool by a name the stubs do not cover.
# shellcheck disable=SC2034  # CZ_E is read by lib.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib-inst.sh"
ci_init

REAL_HOME="${HOME:-}"

decoy() {  # a directory of scheduler tools that record a breach
    mkdir -p "$CZ_CASE/decoy"
    local t
    for t in systemctl crontab launchctl notify-send; do
        printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/BREACH"\nexit 0\n' "$t" "$CZ_CASE" > "$CZ_CASE/decoy/$t"
        bash -n "$CZ_CASE/decoy/$t"; chmod +x "$CZ_CASE/decoy/$t"
    done
    CZ_E[PATH]="$CZ_CASE/bin:$CZ_TOOLS:$CZ_CASE/decoy"
}

case_decoy_never_reached() {
    ci_fixture_profiles; decoy
    ci_install --timers;                  cz_expect_rc 0
    cz_set MAINTAINER_PROFILE sysknife
    ci_cron;                              cz_expect_rc 0
    ci_launchd;                           cz_expect_rc 0
    ci_alert sysknife-ci;                 cz_expect_rc 0
    cz_unset MAINTAINER_PROFILE
    cz_set MAINTAINER_UNINSTALL_YES 1
    ci_install --uninstall;               cz_expect_rc 0
    cz_expect_no_file "$CZ_CASE/BREACH"
    [ -s "$CZ_CASE/systemctl.calls" ] || cz_note_fail "the systemctl stub was never called, so this case proved nothing"
    [ -s "$CZ_CASE/crontab.calls" ] || cz_note_fail "the crontab stub was never called"
    [ -s "$CZ_CASE/launchctl.calls" ] || cz_note_fail "the launchctl stub was never called"
    [ -s "$CZ_CASE/notify.calls" ] || cz_note_fail "the notify-send stub was never called"
}
ci_case "isolation: install, cron, launchd, alert and uninstall reach the stubs and never the decoys behind them" case_decoy_never_reached

case_decoy_reached_when_stub_absent() {
    ci_fixture_profiles; decoy
    ci_drop_tool systemctl
    CZ_E[PATH]="$CZ_CASE/bin:$CZ_TOOLS:$CZ_CASE/decoy"
    ci_install --timers
    [ -s "$CZ_CASE/BREACH" ] || cz_note_fail "with the stub removed the decoy was not reached: the decoy check cannot detect a breach"
}
ci_case "isolation: positive control, with the systemctl stub removed the decoy is reached and records a breach" case_decoy_reached_when_stub_absent

case_env_is_scrubbed() {
    ci_fixture_profiles
    printf 'env > "%s/env.dump"\n' "$CZ_CASE" >> "$CZ_TREE/profiles/sysknife/profile.env"
    export CZ_AMBIENT_SECRET=leak GH_TOKEN=leak AWS_PROFILE=leak MAINTAINER_PROFILE=leak MAINTAINER_STATE_DIR=/nonexistent
    ci_install
    unset CZ_AMBIENT_SECRET GH_TOKEN AWS_PROFILE MAINTAINER_PROFILE MAINTAINER_STATE_DIR
    cz_expect_rc 0
    [ -s "$CZ_CASE/env.dump" ] || { cz_note_fail "the profile.env hook never ran, so the environment was not observed"; return; }
    local k
    for k in CZ_AMBIENT_SECRET GH_TOKEN AWS_PROFILE MAINTAINER_PROFILE MAINTAINER_STATE_DIR; do
        if grep -q "^$k=" "$CZ_CASE/env.dump"; then cz_note_fail "$k reached the program"; fi
    done
    grep -qx "HOME=$CZ_HOME" "$CZ_CASE/env.dump" || cz_note_fail "HOME is not the case's home"
    grep -qx "LC_ALL=C" "$CZ_CASE/env.dump" || cz_note_fail "LC_ALL is not C"
}
ci_case "isolation: ambient variables (tokens, profile and state overrides) do not reach the program" case_env_is_scrubbed

case_hostile_environment_same_output() {
    ci_fixture_profiles; decoy
    ci_install --dry-run; cp "$CZ_CASE/stdout" "$CZ_CASE/out.calm"; local rc1="$CZ_RC"
    export HOME=/nonexistent XDG_CONFIG_HOME=/nonexistent XDG_STATE_HOME=/nonexistent MAINTAINER_PROFILE=hostile \
        MAINTAINER_UNINSTALL_YES=1 LC_ALL=C.UTF-8 TZ=Pacific/Kiritimati PATH="$CZ_CASE/decoy:$CZ_BASE_PATH"
    ci_install --dry-run; local rc2="$CZ_RC"
    export HOME="$REAL_HOME" PATH="$CZ_BASE_PATH"; unset XDG_CONFIG_HOME XDG_STATE_HOME MAINTAINER_PROFILE MAINTAINER_UNINSTALL_YES
    export LC_ALL=C; unset TZ
    cz_check "exit code" "$rc2" "$rc1"
    cmp -s "$CZ_CASE/out.calm" "$CZ_CASE/stdout" || cz_note_fail "a hostile caller environment changed the output"
}
ci_case "isolation: a hostile caller environment (HOME, PATH, locale, overrides) gives the same output" case_hostile_environment_same_output

case_real_home_not_named() {
    ci_fixture_profiles
    ci_install --timers
    cz_check "case home differs from the real home" "$([ "$CZ_HOME" != "$REAL_HOME" ] && echo yes)" "yes"
    if [ -n "$REAL_HOME" ] && grep -rqF "$REAL_HOME" "$CZ_CASE/stdout" "$CZ_CASE/stderr" "$CZ_CASE/systemctl.calls"; then
        cz_note_fail "the real home path appears in the output or the stub logs"
    fi
}
ci_case "isolation: the real home path appears in no output and no stub log" case_real_home_not_named

case_stubs_fail_loudly() {
    ci_fixture_profiles
    printf 'podman ps\n' >> "$CZ_TREE/profiles/sysknife/profile.env"
    ci_install
    [ -s "$CZ_CASE/unplanned-tools" ] || cz_note_fail "an unplanned podman call was not logged"
    : > "$CZ_CASE/unplanned-tools"
}
ci_case "isolation: positive control, a program that calls podman is logged as an unplanned tool" case_stubs_fail_loudly

cz_finish
