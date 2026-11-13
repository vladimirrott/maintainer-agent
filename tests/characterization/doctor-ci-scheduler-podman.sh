#!/usr/bin/env bash
# Characterization: bin/maintainer-doctor, the middle of the report. The check
# that main's latest workflow runs are not red (and the grace period), the
# Scheduler section on Linux, Darwin and any other system, and the Container
# verification section: podman from cold, the verify suites' images, their
# recipe fingerprints and the binaries they need, and the userns warm-up unit.
#
# podman, systemctl, loginctl, launchctl and uname are stubs, so the operating
# system and every image and timer are the case's choice.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib-dr.sh"
dr_init

runs2() { printf '[%s,%s]' "${1:1:${#1}-2}" "${2:1:${#2}-2}"; }   # joins two dr_runs lists

# --- main's workflow runs ------------------------------------------------------

CI_UNKNOWN_MSG="could not read main's workflow runs on o/r, so whether main is red is unknown"
CI_UNKNOWN_FIX="gh run list --repo o/r --branch main"

case_ci_none_slug() {
    dr_install
    dr_p_unset REPO_SLUG
    dr_doctor
    cz_expect_rc 0
    dr_lacks "workflow"
    cz_expect_gh_count "run list" 0
}
dr_case "main runs: a profile with no REPO_SLUG skips the check and never calls gh run list" case_ci_none_slug

case_ci_gh_fails() {
    dr_install
    cz_gh run-list "" 1
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "$CI_UNKNOWN_MSG" "$CI_UNKNOWN_FIX"
}
dr_case "main runs: a failing gh run list is a warning that main's state is unknown" case_ci_gh_fails

case_ci_empty_list() {
    dr_install
    cz_gh run-list "[]"
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "$CI_UNKNOWN_MSG" "$CI_UNKNOWN_FIX"
}
dr_case "main runs: an empty run list is unknown, never 'not red'" case_ci_empty_list

case_ci_not_a_list() {
    dr_install
    cz_gh run-list '{"message":"x"}'
    dr_doctor
    dr_has_finding warn "$CI_UNKNOWN_MSG" "$CI_UNKNOWN_FIX"
}
dr_case "main runs: a JSON object instead of a list is unknown" case_ci_not_a_list

case_ci_garbage() {
    dr_install
    cz_gh run-list 'not json at all'
    dr_doctor
    dr_has_finding warn "$CI_UNKNOWN_MSG" "$CI_UNKNOWN_FIX"
}
dr_case "main runs: unparseable output from gh run list is unknown" case_ci_garbage

case_ci_red_old() {
    dr_install
    cz_gh run-list "$(dr_runs failure 10)"
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "main's latest 'CI' run failed 10h ago and main has been red since" "read the failing job: https://example.invalid/run/10"
    dr_lacks "no workflow on main"
}
dr_case "main runs: a failure 10h old with a 6h grace is a FAIL naming the age and the run URL" case_ci_red_old

case_ci_red_young() {
    dr_install
    cz_gh run-list "$(dr_runs failure 2)"
    dr_doctor
    cz_expect_rc 0
    dr_has_finding ok "no workflow on main has been red for 6h or more"
}
dr_case "main runs: a failure 2h old is inside the 6h grace and stays ok" case_ci_red_young

case_ci_grace_env() {
    dr_install
    cz_set MAINTAINER_RED_GRACE_HOURS 1
    cz_gh run-list "$(dr_runs failure 2)"
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "main's latest 'CI' run failed 2h ago and main has been red since" "read the failing job: https://example.invalid/run/2"
}
dr_case "main runs: MAINTAINER_RED_GRACE_HOURS=1 turns a 2h-old failure into a FAIL" case_ci_grace_env

case_ci_grace_in_message() {
    dr_install
    cz_set MAINTAINER_RED_GRACE_HOURS 30
    cz_gh run-list "$(dr_runs success 1)"
    dr_doctor
    dr_has_finding ok "no workflow on main has been red for 30h or more"
}
dr_case "main runs: the ok message names the grace in hours" case_ci_grace_in_message

