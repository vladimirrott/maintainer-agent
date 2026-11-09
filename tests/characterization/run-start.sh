#!/usr/bin/env bash
# Characterization: how lib/run.sh starts. Finding its tree, the arguments, the
# profile and task checks, the nested-run refusal, and what it exports to the
# helper and the backend. Exit codes are pinned by value, and so is the stream
# each message uses.
#
# Pins current behaviour where the bash program does something a port may be
# asked to change; the comment above such a case names the plan decision, or says
# "no plan decision yet".
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib-run.sh"
cz_init
rz_init

USAGE='usage: run\.sh \[--show-prompt\] <profile> <task>'

# --- arguments ------------------------------------------------------------------

# Pins current behaviour. The usage text is bash's own ${N:?} message, so the
# exit code is 1 and the line carries the script path and a line number. No plan
# decision yet.
case_no_args() {
    rz_setup
    rz_run
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_matches stderr "run.sh: line [0-9]+: 1: $USAGE\$"
    cz_check "stderr is one line" "$(wc -l < "$CZ_CASE/stderr" | tr -d ' ')" 1
    rz_expect_helper
    rz_expect_gh
}
cz_case "arguments: none exits 1 with bash's usage message on stderr, nothing called" case_no_args

case_one_arg() {
    rz_setup
    rz_run fx
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_matches stderr "run.sh: line [0-9]+: 2: $USAGE\$"
    rz_expect_helper
    rz_expect_gh
}
cz_case "arguments: a profile with no task exits 1 naming argument 2" case_one_arg

case_show_alone() {
    rz_setup
    rz_run --show-prompt
    cz_expect_rc 1
    cz_expect_matches stderr "run.sh: line [0-9]+: 1: $USAGE\$"
}
cz_case "arguments: --show-prompt alone leaves the profile missing and exits 1" case_show_alone

case_show_after_profile() {
    rz_setup
    rz_run fx --show-prompt
    cz_expect_rc 64
    cz_expect_stdout_empty
    cz_expect_stderr_first "run.sh: unknown task '--show-prompt'"
}
# Pins current behaviour: --show-prompt is only recognised as the FIRST argument.
cz_case "arguments: --show-prompt after the profile is read as the task name and exits 64" case_show_after_profile

case_empty_profile() {
    rz_setup
    rz_run "" review
    cz_expect_rc 1
    cz_expect_matches stderr "run.sh: line [0-9]+: 1: $USAGE\$"
}
cz_case "arguments: an empty profile name counts as missing and exits 1" case_empty_profile

case_unknown_profile() {
    rz_setup
    rz_run nope review
    cz_expect_rc 64
    cz_expect_stdout_empty
    cz_expect_stderr "run.sh: no profile 'nope'"
    rz_expect_helper
    rz_expect_gh
    rz_expect_no_logs_dir
}
cz_case "profile: an unknown profile exits 64 on stderr and touches nothing" case_unknown_profile

case_unknown_task() {
    rz_setup
    rz_run fx bogus
    cz_expect_rc 64
    cz_expect_stdout_empty
    cz_expect_stderr "run.sh: unknown task 'bogus'"
    rz_expect_helper
    rz_expect_gh
    rz_expect_no_logs_dir
}
cz_case "task: a task the profile does not list exits 64 on stderr and touches nothing" case_unknown_task

case_task_substring() {
    rz_setup
    rz_run fx rev
    cz_expect_rc 64
    cz_expect_stderr "run.sh: unknown task 'rev'"
}
cz_case "task: a prefix of a listed task is unknown (the list is matched by whole words)" case_task_substring

case_no_model() {
    rz_setup
    rz_profile_add 'unset MODEL_review'
    rz_run fx review
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_matches stderr "run.sh: line [0-9]+: !model_var: no model configured for review\$"
    rz_expect_helper
    rz_expect_gh
}
# Pins current behaviour: bash names the unexpanded "!model_var", not MODEL_review.
cz_case "task: a listed task with no MODEL_<task> exits 1 with bash's message" case_no_model

