#!/usr/bin/env bash
# Characterization: bin/maintainer-doctor, the front of the report. The profile
# name rules and the refusals that exit 64, the whole report of a healthy
# deployment, --quick, and the Deployment, Profile and containment, Backend,
# Commands, GitHub identity, Posting and Repository sections.
#
# Every case runs the doctor under `env -i` with a PATH that holds only stubs and
# a farm of plain tools (see lib-dr.sh), so nothing about the host decides a
# result. Messages are pinned by value: the kind of finding (ok, warn, FAIL), its
# exact text, its fix line, and the closing count line.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib-dr.sh"
dr_init



# --- the whole report ---------------------------------------------------------

case_healthy_report() {
    dr_install
    dr_doctor
    cz_expect_rc 0
    cz_expect_stdout "$(dr_exp_healthy)"
    cz_expect_stderr_empty
}
dr_case "report: a healthy deployment prints every section, 32 ok, and exits 0" case_healthy_report

case_healthy_gh_calls() {
    dr_install
    dr_doctor
    cz_expect_rc 0
    # The whole gh conversation of a healthy run, in order: who am I, the runs
    # on main, the pinned token (read by name, never printed).
    cz_expect_gh_log \
        "$(cz_argv api user --jq .login)" \
        "$(cz_argv run list --repo o/r --branch main --event push --limit 40 --json workflowName,status,conclusion,createdAt,url)" \
        "$(cz_argv auth token --user testuser)"
}
dr_case "report: a healthy run makes exactly three gh calls: api user, run list, auth token" case_healthy_gh_calls

case_quick() {
    dr_install
    dr_doctor --quick
    cz_expect_rc 0
    cz_expect_stdout "$(dr_exp_healthy quick)"
    dr_expect_calls podman
}
dr_case "quick: --quick prints 'skipped (--quick)' as a warning with no fix line, calls podman never, exits 0" case_quick

# Pins current behaviour: only the FIRST argument is read.
case_quick_second_arg() {
    dr_install
    dr_doctor now --quick
    cz_expect_rc 0
    dr_has_finding ok "podman runs from cold"
    dr_lacks "skipped (--quick)"
}
dr_case "quick: --quick as a second argument is ignored and the container probe runs" case_quick_second_arg

case_unknown_arg() {
    dr_install
    dr_doctor --verbose
    cz_expect_rc 0
    cz_expect_stdout "$(dr_exp_healthy)"
}
dr_case "quick: an unknown argument is ignored and the full report prints" case_unknown_arg

case_warnings_exit_zero() {
    dr_install
    dr_p_unset POST
    dr_doctor
    cz_expect_rc 0
    dr_summary 31 1 0
}
dr_case "exit: warnings alone leave the exit code 0" case_warnings_exit_zero

case_failure_exit_one() {
    dr_install
    chmod -x "$DR_SHARE/run.sh"
    dr_doctor
    cz_expect_rc 1
    dr_summary 31 0 1
}
dr_case "exit: one failure makes the exit code 1" case_failure_exit_one

# --- the profile name and the refusals ---------------------------------------

case_name_invalid() {
    dr_install
    cz_set MAINTAINER_PROFILE 'x;y'

    dr_doctor
    cz_expect_rc 64
    cz_expect_stdout_empty
    cz_expect_stderr "maintainer-doctor: 'x;y' is not a plain profile name"
}
dr_case "profile name: a name with a semicolon is refused on stderr with exit 64" case_name_invalid

case_name_slash() {
    dr_install
    cz_set MAINTAINER_PROFILE '../evil'
    dr_doctor
    cz_expect_rc 64
    cz_expect_stdout_empty
    cz_expect_stderr "maintainer-doctor: '../evil' is not a plain profile name"
}
dr_case "profile name: a name with a slash is refused with exit 64" case_name_slash

case_name_space() {
    dr_install
    cz_set MAINTAINER_PROFILE 'a b'
    dr_doctor
    cz_expect_rc 64
    cz_expect_stderr "maintainer-doctor: 'a b' is not a plain profile name"
}
dr_case "profile name: a name with a space is refused with exit 64" case_name_space