case_ci_limit_env() {
    dr_install
    cz_set MAINTAINER_DOCTOR_RUN_LIMIT 5
    dr_doctor
    cz_expect_gh_line "$(cz_argv run list --repo o/r --branch main --event push --limit 5 --json workflowName,status,conclusion,createdAt,url)"
}
dr_case "main runs: MAINTAINER_DOCTOR_RUN_LIMIT sets the --limit of gh run list" case_ci_limit_env

case_ci_superseded() {
    dr_install
    cz_gh run-list "$(runs2 "$(dr_runs failure 10)" "$(dr_runs success 1)")"
    dr_doctor
    cz_expect_rc 0
    dr_has_finding ok "no workflow on main has been red for 6h or more"
}
dr_case "main runs: an old failure behind a newer success of the same workflow is not red" case_ci_superseded

case_ci_newest_failure() {
    dr_install
    cz_gh run-list "$(runs2 "$(dr_runs success 10)" "$(dr_runs failure 8)")"
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "main's latest 'CI' run failed 8h ago and main has been red since" "read the failing job: https://example.invalid/run/8"
}
dr_case "main runs: a newer failure over an older success is red" case_ci_newest_failure

case_ci_two_workflows() {
    dr_install
    cz_gh run-list "$(runs2 "$(dr_runs failure 10 Docs)" "$(dr_runs failure 9 'Build and Test')")"
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "main's latest 'Build and Test' run failed 9h ago and main has been red since" "read the failing job: https://example.invalid/run/9"
    dr_has_finding fail "main's latest 'Docs' run failed 10h ago and main has been red since" "read the failing job: https://example.invalid/run/10"
    dr_summary 31 0 2
    # sorted by workflow name
    local a b
    a="$(grep -n "Build and Test" "$CZ_CASE/stdout" | cut -d: -f1)"; b="$(grep -n "'Docs'" "$CZ_CASE/stdout" | cut -d: -f1)"
    [ "${a:-0}" -lt "${b:-0}" ] || cz_note_fail "workflows are not listed in name order (Build and Test at line $a, Docs at line $b)"
}
dr_case "main runs: two red workflows print as two FAIL lines in name order" case_ci_two_workflows

case_ci_in_progress() {
    dr_install
    cz_gh run-list "$(dr_runs '' 10 CI in_progress)"
    dr_doctor
    cz_expect_rc 0
    dr_has_finding ok "no workflow on main has been red for 6h or more"
}
dr_case "main runs: a run still in progress is not red however old it is" case_ci_in_progress

case_ci_queued_failure() {
    dr_install
    cz_gh run-list "$(dr_runs failure 10 CI queued)"
    dr_doctor
    cz_expect_rc 0
    dr_has_finding ok "no workflow on main has been red for 6h or more"
}
dr_case "main runs: a run that is not completed is never red, whatever conclusion it still carries" case_ci_queued_failure

case_ci_cancelled() {
    dr_install
    cz_gh run-list "$(dr_runs cancelled 10)"
    dr_doctor
    cz_expect_rc 0
    dr_has_finding ok "no workflow on main has been red for 6h or more"
}
dr_case "main runs: a cancelled run is not red" case_ci_cancelled

case_ci_null_name() {
    dr_install
    local ts; ts="$(dr_iso_ago 10)"
    cz_gh run-list "[{\"workflowName\":null,\"status\":\"completed\",\"conclusion\":\"failure\",\"createdAt\":\"$ts\",\"url\":null}]"
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "main's latest '?' run failed 10h ago and main has been red since" "read the failing job: "
}
dr_case "main runs: a run with no workflow name prints as '?' and a missing URL leaves the fix empty" case_ci_null_name

# --- Scheduler: Linux -----------------------------------------------------------