# Pins plan decision F7. A hyphenated task name cannot be a shell variable name,
# so ${!model_var} fails before the helper, gh or a log is touched. The cursor
# backend's only allowed task, readonly-review, is therefore unrunnable.
case_hyphen_task() {
    rz_setup
    rz_wall
    rz_profile_add 'TASKS="review readonly-review"'
    rz_profile_add 'BACKEND=cursor'
    rz_run fx readonly-review
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_matches stderr "run.sh: line [0-9]+: MODEL_readonly-review: invalid variable name\$"
    rz_expect_helper
    rz_expect_gh
    rz_expect_b_not_called cursor-agent
    rz_expect_no_logs_dir
}
cz_case "task: a hyphenated task name dies on the model lookup, exit 1 (plan decision F7)" case_hyphen_task

case_hyphen_task_preview() {
    rz_setup
    rz_profile_add 'TASKS="review readonly-review"'
    rz_run --show-prompt fx readonly-review
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_matches stderr "run.sh: line [0-9]+: MODEL_readonly-review: invalid variable name\$"
}
cz_case "task: the preview of a hyphenated task dies the same way (plan decision F7)" case_hyphen_task_preview

# --- finding the tree -----------------------------------------------------------

# Builds a tree around a copy of run.sh. $1 = directory name under the case.
mk_tree() {
    mkdir -p "$CZ_CASE/$1/lib" "$CZ_CASE/$1/profiles"
    cp "$RZ_TREE/lib/run.sh" "$CZ_CASE/$1/lib/run.sh"
}
run_at() {  # $1 = run.sh path, then arguments
    local rs="$1"; shift
    rz_pairs
    { env -i "${RZ_PAIRS[@]}" "$RZ_TIMEOUT" 60 "$RZ_BASH" "$rs" "$@" > "$CZ_CASE/stdout" 2> "$CZ_CASE/stderr" < /dev/null; } 2>/dev/null
    # shellcheck disable=SC2034  # read by cz_expect_rc in lib.sh
    CZ_RC=$?
}

case_no_profiles_dir() {
    rz_setup
    mkdir -p "$CZ_CASE/lonely"
    cp "$RZ_TREE/lib/run.sh" "$CZ_CASE/lonely/run.sh"
    run_at "$CZ_CASE/lonely/run.sh" fx review
    cz_expect_rc 64
    cz_expect_stdout_empty
    cz_expect_stderr "run.sh: cannot find a profiles/ directory beside or above $CZ_CASE/lonely"
}
cz_case "tree: no profiles directory beside or above run.sh exits 64 naming the directory" case_no_profiles_dir

case_no_backends_dir() {
    rz_setup
    mk_tree t2
    run_at "$CZ_CASE/t2/lib/run.sh" fx review
    cz_expect_rc 64
    cz_expect_stdout_empty
    cz_expect_stderr "run.sh: cannot find a backends/ directory under $CZ_CASE/t2"
}
cz_case "tree: no backends directory exits 64 naming the tree" case_no_backends_dir

case_no_profile_lib() {
    rz_setup
    mk_tree t3
    mkdir -p "$CZ_CASE/t3/lib/backends"
    run_at "$CZ_CASE/t3/lib/run.sh" fx review
    cz_expect_rc 64
    cz_expect_stdout_empty
    cz_expect_stderr "run.sh: cannot find profile.sh beside or under $CZ_CASE/t3"
}
cz_case "tree: no profile.sh exits 64 naming the tree" case_no_profile_lib

case_profile_lib_without_scrub() {
    rz_setup
    mk_tree t4
    mkdir -p "$CZ_CASE/t4/lib/backends"
    printf '# a profile library with no scrub function\n' > "$CZ_CASE/t4/lib/profile.sh"
    run_at "$CZ_CASE/t4/lib/run.sh" fx review
    cz_expect_rc 64
    cz_expect_stdout_empty
    cz_expect_stderr "run.sh: $CZ_CASE/t4/lib/profile.sh defines no maintainer_scrub_secret, so the exit scrub would be a no-op"
}
cz_case "tree: a profile.sh without maintainer_scrub_secret exits 64 before anything runs" case_profile_lib_without_scrub

