#!/usr/bin/env bash
# Characterization: new-profile.sh. The files it generates for two inputs (byte
# for byte, through goldens), the systemd timers it writes, its refusals, and
# the substitution rules.
#
# new-profile.sh writes into its own tree, so every case has a private copy.
# Most cases use a small fixture _template (ci_fixture_profiles) with the five
# placeholders in a profile.env, a deny.json and a prompt; one case runs the
# real template.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib-inst.sh"
ci_init

USAGE_LINES=(
"# Scaffold a profile for another repository."
"#"
"#   ./new-profile.sh <profile> <owner/repo> <path-to-checkout> <gh-account> \"<your name>\""
"#"
"# Writes profiles/<profile>/ and the systemd units for it, then tells you the"
"# three things to do before the first run. Nothing is enabled and nothing posts:"
"# a new profile starts at POST=off, so the first week produces reports and"
"# drafts and reaches nobody.")

# The two inputs the goldens are made from.
alpha() { mkdir -p "$CZ_HOME/code/widgets"; ci_newprof alpha acme/widgets "$CZ_HOME/code/widgets" alice "Alice Example"; }
beta()  { mkdir -p "$CZ_CASE/co/.git"; ci_newprof beta-2 org/proj-x "$CZ_CASE/co" bob; }

tree_before() { ci_manifest "$CZ_TREE" > "$CZ_CASE/tree.before"; }
only_new_files() {  # $1.. = path prefixes the run may have created; anything else that changed fails
    ci_manifest "$CZ_TREE" > "$CZ_CASE/tree.after"
    local line path ok p
    while IFS= read -r line; do
        path="${line#* * }"; ok=0
        for p in "$@"; do case "$path" in "$p"*) ok=1 ;; esac; done
        [ "$ok" = 1 ] || cz_note_fail "the run changed a file outside its profile and unit files: $path"
    done < <(diff "$CZ_CASE/tree.before" "$CZ_CASE/tree.after" | grep '^[<>]' | sed 's/^[<>] //')
}

# --- the generated files, byte for byte -----------------------------------------------

case_alpha_stdout() {
    ci_fixture_profiles
    alpha
    cz_expect_rc 0
    cz_expect_stderr_empty
    ci_golden_stream stdout new-profile-alpha-stdout.txt
}
ci_case "alpha (path under HOME, no checkout): the output is the golden file, with the not-a-checkout warning" case_alpha_stdout

case_alpha_files() {
    ci_fixture_profiles
    alpha
    ci_dump "$CZ_TREE/profiles/alpha" > "$CZ_CASE/dump"
    ci_golden_path new-profile-alpha-profile.txt "$CZ_CASE/dump"
}
ci_case "alpha: every file of profiles/alpha is the golden text" case_alpha_files

case_alpha_timers() {
    ci_fixture_profiles
    alpha
    ci_dump "$CZ_TREE/platform/linux" maintainer@alpha-review.timer maintainer@alpha-issues.timer > "$CZ_CASE/dump"
    ci_golden_path new-profile-alpha-timers.txt "$CZ_CASE/dump"
}
ci_case "alpha: the two timer units are the golden text, 09:17 and 10:17" case_alpha_timers

case_beta_stdout() {
    ci_fixture_profiles
    beta
    cz_expect_rc 0
    cz_expect_stderr_empty
    cz_expect_lacks stdout "warning"
    ci_golden_stream stdout new-profile-beta-stdout.txt
}
ci_case "beta (path outside HOME, checkout present, no name): the output is the golden file and has no warning" case_beta_stdout

case_beta_files() {
    ci_fixture_profiles
    beta
    ci_dump "$CZ_TREE/profiles/beta-2" > "$CZ_CASE/dump"
    ci_golden_path new-profile-beta-profile.txt "$CZ_CASE/dump"
}
ci_case "beta: every file of profiles/beta-2 is the golden text, the account standing in for the name" case_beta_files