case_sc_calls() {
    dr_install
    dr_doctor
    dr_expect_calls systemctl \
        "--user show-environment" \
        "--user list-timers maintainer@magent-\\* --all --no-pager" \
        "--user list-unit-files maintainer@magent-\\*.timer --no-pager" \
        "--user list-timers maintainer@magent-\\* --all --no-pager"
    dr_expect_calls loginctl "show-user fixture-user -p Linger --value"
}
dr_case "scheduler: systemctl and loginctl are called with these exact arguments, scoped to the profile" case_sc_calls

case_sc_one_timer() {
    dr_install
    dr_ans sc-timers "Mon 2026-01-05 10:00:00 UTC 3h left Mon 2026-01-05 04:00:00 UTC 3h ago maintainer@magent-review.timer maintainer@magent-review.service"
    dr_doctor
    cz_expect_rc 0
    dr_has_finding ok "1 systemd timer(s) enabled for magent"
}
dr_case "scheduler: one listed timer line is '1 systemd timer(s) enabled'" case_sc_one_timer

case_sc_disabled() {
    dr_install
    dr_ans sc-timers "" 0
    dr_ans sc-units "$(printf 'maintainer@magent-review.timer disabled enabled\nmaintainer@magent-issues.timer disabled enabled')"
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "2 timer file(s) for magent, none enabled: nothing runs unattended" "./install.sh --timers"
}
dr_case "scheduler: timer files that are not loaded read as 'none enabled' and warn" case_sc_disabled

case_sc_none() {
    dr_install
    dr_ans sc-timers "" 0
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "no timers for magent" "./install.sh --timers"
}
dr_case "scheduler: no timers and no timer files is 'no timers for magent'" case_sc_none

case_sc_other_profile() {
    dr_install
    dr_ans sc-timers "$(printf 'Mon 2026-01-05 10:00:00 UTC 3h left Mon 2026-01-05 04:00:00 UTC 3h ago maintainer@sysknife-review.timer maintainer@sysknife-review.service')" 0
    dr_ans sc-units "maintainer@sysknife-review.timer enabled enabled"
    dr_doctor
    dr_has_finding warn "no timers for magent" "./install.sh --timers"
}
dr_case "scheduler: another profile's timers are not counted for this one" case_sc_other_profile

case_sc_no_session() {
    dr_install
    dr_ans sc-env "" 1
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "no systemd user session" "use platform/posix/install-cron.sh"
    dr_expect_calls loginctl
    dr_expect_calls systemctl "--user show-environment"
}
dr_case "scheduler: a failing systemctl --user show-environment is 'no systemd user session' and stops the section" case_sc_no_session

case_sc_no_systemctl() {
    dr_install
    dr_absent systemctl
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "no systemd user session" "use platform/posix/install-cron.sh"
}
dr_case "scheduler: no systemctl on PATH is 'no systemd user session'" case_sc_no_systemctl

case_linger_off() {
    dr_install
    dr_ans loginctl no
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "lingering off: timers stop when you log out" "sudo loginctl enable-linger fixture-user"
}
dr_case "scheduler: Linger=no warns and the fix names the user" case_linger_off

case_linger_empty() {
    dr_install
    dr_ans loginctl ""
    dr_doctor
    dr_has_finding warn "lingering off: timers stop when you log out" "sudo loginctl enable-linger fixture-user"
}
dr_case "scheduler: an empty loginctl answer counts as lingering off" case_linger_empty

case_linger_no_user_var() {
    dr_install
    cz_unset USER
    dr_ans loginctl no
    dr_doctor
    dr_has_finding warn "lingering off: timers stop when you log out" "sudo loginctl enable-linger idfallback"
    dr_expect_calls loginctl "show-user idfallback -p Linger --value"
}
dr_case "scheduler: with USER unset the user comes from id -un" case_linger_no_user_var

case_timer_soon() {
    dr_install
    dr_ans sc-timers "Mon 12s left maintainer@magent-review.timer maintainer@magent-review.service" 0
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "a timer fires within seconds; Persistent=true may be catching up" "expected after enabling; otherwise check the stamp files"
    dr_has_finding ok "1 systemd timer(s) enabled for magent"
}
dr_case "scheduler: a timer due in seconds is a catch-up warning" case_timer_soon