case_no_defaults() {
    rz_setup
    rm "$RZ_TREE/lib/defaults.env"
    rz_run fx review
    cz_expect_rc 64
    cz_expect_stdout_empty
    cz_expect_stderr "maintainer: lib/defaults.env not found, so no tunable has a value. Run ./install.sh."
    rz_expect_helper
    rz_expect_gh
}
cz_case "tree: no defaults.env exits 64 with the install hint on stderr" case_no_defaults

# The installed layout: run.sh, profile.sh, defaults.env, preamble-core.md and
# backends/ all sit beside profiles/ instead of under lib/.
case_installed_layout() {
    rz_setup
    local t="$CZ_CASE/inst"
    mkdir -p "$t"
    cp -a "$RZ_TREE/lib/backends" "$t/backends"
    cp "$RZ_TREE/lib/run.sh" "$RZ_TREE/lib/profile.sh" "$RZ_TREE/lib/defaults.env" "$RZ_TREE/lib/failure-shapes.json" \
       "$RZ_TREE/lib/preamble-core.md" "$RZ_TREE/lib/prose-style.md" "$t/"
    cp -a "$RZ_TREE/profiles" "$t/profiles"
    cp "$RZ_TREE/VERSION" "$t/VERSION"
    run_at "$t/run.sh" --show-prompt fx review
    cz_expect_rc 0
    cz_expect_stderr_empty
    rz_want_prompt "$CZ_CASE/want.prompt" review claude on "$RZ_PREVIEW_CONTEXT"
    cz_expect_file_equals "$CZ_CASE/stdout" "$CZ_CASE/want.prompt" "the installed-layout prompt"
}
cz_case "tree: the installed layout (everything beside profiles/) assembles the same prompt" case_installed_layout

# --- the nested-run refusal -----------------------------------------------------

case_nested() {
    rz_setup
    cz_set MAINTAINER_IN_RUN other/task
    rz_run fx review
    cz_expect_rc 78
    cz_expect_stdout_empty
    cz_expect_stderr "run.sh: already inside the run 'other/task'; refusing to start 'fx/review' from within it"
    rz_expect_helper
    rz_expect_gh
    rz_expect_no_logs_dir
    rz_expect_b_not_called claude
}
cz_case "nested: starting a run inside a run exits 78 on stderr and touches nothing" case_nested

case_nested_empty_marker() {
    rz_setup
    cz_set MAINTAINER_IN_RUN ""
    rz_run fx review
    cz_expect_rc 0
    rz_expect_helper_count "start review" 1
}
cz_case "nested: an empty MAINTAINER_IN_RUN is not a marker, so the run goes ahead" case_nested_empty_marker

case_nested_preview_exempt() {
    rz_setup
    cz_set MAINTAINER_IN_RUN other/task
    rz_run --show-prompt fx review
    cz_expect_rc 0
    rz_want_prompt "$CZ_CASE/want.prompt" review claude on "$RZ_PREVIEW_CONTEXT"
    cz_expect_file_equals "$CZ_CASE/stdout" "$CZ_CASE/want.prompt" "the preview"
}
cz_case "nested: a preview inside a run is allowed and exits 0" case_nested_preview_exempt

case_nested_checked_before_profile() {
    rz_setup
    cz_set MAINTAINER_IN_RUN other/task
    rz_run nope review
    cz_expect_rc 78
    cz_expect_stderr_first "run.sh: already inside the run 'other/task'; refusing to start 'nope/review' from within it"
}
cz_case "nested: the refusal comes before the profile check, so an unknown profile still exits 78" case_nested_checked_before_profile

# --- what the run exports -------------------------------------------------------