case_name_plain_chars() {
    dr_install
    mv "$DR_SHARE/profiles/magent" "$DR_SHARE/profiles/my-prof.v2_x"
    # shellcheck disable=SC2034  # read by dr_write_profile in lib-dr.sh
    DR_PROFILE=my-prof.v2_x
    cz_set MAINTAINER_PROFILE my-prof.v2_x
    dr_doctor
    cz_expect_rc 0
    dr_has_finding ok "profile 'my-prof.v2_x' present"
    dr_has_finding warn "no timers for my-prof.v2_x" "./install.sh --timers"
    dr_summary 31 1 0
}
dr_case "profile name: letters, digits, dot, underscore and hyphen are accepted" case_name_plain_chars

case_two_profiles() {
    dr_install
    mkdir -p "$DR_SHARE/profiles/other"; : > "$DR_SHARE/profiles/other/profile.env"
    dr_doctor
    cz_expect_rc 64
    cz_expect_stdout_empty
    cz_expect_stderr \
        "maintainer-doctor: 2 profiles are deployed (magent other)." \
        "                   Set MAINTAINER_PROFILE to say which one to check."
}
dr_case "profile name: two deployed profiles and none named is refused on stderr with exit 64" case_two_profiles

case_two_profiles_named() {
    dr_install
    mkdir -p "$DR_SHARE/profiles/other"; : > "$DR_SHARE/profiles/other/profile.env"
    cz_set MAINTAINER_PROFILE magent
    dr_doctor
    cz_expect_rc 0
    dr_has_finding ok "profile 'magent' present"
    dr_summary 32 0 0
}
dr_case "profile name: MAINTAINER_PROFILE picks one of two deployed profiles" case_two_profiles_named

case_none_deployed() {
    dr_install
    rm -rf "$DR_SHARE/profiles/magent"
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "no profile '(none deployed)'" "check profiles/ in the repository"
    dr_has_finding fail "no deny.json for '(none deployed)'" "every profile needs one; copy profiles/_template/deny.json"
    dr_has_finding warn "no rehearsal wall; POST=off would refuse to start" "./install.sh generates it"
    dr_has_finding fail "the profile names no GH_ACCOUNT" "set it in profile.env; a run refuses to start without one"
    dr_has_finding warn "POST=on: this profile writes to GitHub as ?" "set POST=off in profile.env for a rehearsal week"
    dr_has_finding fail "the profile names no REPO_PATH" "set it in profiles/(none deployed)/profile.env"
    dr_has_finding warn "no timers for (none deployed)" "./install.sh --timers"
    dr_has_finding fail "the profile names no STATE_DIR" "set it in profiles/(none deployed)/profile.env"
    dr_has_finding fail "maintainer is named in the prompts and is NOT on PATH" "install it, or remove it from the prompts and REQUIRED_COMMANDS"
    dr_summary 15 3 7
}
dr_case "profile name: with no profile deployed the report names '(none deployed)' and counts 15 ok, 3 warn, 7 FAIL" case_none_deployed

case_no_profile_sh() {
    dr_install
    dr_tree
    dr_run "$CZ_CASE/tree/bin/maintainer-doctor"
    cz_expect_rc 64
    cz_expect_stdout_empty
    # bash reports the failed source on the line before; ours is the last line.
    cz_check "last stderr line" "$(tail -1 "$CZ_CASE/stderr")" "maintainer-doctor: cannot find profile.sh"
}
dr_case "refusal: no lib/profile.sh beside the program and none deployed exits 64 with 'cannot find profile.sh'" case_no_profile_sh

case_no_defaults() {
    dr_install
    dr_tree profile.sh
    dr_run "$CZ_CASE/tree/bin/maintainer-doctor"
    cz_expect_rc 64
    cz_expect_stdout_empty
    cz_expect_stderr "maintainer: lib/defaults.env not found, so no tunable has a value. Run ./install.sh."
}
dr_case "refusal: no defaults.env beside lib/profile.sh and none deployed exits 64 on stderr" case_no_defaults