case_beta_timers() {
    ci_fixture_profiles
    beta
    ci_dump "$CZ_TREE/platform/linux" maintainer@beta-2-review.timer maintainer@beta-2-issues.timer > "$CZ_CASE/dump"
    ci_golden_path new-profile-beta-timers.txt "$CZ_CASE/dump"
}
ci_case "beta: a hyphenated profile name gives maintainer@beta-2-<task> units" case_beta_timers

# --- what it writes, and where -------------------------------------------------------------

case_writes_only_its_own_files() {
    ci_fixture_profiles; tree_before; mkdir -p "$CZ_HOME/code/widgets"
    ci_snap "$CZ_HOME" > "$CZ_CASE/home.before"
    alpha
    cz_expect_rc 0
    only_new_files "./profiles/alpha/" "./platform/linux/maintainer@alpha-"
    ci_snap "$CZ_HOME" > "$CZ_CASE/home.after"
    ci_expect_same_snap "home" "$CZ_CASE/home.before" "$CZ_CASE/home.after"
    ci_expect_calls systemctl.calls
    ci_expect_calls crontab.calls
}
ci_case "writes: only profiles/<name>/ and the two timers appear, HOME is untouched, no scheduler runs" case_writes_only_its_own_files

case_template_unchanged() {
    ci_fixture_profiles
    ci_manifest "$CZ_TREE/profiles/_template" > "$CZ_CASE/t.before"
    alpha
    ci_manifest "$CZ_TREE/profiles/_template" > "$CZ_CASE/t.after"
    ci_expect_same_snap "the template" "$CZ_CASE/t.before" "$CZ_CASE/t.after"
}
ci_case "writes: profiles/_template is not changed" case_template_unchanged

case_file_without_placeholder_copied() {
    ci_fixture_profiles
    alpha
    cmp -s "$CZ_TREE/profiles/_template/notes.txt" "$CZ_TREE/profiles/alpha/notes.txt" || cz_note_fail "a template file with no placeholder was changed"
}
ci_case "writes: a template file with no placeholder is copied byte for byte" case_file_without_placeholder_copied

case_profile_env_sources() {
    ci_fixture_profiles
    alpha
    local got
    got="$(env -i HOME="$CZ_HOME" PATH="$CZ_TOOLS" bash -c '. "$1"; printf "%s|%s|%s|%s|%s|%s" "$PROFILE_NAME" "$REPO_PATH" "$REPO_SLUG" "$MAINTAINER_NAME" "$GH_ACCOUNT" "$STATE_DIR"' _ "$CZ_TREE/profiles/alpha/profile.env")"
    cz_check "values after sourcing" "$got" "alpha|$CZ_HOME/code/widgets|acme/widgets|Alice Example|alice|$CZ_HOME/.local/state/alpha-maint"
}
ci_case "writes: the generated profile.env sources and expands \$HOME to this home" case_profile_env_sources

case_home_literal() {
    ci_fixture_profiles
    alpha
    grep -qF 'REPO_PATH="${MAINTAINER_REPO_PATH:-$HOME/code/widgets}"' "$CZ_TREE/profiles/alpha/profile.env" \
        || cz_note_fail "a checkout under HOME is not written as \$HOME/..."
    if grep -qF "$CZ_HOME" "$CZ_TREE/profiles/alpha/profile.env"; then cz_note_fail "the home path leaked into profile.env"; fi
}
ci_case "path: a checkout under HOME is written as \$HOME/... and the home path never appears" case_home_literal

# Pins current behaviour. Only paths below HOME are abbreviated; HOME itself is not.
case_home_itself_verbatim() {
    ci_fixture_profiles
    ci_newprof alpha acme/widgets "$CZ_HOME" alice
    cz_expect_rc 0
    grep -qF "REPO_PATH=\"\${MAINTAINER_REPO_PATH:-$CZ_HOME}\"" "$CZ_TREE/profiles/alpha/profile.env" \
        || cz_note_fail "HOME itself was not written verbatim"
}
ci_case "path: HOME itself, not a path below it, is written verbatim (pins current behaviour)" case_home_itself_verbatim