case_exports_to_helper() {
    rz_setup
    cz_set MAINTAINER_FORCE 1
    cz_set GITHUB_TOKEN should-not-travel
    rz_run fx review
    cz_expect_rc 0
    local v
    for v in "MAINTAINER_PROFILE=fx" "MAINTAINER_TASK=review" "MAINTAINER_TASKS=review issues" \
             "MAINTAINER_REPO=$RZ_STATE/checkout" "MAINTAINER_SLUG=fx/repo" "MAINTAINER_STATE=$RZ_STATE" \
             "MAINTAINER_ACCOUNT=fxacct" "MAINTAINER_POST=on" "MAINTAINER_IN_RUN=fx/review" \
             "MAINTAINER_SCRIPTS=$RZ_TREE/scripts" "MAINTAINER_VERSION=9.9.9" "MAINTAINER_COMMIT=abc1234" \
             "PROD_GLOBS=bin/* lib/*" "CLAIM_LABEL=" "PROFILE_DIR=$RZ_PROFILE_DIR" "REPO_PATH=$RZ_STATE/checkout" \
             "MAINTAINER_SKILL=" "MAINTAINER_FORCE=<unset>" "GITHUB_TOKEN=<unset>"; do
        grep -qxF -- "start $v" "$CZ_CASE/h/envlog" || cz_note_fail "the start call did not see $v"
    done
    grep -qxF -- "start GH_TOKEN=match" "$CZ_CASE/h/envlog" || cz_note_fail "the start call did not see the pinned token"
}
# MAINTAINER_SKILL is empty-or-unset: SKILL_review is not in the fixture profile,
# so ${!skill_var:-} is empty and the export makes it set but empty.
cz_case "exports: the helper sees profile, task, repo, slug, state, account, post, in-run marker, scripts, version, token; FORCE and GITHUB_TOKEN stripped" case_exports_to_helper

case_skill_export() {
    rz_setup
    rz_profile_add 'SKILL_review="my-skill"'
    rz_run fx review
    cz_expect_rc 0
    grep -qxF -- "start MAINTAINER_SKILL=my-skill" "$CZ_CASE/h/envlog" || cz_note_fail "MAINTAINER_SKILL was not my-skill"
}
cz_case "exports: SKILL_<task> from the profile reaches the helper as MAINTAINER_SKILL" case_skill_export

case_path_prefix() {
    rz_setup
    printf '#!/usr/bin/env bash\necho "shadow" > "$CZ_CASE_DIR/b/shadow-ran"\nexit 0\n' > "$RZ_HOME/.local/bin/claude"
    chmod +x "$RZ_HOME/.local/bin/claude"
    rz_run fx review
    cz_expect_rc 0
    cz_expect_file "$CZ_CASE/b/shadow-ran"
    rz_expect_b_not_called claude
}
# PATH gets $HOME/.local/bin:$HOME/.cargo/bin in front, so a tool installed
# there wins over the one on the caller's PATH.
cz_case "path: \$HOME/.local/bin is put in front of PATH, so its claude wins" case_path_prefix

case_cargo_prefix() {
    rz_setup
    mkdir -p "$RZ_HOME/.cargo/bin"
    printf '#!/usr/bin/env bash\necho "cargo-shadow" > "$CZ_CASE_DIR/b/shadow-ran"\nexit 0\n' > "$RZ_HOME/.cargo/bin/claude"
    chmod +x "$RZ_HOME/.cargo/bin/claude"
    rz_run fx review
    cz_expect_rc 0
    cz_expect_file "$CZ_CASE/b/shadow-ran"
    rz_expect_b_not_called claude
}
cz_case "path: \$HOME/.cargo/bin is put in front of PATH too" case_cargo_prefix

case_local_bin_before_cargo() {
    rz_setup
    mkdir -p "$RZ_HOME/.cargo/bin"
    printf '#!/usr/bin/env bash\necho local > "$CZ_CASE_DIR/b/which"\n' > "$RZ_HOME/.local/bin/claude"
    printf '#!/usr/bin/env bash\necho cargo > "$CZ_CASE_DIR/b/which"\n' > "$RZ_HOME/.cargo/bin/claude"
    chmod +x "$RZ_HOME/.local/bin/claude" "$RZ_HOME/.cargo/bin/claude"
    rz_run fx review
    cz_check "which claude ran" "$(cat "$CZ_CASE/b/which")" local
}
cz_case "path: .local/bin comes before .cargo/bin" case_local_bin_before_cargo

cz_finish