case_defaults_deployed() {
    dr_install
    dr_tree profile.sh
    cp "$MX_TREE/lib/defaults.env" "$DR_SHARE/defaults.env"
    dr_run "$CZ_CASE/tree/bin/maintainer-doctor"
    cz_expect_rc 0
    dr_has_finding ok "deny wall generated, 120 rules"
    dr_summary 32 0 0
}
dr_case "refusal: defaults.env is read from the deployed share when the tree has none" case_defaults_deployed

# --- Deployment ---------------------------------------------------------------

case_share_missing() {
    dr_install
    rm -rf "$DR_SHARE"
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "not installed" "run ./install.sh from the repository"
    dr_has_finding ok "no nested profiles/ or backends/"
    dr_has_finding fail "run.sh missing" "./install.sh"
    dr_has_finding fail "run-instance.sh missing" "./install.sh"
}
dr_case "deployment: a missing share directory is 'not installed' and run.sh and run-instance.sh are missing" case_share_missing

case_nested() {
    dr_install
    mkdir -p "$DR_SHARE/old/profiles"
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "3 profiles/backends dirs; a reinstall nested them" "rm -rf $DR_SHARE && ./install.sh"
}
dr_case "deployment: a third profiles/backends directory is a nested reinstall and fails" case_nested

case_run_not_exec() {
    dr_install
    chmod -x "$DR_SHARE/run.sh"
    dr_doctor
    dr_has_finding fail "run.sh is NOT executable" "chmod +x $DR_SHARE/run.sh, then fix install.sh"
}
dr_case "deployment: run.sh without the execute bit fails with the chmod fix" case_run_not_exec

case_run_instance_not_exec() {
    dr_install
    chmod -x "$DR_SHARE/run-instance.sh"
    dr_doctor
    dr_has_finding fail "run-instance.sh is NOT executable" "chmod +x $DR_SHARE/run-instance.sh, then fix install.sh"
}
dr_case "deployment: run-instance.sh without the execute bit fails with the chmod fix" case_run_instance_not_exec

case_run_instance_darwin() {
    dr_install
    dr_os Darwin
    rm -f "$DR_SHARE/run-instance.sh"
    dr_doctor
    dr_has_finding ok "run-instance.sh not needed on Darwin"
    dr_lacks "run-instance.sh missing"
}
dr_case "deployment: a missing run-instance.sh is fine on Darwin" case_run_instance_darwin

case_bin_missing() {
    dr_install
    rm -f "$DR_HOME/.local/bin/maintainer"
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "$DR_HOME/.local/bin/maintainer missing or not executable" "./install.sh"
    dr_has_finding ok "maintainer-merge on PATH and executable"
}
dr_case "deployment: a missing ~/.local/bin/maintainer fails and names the full path" case_bin_missing

case_bin_not_exec() {
    dr_install
    chmod -x "$DR_HOME/.local/bin/maintainer-merge"
    dr_doctor
    dr_has_finding fail "$DR_HOME/.local/bin/maintainer-merge missing or not executable" "./install.sh"
}
dr_case "deployment: a non-executable ~/.local/bin/maintainer-merge fails the same way" case_bin_not_exec

# --- Profile and containment ---------------------------------------------------

case_profile_absent() {
    dr_install
    rm -f "$DR_SHARE/profiles/magent/profile.env"
    cz_set MAINTAINER_PROFILE magent
    dr_doctor
    dr_has_finding fail "no profile 'magent'" "check profiles/ in the repository"
}
dr_case "profile: a named profile without profile.env fails with 'no profile'" case_profile_absent

case_old_template() {
    dr_install
    : > "$DR_SHARE/profiles/magent/settings.json.template"
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "an old settings.json.template is still here" "rm it and re-run ./install.sh; walls are generated from deny.json now"
    dr_lacks "deny wall"
    dr_lacks "no deny.json"
}
dr_case "profile: an old settings.json.template fails and ends the wall checks" case_old_template

case_no_deny_json() {
    dr_install
    rm -f "$DR_SHARE/profiles/magent/deny.json"
    dr_doctor
    dr_has_finding fail "no deny.json for 'magent'" "every profile needs one; copy profiles/_template/deny.json"
    dr_lacks "deny wall generated"
}
dr_case "profile: a missing deny.json fails and ends the wall checks" case_no_deny_json