case_timer_not_soon() {
    dr_install
    dr_ans sc-timers "Mon 3min 5s left maintainer@magent-review.timer maintainer@magent-review.service" 0
    dr_doctor
    dr_lacks "fires within seconds"
}
dr_case "scheduler: a timer due in minutes is not a catch-up warning" case_timer_not_soon

# --- Scheduler: other systems -----------------------------------------------------

case_darwin_agents() {
    dr_install
    dr_os Darwin "$(printf '123\t0\tdev.maintainer.review\n124\t0\tdev.maintainer.issues\n125\t0\tcom.apple.x\n')"
    dr_doctor
    cz_expect_rc 0
    dr_has_finding ok "2 launchd agent(s) loaded"
    dr_has_finding warn "launchd has no Persistent=true" "a run missed while asleep does not catch up"
    dr_expect_calls systemctl
    dr_expect_calls launchctl "list"
    dr_lacks "userns"
    dr_has_finding ok "no systemd user unit to probe on this machine"
}
dr_case "scheduler: on Darwin the agents count comes from launchctl list, with the Persistent warning and no systemd" case_darwin_agents

case_darwin_none() {
    dr_install
    dr_os Darwin "$(printf '125\t0\tcom.apple.x\n126\t0\tcom.example.maintainer-helper\n')"
    dr_doctor
    dr_has_finding warn "no launchd agents" "platform/macos/install-launchd.sh"
    dr_has_finding warn "launchd has no Persistent=true" "a run missed while asleep does not catch up"
}
dr_case "scheduler: on Darwin only labels containing dev.maintainer count, so the doctor warns twice" case_darwin_none

case_other_os() {
    dr_install
    dr_os FreeBSD
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "FreeBSD: no native scheduler wired" "platform/posix/install-cron.sh"
    dr_expect_calls systemctl
}
dr_case "scheduler: another system is 'no native scheduler wired' and never touches systemctl" case_other_os

# --- Container verification -------------------------------------------------------

case_podman_missing() {
    dr_install
    dr_absent podman
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "podman not installed; the merge gate cannot observe a mutation" "install podman"
    dr_lacks "userns"
    dr_lacks "no podman-userns-warmup"
}
dr_case "podman: no podman on PATH is a warning and skips the warm-up check" case_podman_missing

case_podman_cold_fails() {
    dr_install
    dr_ans podman-cold "" 125
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "podman cannot start a container from cold" "check newuidmap and /etc/subuid"
    dr_lacks "podman runs from cold"
}
dr_case "podman: a failing cold start is a FAIL with the newuidmap fix" case_podman_cold_fails

case_podman_calls() {
    dr_install
    dr_doctor
    cz_expect_rc 0
    dr_expect_calls podman \
        "system migrate" \
        "run --rm --network=none docker.io/library/busybox:latest true"
}
dr_case "podman: a deployment with no verify suite makes exactly two podman calls, migrate then the busybox run" case_podman_calls

case_userns_missing() {
    dr_install
    rm -f "$DR_HOME/.config/systemd/user/podman-userns-warmup.service"
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "no podman-userns-warmup.service" "./install.sh; without it a hardened timer cannot start a container"
}
dr_case "podman: a missing podman-userns-warmup.service is a FAIL on Linux" case_userns_missing

# dr_suite NAME IMAGE NEEDS: a verify suite file that names an image and the
# binaries its tests invoke.
dr_suite() {
    local f="$DR_SHARE/profiles/magent/verify.d/$1.sh"
    mkdir -p "${f%/*}"
    { [ -n "$2" ] && printf 'suite_image() { echo %s; }\n' "$2"; [ -n "$3" ] && printf 'suite_needs() { echo "%s"; }\n' "$3"; } > "$f"
    true
}
PROBE_SCRIPT='for b in "$@"; do command -v "$b" >/dev/null 2>&1 || printf "%s " "$b"; done'
dr_probe_call() { cz_argv run --rm --network=none "$1" sh -c "$PROBE_SCRIPT" sh "${@:2}"; }
V="profiles/magent/verify.d"