case_name_defaults_to_account() {
    ci_fixture_profiles
    ci_newprof alpha acme/widgets /srv/widgets carol
    grep -qx 'MAINTAINER_NAME="carol"' "$CZ_TREE/profiles/alpha/profile.env" || cz_note_fail "the name did not default to the account"
}
ci_case "args: with four arguments the maintainer name is the account" case_name_defaults_to_account

case_missing_checkout_warns_not_fails() {
    ci_fixture_profiles
    ci_newprof alpha acme/widgets /nonexistent/path alice
    cz_expect_rc 0
    cz_expect_stdout_has "  warning: /nonexistent/path is not a git checkout yet"
}
ci_case "args: a checkout path that does not exist is a warning, not a refusal" case_missing_checkout_warns_not_fails

case_special_characters_in_name() {
    ci_fixture_profiles
    ci_newprof alpha acme/widgets /srv/w alice "Zoe O'Brien/Dev Team"
    cz_expect_rc 0
    grep -qxF 'MAINTAINER_NAME="Zoe O'"'"'Brien/Dev Team"' "$CZ_TREE/profiles/alpha/profile.env" || cz_note_fail "a name with an apostrophe and a slash was not written literally"
}
ci_case "substitution: an apostrophe, a slash and spaces in the name are written literally" case_special_characters_in_name

# Pins current behaviour, and it matters: the value is written inside double quotes
# in a file that run.sh sources, so a command substitution in the name stays one.
case_name_command_substitution() {
    ci_fixture_profiles
    ci_newprof alpha acme/widgets /srv/w alice '$(echo hi)'
    cz_expect_rc 0
    grep -qxF 'MAINTAINER_NAME="$(echo hi)"' "$CZ_TREE/profiles/alpha/profile.env" || cz_note_fail "the name was escaped or changed"
}
ci_case "substitution: a \$(...) in the name is written into profile.env unescaped (pins current behaviour)" case_name_command_substitution

# Pins current behaviour. \n in an argument reaches sed's replacement and becomes a newline.
case_name_backslash_n() {
    ci_fixture_profiles
    ci_newprof alpha acme/widgets /srv/w alice 'Al\nice'
    cz_expect_rc 0
    grep -qx 'MAINTAINER_NAME="Al' "$CZ_TREE/profiles/alpha/profile.env" || cz_note_fail "backslash-n did not split the line"
    grep -qx 'ice"' "$CZ_TREE/profiles/alpha/profile.env" || cz_note_fail "the second half of the name is not on its own line"
}
ci_case "substitution: a backslash-n in the name becomes a line break in profile.env (pins current behaviour)" case_name_backslash_n

case_slug_substituted_everywhere() {
    ci_fixture_profiles
    alpha
    cz_check "review.md" "$(cat "$CZ_TREE/profiles/alpha/prompts/review.md")" "Review acme/widgets as Alice Example (alice), twice: acme/widgets."
    grep -qF '"alpha publish"' "$CZ_TREE/profiles/alpha/deny.json" || cz_note_fail "deny.json was not substituted"
}
ci_case "substitution: every occurrence in every file, nested ones included, is replaced" case_slug_substituted_everywhere

# --- tasks and timers ---------------------------------------------------------------------