case_no_wall() {
    dr_install
    rm -f "$DR_SHARE/profiles/magent/settings.json"
    dr_doctor
    dr_has_finding fail "no deny wall at all" "./install.sh"
}
dr_case "profile: a missing settings.json fails with 'no deny wall at all'" case_no_wall

case_wall_invalid() {
    dr_install
    printf 'not json\n' > "$DR_SHARE/profiles/magent/settings.json"
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "deny wall is not valid JSON" "reinstall"
    dr_has_finding fail "no Read(~/...) rule; credential paths are not protected" "check credential_paths in deny.json and re-run ./install.sh"
    dr_summary 30 0 2
}
dr_case "profile: an unparseable settings.json fails twice, as invalid JSON and as lacking Read(~/" case_wall_invalid

case_wall_floor_under() {
    dr_install
    dr_settings "$DR_SHARE/profiles/magent/settings.json" 99
    dr_doctor
    dr_has_finding fail "deny wall has only 99 rules, under the floor of 100; it is stale" "rm -rf $DR_SHARE && ./install.sh"
}
dr_case "profile: 99 deny rules is under the floor of 100 and fails" case_wall_floor_under

case_wall_floor_at() {
    dr_install
    dr_settings "$DR_SHARE/profiles/magent/settings.json" 100
    dr_doctor
    cz_expect_rc 0
    dr_has_finding ok "deny wall generated, 100 rules"
}
dr_case "profile: exactly 100 deny rules passes" case_wall_floor_at

case_wall_floor_env() {
    dr_install
    cz_set MAINTAINER_DENY_WALL_MIN_RULES 150
    dr_doctor
    dr_has_finding fail "deny wall has only 120 rules, under the floor of 150; it is stale" "rm -rf $DR_SHARE && ./install.sh"
}
dr_case "profile: MAINTAINER_DENY_WALL_MIN_RULES overrides the floor" case_wall_floor_env

case_wall_floor_profile() {
    dr_install
    dr_p DENY_WALL_MIN_RULES 10
    dr_settings "$DR_SHARE/profiles/magent/settings.json" 50
    dr_doctor
    cz_expect_rc 0
    dr_has_finding ok "deny wall generated, 50 rules"
}
dr_case "profile: DENY_WALL_MIN_RULES in profile.env overrides the default floor" case_wall_floor_profile

case_wall_home() {
    dr_install
    dr_settings "$DR_SHARE/profiles/magent/settings.json" 120 "Read(__HOME__/.aws/**)"
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "unrendered __HOME__ left in the deny wall" "reinstall"
    dr_has_finding ok "deny wall generated, 120 rules"
}
dr_case "profile: an unrendered __HOME__ in the deny wall fails" case_wall_home

case_wall_no_read_tilde() {
    dr_install
    python3 -c 'import json,sys; json.dump({"permissions":{"deny":["Bash(x%d)"%i for i in range(110)]+["Read(/home/u/.ssh/**)"]}}, open(sys.argv[1],"w"))' \
        "$DR_SHARE/profiles/magent/settings.json"
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "no Read(~/...) rule; credential paths are not protected" "check credential_paths in deny.json and re-run ./install.sh"
    dr_has_finding ok "deny wall generated, 111 rules"
}
dr_case "profile: a wall with only an absolute-path Read rule fails, because it denies nothing" case_wall_no_read_tilde

case_rehearsal_missing() {
    dr_install
    rm -f "$DR_SHARE/profiles/magent/settings-rehearsal.json"
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "no rehearsal wall; POST=off would refuse to start" "./install.sh generates it"
}
dr_case "profile: a missing rehearsal wall is a warning" case_rehearsal_missing

# Pins current behaviour: the rehearsal wall is counted, never validated.
case_rehearsal_invalid() {
    dr_install
    printf 'not json\n' > "$DR_SHARE/profiles/magent/settings-rehearsal.json"
    dr_doctor
    cz_expect_rc 0
    dr_has_finding ok "rehearsal wall present,  rules (POST=off posts nothing)"
}
dr_case "profile: an unparseable rehearsal wall still prints ok, with an empty rule count (pins current behaviour)" case_rehearsal_invalid