case_suite_no_needs() {
    dr_install
    dr_suite shell docker.io/library/bash:5 ""
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "verify suite 'shell' declares no suite_needs, so its image is unchecked" "add suite_needs() naming the binaries its tests invoke"
    dr_expect_calls podman "system migrate" "run --rm --network=none docker.io/library/busybox:latest true"
}
dr_case "suite image: a suite without suite_needs is a FAIL and is not probed" case_suite_no_needs

case_suite_broken_file() {
    dr_install
    mkdir -p "$DR_SHARE/$V"
    printf 'suite_needs() { echo python3; \n' > "$DR_SHARE/$V/broken.sh"
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "verify suite 'broken' declares no suite_needs, so its image is unchecked" "add suite_needs() naming the binaries its tests invoke"
}
dr_case "suite image: a suite file that does not parse reads as declaring no suite_needs" case_suite_broken_file

case_suite_ok() {
    dr_install
    dr_suite shell docker.io/library/bash:5 "python3 jq"
    dr_ans podman-probe "" 0
    dr_doctor
    cz_expect_rc 0
    dr_has_finding ok "verify suite 'shell': docker.io/library/bash:5 provides python3 jq"
    dr_expect_calls podman \
        "system migrate" \
        "run --rm --network=none docker.io/library/busybox:latest true" \
        "$(dr_probe_call docker.io/library/bash:5 python3 jq)"
}
dr_case "suite image: needs that all resolve in the image print ok, and the probe call carries the image and each binary as an argument" case_suite_ok

case_suite_missing_bins() {
    dr_install
    dr_suite shell docker.io/library/bash:5 "python3 jq git"
    dr_ans podman-probe "python3 jq " 0
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "verify suite 'shell' runs in docker.io/library/bash:5, which has no: python3 jq" "no receipt is earnable for that suite; change suite_image or suite_needs in $V/shell.sh"
}
dr_case "suite image: binaries the image lacks are listed in a FAIL with the trailing space trimmed" case_suite_missing_bins

case_suite_probe_fails() {
    dr_install
    dr_suite shell docker.io/library/bash:5 "python3"
    dr_ans podman-probe "Error: image not known" 125
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "verify suite 'shell': could not probe docker.io/library/bash:5 (podman exited 125)" "podman pull docker.io/library/bash:5, then re-run; until then this suite's image is unverified"
    dr_lacks "Error: image not known"
}
dr_case "suite image: a failing probe is a warning that names the exit code and never reads as 'nothing missing'" case_suite_probe_fails

case_suite_local_no_recipe() {
    dr_install
    dr_suite shell localhost/mx-test:1 "python3"
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "verify suite 'shell' runs localhost/mx-test:1 and no shell.Containerfile builds it" "add the recipe beside $V/shell.sh"
    dr_expect_calls podman "system migrate" "run --rm --network=none docker.io/library/busybox:latest true"
}
dr_case "suite image: a localhost image with no Containerfile beside the suite is a FAIL and is not probed" case_suite_local_no_recipe

recipe_setup() {  # a localhost suite with a Containerfile; sets RECIPE and BUILD
    dr_install
    dr_suite shell localhost/mx-test:1 "python3"
    local cf="$DR_SHARE/$V/shell.Containerfile"
    printf 'FROM scratch\n' > "$cf"
    RECIPE="$(sha256sum "$cf" | cut -d' ' -f1)"
    BUILD="podman build --label maintainer.recipe=$RECIPE -t localhost/mx-test:1 -f $cf $DR_SHARE/$V"
}

case_suite_local_absent() {
    recipe_setup
    dr_ans podman-exists "" 1
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "verify suite 'shell': localhost/mx-test:1 is not on this host, so nothing can earn a receipt there" "$BUILD"
    dr_expect_calls podman \
        "system migrate" \
        "run --rm --network=none docker.io/library/busybox:latest true" \
        "image exists localhost/mx-test:1"
}
dr_case "suite image: a localhost image that is not on the host is a FAIL carrying the build command with the recipe hash" case_suite_local_absent