case_three_tasks() {
    ci_fixture_profiles
    sed -i 's/^TASKS=.*/TASKS="review issues audit"/' "$CZ_TREE/profiles/_template/profile.env"
    alpha
    ( cd "$CZ_TREE/platform/linux" && printf '%s\n' *alpha* ) > "$CZ_CASE/alpha.units"
    cz_check "alpha units" "$(cat "$CZ_CASE/alpha.units")" "maintainer@alpha-audit.timer
maintainer@alpha-issues.timer
maintainer@alpha-review.timer"
    grep -q 'OnCalendar=\*-\*-\* 09:17:00' "$CZ_TREE/platform/linux/maintainer@alpha-review.timer" || cz_note_fail "review is not at 09:17"
    grep -q 'OnCalendar=\*-\*-\* 10:17:00' "$CZ_TREE/platform/linux/maintainer@alpha-issues.timer" || cz_note_fail "issues is not at 10:17"
    grep -q 'OnCalendar=\*-\*-\* 11:17:00' "$CZ_TREE/platform/linux/maintainer@alpha-audit.timer" || cz_note_fail "audit is not at 11:17"
    cz_expect_stdout_has "  wrote maintainer@alpha-audit.timer"
}
ci_case "timers: each task gets a timer one hour after the previous, starting at 09:17, in TASKS order" case_three_tasks

case_hours_pad() {
    ci_fixture_profiles
    sed -i 's/^TASKS=.*/TASKS="t1 t2 t3 t4 t5 t6 t7 t8 t9 t10"/' "$CZ_TREE/profiles/_template/profile.env"
    alpha
    grep -q 'OnCalendar=\*-\*-\* 18:17:00' "$CZ_TREE/platform/linux/maintainer@alpha-t10.timer" || cz_note_fail "the tenth task is not at 18:17"
}
ci_case "timers: the tenth task is at 18:17" case_hours_pad

case_hour_after_midnight() {
    ci_fixture_profiles
    sed -i 's/^TASKS=.*/TASKS="a b c d e f g h i j k l m n o p"/' "$CZ_TREE/profiles/_template/profile.env"
    alpha
    cz_expect_rc 0
    grep -q 'OnCalendar=\*-\*-\* 24:17:00' "$CZ_TREE/platform/linux/maintainer@alpha-p.timer" \
        || cz_note_fail "the sixteenth task is not written as 24:17"
}
ci_case "timers: the sixteenth task is written as 24:17, an invalid time (pins current behaviour)" case_hour_after_midnight

case_no_tasks_line() {
    ci_fixture_profiles
    sed -i '/^TASKS=/d' "$CZ_TREE/profiles/_template/profile.env"
    alpha
    cz_expect_rc 0
    cz_expect_lacks stdout "wrote "
    cz_check "alpha units" "$(find "$CZ_TREE/platform/linux" -name '*alpha*' | wc -l | tr -d ' ')" "0"
}
ci_case "timers: a template with no TASKS line writes no timer and still succeeds" case_no_tasks_line

case_timer_overwritten() {
    ci_fixture_profiles
    printf 'old content\n' > "$CZ_TREE/platform/linux/maintainer@alpha-review.timer"
    alpha
    cz_expect_rc 0
    grep -q '^Description=maintainer: alpha review (timer)$' "$CZ_TREE/platform/linux/maintainer@alpha-review.timer" || cz_note_fail "the existing timer was not replaced"
}
ci_case "timers: an existing timer unit of the same name is overwritten without a word (pins current behaviour)" case_timer_overwritten

# --- refusals -------------------------------------------------------------------------------

case_usage() {
    ci_fixture_profiles
    "$@"
    cz_expect_rc 64
    cz_expect_stdout_empty
    cz_expect_stderr "${USAGE_LINES[@]}"
}
case_usage_none()  { case_usage ci_newprof; }
ci_case "refusal: no arguments print the eight header lines on stderr and exit 64" case_usage_none
case_usage_three() { case_usage ci_newprof a b/c /x; }
ci_case "refusal: three arguments print the same header and exit 64" case_usage_three