case_template_deployed() {
    dr_install
    mkdir -p "$DR_SHARE/profiles/_template"
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "the scaffolding template was deployed" "harmless, but ./install.sh should have skipped it"
}
dr_case "profile: a deployed _template directory is a warning and does not count as a second profile" case_template_deployed

# --- Backend -------------------------------------------------------------------

case_backend_missing() {
    dr_install
    rm -f "$DR_SHARE/backends/claude.sh"
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "backend 'claude' not installed" "./install.sh"
}
dr_case "backend: a missing backends/claude.sh fails" case_backend_missing

case_claude_missing() {
    dr_install
    dr_absent claude
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "claude not on PATH" "install Claude Code"
}
dr_case "backend: claude absent from PATH fails with the install fix" case_claude_missing

case_claude_version() {
    dr_install
    dr_doctor
    dr_has_finding ok "claude on PATH (2.0.0 (Claude Code))"
    dr_lacks "second line"
    dr_expect_calls claude "--version"
}
dr_case "backend: claude is run once with --version and only its first line is shown" case_claude_version

case_codex() {
    dr_install
    dr_p BACKEND codex
    printf 'b\n' > "$DR_SHARE/backends/codex.sh"
    dr_present codex
    dr_doctor
    cz_expect_rc 0
    dr_has_finding ok "backend 'codex' installed"
    dr_has_finding ok "codex on PATH"
    dr_expect_calls claude
}
dr_case "backend: BACKEND=codex checks codex on PATH and never runs claude" case_codex

case_codex_missing() {
    dr_install
    dr_p BACKEND codex
    printf 'b\n' > "$DR_SHARE/backends/codex.sh"
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "codex not on PATH" "npm i -g @openai/codex"
}
dr_case "backend: BACKEND=codex with no codex fails with the npm fix" case_codex_missing

case_cursor() {
    dr_install
    dr_p BACKEND cursor
    printf 'b\n' > "$DR_SHARE/backends/cursor.sh"
    dr_present cursor-agent
    dr_doctor
    cz_expect_rc 0
    dr_has_finding ok "cursor-agent on PATH"
}
dr_case "backend: BACKEND=cursor checks for the cursor-agent binary" case_cursor

case_cursor_missing() {
    dr_install
    dr_p BACKEND cursor
    printf 'b\n' > "$DR_SHARE/backends/cursor.sh"
    dr_doctor
    dr_has_finding fail "cursor-agent not on PATH" "install the Cursor CLI"
}
dr_case "backend: BACKEND=cursor with no cursor-agent fails" case_cursor_missing

case_opencode() {
    dr_install
    dr_p BACKEND opencode
    printf 'b\n' > "$DR_SHARE/backends/opencode.sh"
    dr_present opencode
    dr_doctor
    cz_expect_rc 0
    dr_has_finding ok "opencode on PATH"
}
dr_case "backend: BACKEND=opencode checks for the opencode binary" case_opencode

case_opencode_missing() {
    dr_install
    dr_p BACKEND opencode
    printf 'b\n' > "$DR_SHARE/backends/opencode.sh"
    dr_doctor
    dr_has_finding fail "opencode not on PATH" "curl -fsSL https://opencode.ai/install | bash"
}
dr_case "backend: BACKEND=opencode with no opencode fails with the install fix" case_opencode_missing

case_backend_unknown() {
    dr_install
    dr_p BACKEND mystery
    printf 'b\n' > "$DR_SHARE/backends/mystery.sh"
    dr_doctor
    cz_expect_rc 0
    dr_has_finding ok "backend 'mystery' installed"
    dr_lacks "on PATH ("
    dr_lacks "mystery on PATH"
    dr_summary 31 0 0
}
dr_case "backend: an unknown backend with a script is ok and gets no PATH check" case_backend_unknown

# Pins current behaviour: the doctor reads $BACKEND from the environment when the
# profile does not set it.
case_backend_env() {
    dr_install
    cz_set BACKEND codex
    printf 'b\n' > "$DR_SHARE/backends/codex.sh"
    dr_present codex
    dr_doctor
    dr_has_finding ok "backend 'codex' installed"
    dr_has_finding ok "codex on PATH"
}
dr_case "backend: BACKEND in the environment is used when profile.env sets none (pins current behaviour)" case_backend_env