case_suite_local_current() {
    recipe_setup
    dr_ans podman-exists "" 0
    dr_ans podman-inspect "$RECIPE" 0
    dr_ans podman-probe "" 0
    dr_doctor
    cz_expect_rc 0
    dr_has_finding ok "verify suite 'shell': localhost/mx-test:1 provides python3"
    dr_expect_calls podman \
        "system migrate" \
        "run --rm --network=none docker.io/library/busybox:latest true" \
        "image exists localhost/mx-test:1" \
        "$(cz_argv image inspect --format '{{index .Config.Labels "maintainer.recipe"}}' localhost/mx-test:1)" \
        "$(dr_probe_call localhost/mx-test:1 python3)"
}
dr_case "suite image: an image whose recipe stamp equals the Containerfile hash goes on to the needs probe" case_suite_local_current

case_suite_local_unstamped() {
    recipe_setup
    dr_ans podman-exists "" 0
    dr_ans podman-inspect "" 0
    dr_ans podman-probe "" 0
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "verify suite 'shell': localhost/mx-test:1 carries no recipe fingerprint, so drift from shell.Containerfile is invisible" "$BUILD"
    # Pins current behaviour: a warning does not stop the suite, so the needs
    # probe still runs and prints its own line.
    dr_has_finding ok "verify suite 'shell': localhost/mx-test:1 provides python3"
}
dr_case "suite image: an unstamped image warns and the needs probe still runs (pins current behaviour)" case_suite_local_unstamped

case_suite_local_novalue() {
    recipe_setup
    dr_ans podman-exists "" 0
    dr_ans podman-inspect "<no value>" 0
    dr_ans podman-probe "" 0
    dr_doctor
    dr_has_finding warn "verify suite 'shell': localhost/mx-test:1 carries no recipe fingerprint, so drift from shell.Containerfile is invisible" "$BUILD"
}
dr_case "suite image: a podman '<no value>' label reads as unstamped" case_suite_local_novalue

case_suite_local_drift() {
    recipe_setup
    dr_ans podman-exists "" 0
    dr_ans podman-inspect "0000000000000000000000000000000000000000000000000000000000000000" 0
    dr_ans podman-probe "jq " 0
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "verify suite 'shell': localhost/mx-test:1 was built from a different shell.Containerfile" "$BUILD"
    dr_has_finding fail "verify suite 'shell' runs in localhost/mx-test:1, which has no: jq" "no receipt is earnable for that suite; change suite_image or suite_needs in $V/shell.sh"
    dr_summary 32 0 2
}
dr_case "suite image: a stamp that differs from the Containerfile hash is a FAIL and the needs probe still runs" case_suite_local_drift

case_suite_two_isolated() {
    dr_install
    dr_suite a docker.io/library/img-a:1 "x"
    printf 'suite_needs() { echo "y"; }\n' > "$DR_SHARE/$V/b.sh"
    dr_ans podman-probe "" 0
    dr_doctor
    dr_has_finding ok "verify suite 'a': docker.io/library/img-a:1 provides x"
    # Pins current behaviour: suite b names no image, and suite a's image does
    # not leak into it, so the probe runs with an empty image name.
    dr_has_finding ok "verify suite 'b':  provides y"
    dr_expect_call_line podman "$(dr_probe_call '' y)"
}
dr_case "suite image: each suite is sourced in its own subshell, so one suite's image never reaches the next" case_suite_two_isolated

case_suite_ignores_other_files() {
    dr_install
    mkdir -p "$DR_SHARE/$V"; printf 'x\n' > "$DR_SHARE/$V/README.md"
    dr_doctor
    cz_expect_rc 0
    dr_lacks "verify suite"
}
dr_case "suite image: only *.sh files in verify.d are suites" case_suite_ignores_other_files

cz_finish