case_refused() {  # $1 = expected first stderr line, then the arguments
    local want="$1"; shift
    ci_fixture_profiles; tree_before
    ci_newprof "$@"
    cz_expect_rc 64
    cz_expect_stdout_empty
    cz_expect_stderr "$want"
    ci_manifest "$CZ_TREE" > "$CZ_CASE/tree.after"
    ci_expect_same_snap "the tree" "$CZ_CASE/tree.before" "$CZ_CASE/tree.after"
}
case_ref_underscore() { case_refused "new-profile: '_x' is not a usable profile name" _x a/b /srv/x acct; }
ci_case "refusal: a profile name starting with an underscore exits 64 and writes nothing" case_ref_underscore
case_ref_template() { case_refused "new-profile: '_template' is not a usable profile name" _template a/b /srv/x acct; }
ci_case "refusal: the name _template exits 64" case_ref_template
case_ref_slash() { case_refused "new-profile: 'a/b' is not a usable profile name" a/b a/b /srv/x acct; }
ci_case "refusal: a profile name with a slash exits 64" case_ref_slash
case_ref_empty() { case_refused "new-profile: '' is not a usable profile name" "" a/b /srv/x acct; }
ci_case "refusal: an empty profile name exits 64" case_ref_empty
case_ref_slug() { case_refused "new-profile: 'widgets' is not owner/repo" alpha widgets /srv/x acct; }
ci_case "refusal: a slug without a slash exits 64" case_ref_slug

case_bad_char() {  # $1 = the argument position to poison, $2 = the character
    local args=(alpha acme/widgets /srv/x acct "Name") i="$1" c="$2"
    args[$i]="${args[$i]}$c"
    ci_fixture_profiles; tree_before
    ci_newprof "${args[@]}"
    cz_expect_rc 64
    cz_expect_stderr_has "new-profile: '|' and '&' are not allowed in an argument"
    cz_expect_stderr_first "new-profile: '|' and '&' are not allowed in an argument"
    cz_check "stderr lines" "$(wc -l < "$CZ_CASE/stderr" | tr -d ' ')" "1"
    ci_manifest "$CZ_TREE" > "$CZ_CASE/tree.after"
    ci_expect_same_snap "the tree" "$CZ_CASE/tree.before" "$CZ_CASE/tree.after"
}
c1() { case_bad_char 0 '|'; }; ci_case "refusal: a pipe in the profile name exits 64 and writes nothing" c1
c2() { case_bad_char 1 '&'; }; ci_case "refusal: an ampersand in the slug exits 64 and writes nothing" c2
c3() { case_bad_char 2 '|'; }; ci_case "refusal: a pipe in the checkout path exits 64 and writes nothing" c3
c4() { case_bad_char 3 '&'; }; ci_case "refusal: an ampersand in the account exits 64 and writes nothing" c4
c5() { case_bad_char 4 '|'; }; ci_case "refusal: a pipe in the name exits 64 and writes nothing" c5

case_exists() {
    ci_fixture_profiles; tree_before
    ci_newprof magent a/b /srv/x acct
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr "new-profile: profiles/magent already exists"
    ci_manifest "$CZ_TREE" > "$CZ_CASE/tree.after"
    ci_expect_same_snap "the tree" "$CZ_CASE/tree.before" "$CZ_CASE/tree.after"
}
ci_case "refusal: an existing profile exits 1 and changes nothing" case_exists

case_exists_empty_dir() {
    ci_fixture_profiles; mkdir -p "$CZ_TREE/profiles/alpha"
    alpha
    cz_expect_rc 1
    cz_expect_stderr "new-profile: profiles/alpha already exists"
}
ci_case "refusal: an empty directory with the profile's name counts as existing" case_exists_empty_dir

case_second_run() {
    ci_fixture_profiles
    alpha
    cz_expect_rc 0
    alpha
    cz_expect_rc 1
    cz_expect_stderr "new-profile: profiles/alpha already exists"
}
ci_case "refusal: running it twice for the same name refuses the second run" case_second_run