# --- Commands the prompts tell the agent to run ------------------------------

case_commands_default() {
    dr_install
    dr_p_unset REQUIRED_COMMANDS
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "maintainer is named in the prompts and is NOT on PATH" "install it, or remove it from the prompts and REQUIRED_COMMANDS"
    dr_has_finding fail "maintainer-merge is named in the prompts and is NOT on PATH" "install it, or remove it from the prompts and REQUIRED_COMMANDS"
    dr_has_finding ok "gh resolves"
    dr_has_finding ok "git resolves"
}
dr_case "commands: with REQUIRED_COMMANDS unset the list is maintainer maintainer-merge gh git" case_commands_default

case_commands_default_found() {
    dr_install
    dr_p_unset REQUIRED_COMMANDS
    dr_present maintainer maintainer-merge
    dr_doctor
    cz_expect_rc 0
    dr_has_finding ok "maintainer resolves"
    dr_has_finding ok "maintainer-merge resolves"
    dr_summary 34 0 0
}
dr_case "commands: the default four all resolve when they are on PATH" case_commands_default_found

case_commands_custom() {
    dr_install
    dr_p REQUIRED_COMMANDS "gh frobnicate git"
    dr_doctor
    cz_expect_rc 1
    dr_has_finding ok "gh resolves"
    dr_has_finding fail "frobnicate is named in the prompts and is NOT on PATH" "install it, or remove it from the prompts and REQUIRED_COMMANDS"
    dr_has_finding ok "git resolves"
}
dr_case "commands: a name in REQUIRED_COMMANDS that is not on PATH fails and the others still print" case_commands_custom

# --- GitHub identity -----------------------------------------------------------

case_gh_missing() {
    dr_install
    dr_absent gh
    dr_expect_missing gh
    dr_p REQUIRED_COMMANDS "git"
    dr_doctor
    cz_expect_rc 1
    # Pins current behaviour: the token read is not guarded by `command -v gh`,
    # so the doctor still tries to run gh once and swallows the failure.
    dr_expect_missing_calls "gh auth token --user testuser"
    dr_has_finding fail "gh not installed" "install the GitHub CLI"
    dr_has_finding warn "cannot read the pinned token, so nothing checked whether one was left on disk" "gh auth switch --user testuser"
    dr_lacks "workflow"
}
dr_case "identity: no gh on PATH fails with 'gh not installed' and skips the workflow check" case_gh_missing

case_no_account() {
    dr_install
    dr_p_unset GH_ACCOUNT
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "the profile names no GH_ACCOUNT" "set it in profile.env; a run refuses to start without one"
}
dr_case "identity: a profile with no GH_ACCOUNT fails" case_no_account

case_bad_credentials() {
    dr_install
    cz_gh api-user '{"message":"Bad credentials","status":"401"}' 1
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "GitHub rejects the stored token for testuser (HTTP 401)" "gh auth login -h github.com, signed in as testuser"
    dr_lacks "Bad credentials"
}
dr_case "identity: a 401 body is reported as a rejected token, never as the account name" case_bad_credentials

case_account_case() {
    dr_install
    cz_gh api-user "TestUser"
    dr_doctor
    cz_expect_rc 0
    dr_has_finding ok "gh is TestUser"
}
dr_case "identity: the account match ignores case and prints the name gh reports" case_account_case

case_not_authenticated() {
    dr_install
    cz_gh api-user "gh: To get started with GitHub CLI, please run: gh auth login" 4
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "gh is not authenticated" "gh auth login"
}
dr_case "identity: a failing gh api user that is not a 401 reads as 'not authenticated'" case_not_authenticated

case_empty_login() {
    dr_install
    cz_gh api-user ""
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "gh is not authenticated" "gh auth login"
}
dr_case "identity: a zero exit with an empty login reads as 'not authenticated'" case_empty_login

case_other_account() {
    dr_install
    cz_gh api-user "someoneelse"
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "gh is 'someoneelse', not 'testuser'" "run.sh switches automatically, but check ~/.config/gh/hosts.yml"
}
dr_case "identity: a different active account is a warning, not a failure" case_other_account

# --- Posting -------------------------------------------------------------------

case_post_off() {
    dr_install
    dr_p POST off
    dr_doctor
    dr_has_finding ok "POST=off: this profile writes reports and drafts, and posts nothing"
}
dr_case "posting: POST=off is ok" case_post_off

case_post_unset() {
    dr_install
    dr_p_unset POST
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "POST=on: this profile writes to GitHub as testuser" "set POST=off in profile.env for a rehearsal week"
}
dr_case "posting: POST unset defaults to on and warns, naming the account" case_post_unset

case_post_on() {
    dr_install
    dr_p POST on
    dr_doctor
    dr_has_finding warn "POST=on: this profile writes to GitHub as testuser" "set POST=off in profile.env for a rehearsal week"
}
dr_case "posting: POST=on warns" case_post_on

# Pins current behaviour: the test is the glob *off*, so any value that contains
# the letters passes.
case_post_substring() {
    dr_install
    dr_p POST "never-offline"
    dr_doctor
    dr_has_finding ok "POST=off: this profile writes reports and drafts, and posts nothing"
}
dr_case "posting: any POST value containing 'off' reads as POST=off (pins current behaviour)" case_post_substring

case_post_uppercase() {
    dr_install
    dr_p POST OFF
    dr_doctor
    dr_has_finding warn "POST=on: this profile writes to GitHub as testuser" "set POST=off in profile.env for a rehearsal week"
}
dr_case "posting: POST=OFF in capitals is not off" case_post_uppercase

# --- Repository ------------------------------------------------------------------

case_no_repo_path() {
    dr_install
    dr_p_unset REPO_PATH
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "the profile names no REPO_PATH" "set it in profiles/magent/profile.env"
}
dr_case "repository: a profile with no REPO_PATH fails" case_no_repo_path

case_repo_missing() {
    dr_install
    dr_p REPO_PATH "$CZ_CASE/nowhere"
    dr_doctor
    cz_expect_rc 1
    dr_has_finding fail "no repository at $CZ_CASE/nowhere" "clone it or set REPO_PATH in profile.env"
}
dr_case "repository: a REPO_PATH that does not exist fails" case_repo_missing

case_repo_no_git() {
    dr_install
    mkdir -p "$CZ_CASE/plain"
    dr_p REPO_PATH "$CZ_CASE/plain"
    dr_doctor
    dr_has_finding fail "no repository at $CZ_CASE/plain" "clone it or set REPO_PATH in profile.env"
}
dr_case "repository: a directory without .git is not a repository" case_repo_no_git

case_repo_dirty() {
    dr_install
    printf 'a\n' > "$CZ_REPO/one"; printf 'b\n' > "$CZ_REPO/two"; printf 'c\n' > "$CZ_REPO/three"
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "3 uncommitted change(s); a run will refuse to start" "commit or stash"
    dr_lacks "working tree clean"
}
dr_case "repository: three untracked files are '3 uncommitted change(s)' and a warning" case_repo_dirty

case_repo_ahead() {
    dr_install
    # shellcheck disable=SC2034  # named by cz_commit
    local x
    cz_write one.txt 1; cz_commit one x
    cz_write two.txt 2; cz_commit two x
    printf 'commit=%s\ninstalled_from=%s\n' "$(cz_git rev-parse --short HEAD)" "$CZ_REPO" > "$DR_SHARE/VERSION"
    dr_doctor
    cz_expect_rc 0
    dr_has_finding warn "2 commit(s) ahead of origin/main" "push or reset"
    dr_lacks "not ahead of origin/main"
}
dr_case "repository: two commits past origin/main is '2 commit(s) ahead' and a warning" case_repo_ahead

# Pins current behaviour: rev-list fails when origin/main does not exist, and the
# check substitutes 0, so a repository that never fetched reads as not ahead.
case_repo_no_origin_ref() {
    dr_install
    cz_git update-ref -d refs/remotes/origin/main
    dr_doctor
    cz_expect_rc 0
    dr_has_finding ok "not ahead of origin/main"
}
dr_case "repository: a repository with no origin/main reads as 'not ahead' (pins current behaviour)" case_repo_no_origin_ref

cz_finish