# The name check comes after the warning. The warning is printed on stdout and the
# refusal on stderr, so a refusal can leave one stdout line behind.
case_warning_before_refusal() {
    ci_fixture_profiles
    ci_newprof alpha acme/widgets /nonexistent/x acct 'bad|name'
    cz_expect_rc 64
    cz_expect_stdout "  warning: /nonexistent/x is not a git checkout yet"
    cz_expect_stderr "new-profile: '|' and '&' are not allowed in an argument"
}
ci_case "refusal: the not-a-checkout warning is printed before an argument is refused" case_warning_before_refusal

# Pins current behaviour. A placeholder that survives leaves the half-made profile
# in place and the timers unwritten.
case_surviving_placeholder() {
    ci_fixture_profiles
    printf 'Hello __EXTRA__ and __SLUG__\n' >> "$CZ_TREE/profiles/_template/prompts/review.md"
    alpha
    cz_expect_rc 1
    cz_expect_stdout_has "  warning:"
    cz_expect_stderr_first "new-profile: a placeholder survived substitution:"
    cz_check "stderr line 2" "$(sed -n 2p "$CZ_CASE/stderr")" "$CZ_TREE/profiles/alpha/prompts/review.md:2:Hello __EXTRA__ and acme/widgets"
    cz_check "stderr lines" "$(wc -l < "$CZ_CASE/stderr" | tr -d ' ')" "2"
    cz_expect_file "$CZ_TREE/profiles/alpha/profile.env"
    cz_expect_no_file "$CZ_TREE/platform/linux/maintainer@alpha-review.timer"
    cz_expect_lacks stdout "ready"
}
ci_case "refusal: a placeholder left after substitution exits 1 with grep's lines, keeps the profile, writes no timers (pins current behaviour)" case_surviving_placeholder

# --- the real template -------------------------------------------------------------------------

case_real_template() {
    alpha
    cz_expect_rc 0
    cz_expect_stderr_empty
    if grep -rq '__[A-Z_]*__' "$CZ_TREE/profiles/alpha"; then cz_note_fail "a placeholder is left in the generated profile"; fi
    ( cd "$CZ_TREE/profiles/_template" && find . -type f | LC_ALL=C sort ) > "$CZ_CASE/list.t"
    ( cd "$CZ_TREE/profiles/alpha" && find . -type f | LC_ALL=C sort ) > "$CZ_CASE/list.a"
    ci_expect_same_snap "the file list" "$CZ_CASE/list.t" "$CZ_CASE/list.a"
    local tasks t n=0
    tasks="$(sed -n 's/^TASKS="\(.*\)"/\1/p' "$CZ_TREE/profiles/alpha/profile.env")"
    for t in $tasks; do
        n=$((n + 1)); cz_expect_file "$CZ_TREE/platform/linux/maintainer@alpha-$t.timer"
    done
    [ "$n" -ge 1 ] || cz_note_fail "the real template declares no task"
    cz_expect_stdout_has "  profiles/alpha/ is ready. Three things before the first run:"
}
ci_case "real template: no placeholder survives, the file list is the template's, one timer per declared task" case_real_template

# --- a generated profile installs ---------------------------------------------------------------

case_generated_installs() {
    ci_fixture_profiles
    alpha
    ci_install --timers
    cz_expect_rc 0
    cz_expect_file "$CZ_SHARE/profiles/alpha/profile.env"
    cz_expect_file "$CZ_SHARE/profiles/alpha/settings.json"
    cz_expect_stdout_has "  alpha: "
    cz_expect_stdout_has "  enabled maintainer@alpha-review.timer"
    cz_expect_stdout_has "  enabled maintainer@alpha-issues.timer"
    cz_expect_file "$CZ_HOME/.config/systemd/user/maintainer@alpha-review.timer"
    cz_check "systemctl enable calls" "$(grep -c -- ' enable --now ' "$CZ_CASE/systemctl.calls")" "8"
}
ci_case "install: a generated profile deploys, gets a wall and its two timers enable with the other six" case_generated_installs

cz_finish
