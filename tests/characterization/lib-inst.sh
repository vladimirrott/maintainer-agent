#!/usr/bin/env bash
# Helpers for the characterization tests of install.sh, new-profile.sh, the
# platform scripts (platform/linux, platform/posix, platform/macos) and
# evals/run-evals.sh. Sourced by install-*.sh after lib.sh, never run alone.
#
# Isolation. Every case gets a fresh sandbox:
#   home/   the HOME of the program. The real HOME is never named.
#   tree/   a private copy of the checkout files the programs read and write
#           (install.sh, new-profile.sh, lib, scripts, bin, profiles, platform,
#           evals). new-profile.sh writes into its own tree, so a case never
#           shares one.
#   bin/    stubs first on PATH: systemctl, crontab, launchctl, flock,
#           notify-send, date (fixed answer for -Is) and, on request, uname.
#           podman, docker, curl, wget, ssh, gh, claude and codex fail the case
#           when they run.
#   tools/  symlinks to the few real tools the programs need, and nothing else.
#           The real systemctl, crontab and launchctl are not reachable, so a
#           program that skips PATH and names /usr/bin/systemctl is the only
#           way to touch them, and install-isolation.sh checks that.
# The program runs under `env -i`, from the case's home directory.
#
# Golden files live in golden/install/. The bash programs produced them and a
# person read them. CZ_REGEN_GOLDEN=1 rewrites them and fails every case that
# does, so a regenerating run can never read as a pass.

# shellcheck disable=SC1091,SC2034  # SC2034: the variables are read by lib.sh and the case files
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CI_GOLDEN="$CZ_GOLDEN/install"

# The real tools the programs under test use. A missing one stops the run:
# a case that quietly lacked a tool would be testing the missing-tool path.
CI_TOOL_NAMES="bash cp rm mkdir mv sed grep awk cat chmod touch find sort tr od head tail dirname basename readlink git python3 date uname id env flock timeout ln ls cut wc stat sha256sum mktemp tee diff cmp sleep true false xargs"

ci_init() {
    cz_init
    CI_REAL_DATE="$(type -P date)"; CI_REAL_UNAME="$(type -P uname)"
    CI_TOOLS_ALL="$CZ_ROOT/tools-all"; mkdir -p "$CI_TOOLS_ALL"
    local t p
    for t in $CI_TOOL_NAMES; do
        p="$(type -P "$t")" || { echo "characterization: tool '$t' not found on this machine" >&2; exit 2; }
        ln -s "$p" "$CI_TOOLS_ALL/$t"
    done

    # The files of the tree under test that these programs read or write.
    CI_PRISTINE="$CZ_ROOT/pristine"; mkdir -p "$CI_PRISTINE"
    local f
    for f in install.sh new-profile.sh lib scripts bin profiles platform evals; do
        [ -e "$MX_TREE/$f" ] || { echo "characterization: MX_TREE=$MX_TREE has no $f" >&2; exit 2; }
        cp -a "$MX_TREE/$f" "$CI_PRISTINE/$f"
    done

    mkdir -p "$CI_PRISTINE/tests"
    [ -f "$MX_TREE/tests/containment-probe.sh" ] || { echo "characterization: MX_TREE has no tests/containment-probe.sh" >&2; exit 2; }
    cp -a "$MX_TREE/tests/containment-probe.sh" "$CI_PRISTINE/tests/containment-probe.sh"

    # Stub sources, written once and copied into each case.
    CI_STUBS="$CZ_ROOT/stubs"; mkdir -p "$CI_STUBS"
    cat > "$CI_STUBS/systemctl" <<'STUB'
#!/usr/bin/env bash
# Logs argv. show-environment answers 1 when systemctl.noenv exists (no user
# session); list-timers prints systemctl.timers; any verb fails when
# systemctl.fail.<verb> exists. For enable it records whether the stamp file
# for the unit existed at that moment.
d="${CZ_CASE_DIR:?}"
line=""; for a in "$@"; do line="$line$(printf '%q' "$a") "; done
printf '%s\n' "${line% }" >> "$d/systemctl.calls"
verb="${2:-}"
if [ "$verb" = enable ]; then
    n="${*: -1}"
    if [ -e "$HOME/.local/share/systemd/timers/stamp-$n" ]; then s=yes; else s=no; fi
    printf '%s stamp=%s\n' "$n" "$s" >> "$d/systemctl.stamps"
fi
case "$verb" in
    show-environment) [ -e "$d/systemctl.noenv" ] && exit 1; exit 0 ;;
    list-timers) [ -e "$d/systemctl.timers" ] && cat "$d/systemctl.timers"; exit 0 ;;
esac
if [ -e "$d/systemctl.fail.$verb" ]; then echo "stub systemctl: $verb failed" >&2; exit 1; fi
exit 0
STUB
    cat > "$CI_STUBS/crontab" <<'STUB'
#!/usr/bin/env bash
# A crontab held in crontab.store. -l prints it, or fails like the real one when
# there is none. - replaces it from stdin, unless crontab.w.rc names a failure.
d="${CZ_CASE_DIR:?}"
line=""; for a in "$@"; do line="$line$(printf '%q' "$a") "; done
printf '%s\n' "${line% }" >> "$d/crontab.calls"
case "${1:-}" in
    -l) if [ -e "$d/crontab.store" ]; then cat "$d/crontab.store"; exit 0; fi
        echo "no crontab for fixture-user" >&2; exit 1 ;;
    -)  if [ -e "$d/crontab.w.rc" ]; then echo "stub crontab: cannot write" >&2; exit "$(cat "$d/crontab.w.rc")"; fi
        cat > "$d/crontab.store" ;;
    *)  echo "stub crontab: unexpected argv: $*" >&2; exit 2 ;;
esac
STUB
    cat > "$CI_STUBS/launchctl" <<'STUB'
#!/usr/bin/env bash
# Logs argv. A verb fails when launchctl.fail.<verb> exists.
d="${CZ_CASE_DIR:?}"
line=""; for a in "$@"; do line="$line$(printf '%q' "$a") "; done
printf '%s\n' "${line% }" >> "$d/launchctl.calls"
if [ -e "$d/launchctl.fail.${1:-}" ]; then echo "stub launchctl: ${1:-} failed" >&2; exit 1; fi
exit 0
STUB
    cat > "$CI_STUBS/flock" <<'STUB'
#!/usr/bin/env bash
# Logs argv, exits with the code in flock.rc (default 0): "the lock is held"
# without a second process.
d="${CZ_CASE_DIR:?}"
printf '%s\n' "$*" >> "$d/flock.calls"
rc=0; [ -e "$d/flock.rc" ] && rc="$(cat "$d/flock.rc")"
exit "$rc"
STUB
    cat > "$CI_STUBS/notify-send" <<'STUB'
#!/usr/bin/env bash
# Logs argv with %q quoting plus the two variables alert.sh sets for it.
d="${CZ_CASE_DIR:?}"
line=""; for a in "$@"; do line="$line$(printf '%q' "$a") "; done
printf 'argv: %s\nDISPLAY=%s\nDBUS=%s\n' "${line% }" "${DISPLAY-<unset>}" "${DBUS_SESSION_BUS_ADDRESS-<unset>}" >> "$d/notify.calls"
[ -e "$d/notify.rc" ] && exit "$(cat "$d/notify.rc")"
exit 0
STUB
    cat > "$CI_STUBS/date" <<'STUB'
#!/usr/bin/env bash
# `date -Is` answers a fixed instant; every other call goes to the real date.
if [ "$*" = "-Is" ]; then echo "2026-01-01T00:00:00+00:00"; exit 0; fi
exec "${CZ_REAL_DATE:?}" "$@"
STUB
    cat > "$CI_STUBS/uname" <<'STUB'
#!/usr/bin/env bash
# `uname -s` answers the text in uname.out when that file exists.
if [ "$*" = "-s" ] && [ -e "${CZ_CASE_DIR:?}/uname.out" ]; then cat "$CZ_CASE_DIR/uname.out"; exit 0; fi
exec "${CZ_REAL_UNAME:?}" "$@"
STUB
    for t in systemctl crontab launchctl flock notify-send date uname; do
        bash -n "$CI_STUBS/$t" || { echo "characterization: stub $t does not parse" >&2; exit 2; }
        chmod +x "$CI_STUBS/$t"
    done
}

# --- the sandbox ---------------------------------------------------------------

ci_sandbox_new() {
    CZ_SEQ=$((CZ_SEQ + 1))
    CZ_CASE="$CZ_ROOT/case-$CZ_SEQ"
    CZ_HOME="$CZ_CASE/home"; CZ_TREE="$CZ_CASE/tree"; CZ_TOOLS="$CZ_CASE/tools"
    # shellcheck disable=SC2034  # read by the cases that sourced this file
    CZ_SHARE="$CZ_HOME/.local/share/maintainer"
    mkdir -p "$CZ_CASE/bin" "$CZ_HOME"
    cp -a "$CI_PRISTINE" "$CZ_TREE"
    cp -a "$CI_TOOLS_ALL" "$CZ_TOOLS"
    local t
    for t in systemctl crontab launchctl flock notify-send date; do cp "$CI_STUBS/$t" "$CZ_CASE/bin/$t"; done
    for t in podman docker curl wget ssh gh claude codex; do cz_stub_tool "$t"; done
    CZ_E=()
    CZ_E[PATH]="$CZ_CASE/bin:$CZ_TOOLS"
    CZ_E[HOME]="$CZ_HOME"
    CZ_E[LC_ALL]=C
    CZ_E[TZ]=UTC
    CZ_E[LOGNAME]=fixture-user
    CZ_E[USER]=fixture-user
    CZ_E[GIT_CONFIG_NOSYSTEM]=1
    CZ_E[GIT_CONFIG_GLOBAL]=/dev/null
    CZ_E[GIT_TERMINAL_PROMPT]=0
    CZ_E[CZ_CASE_DIR]="$CZ_CASE"
    CZ_E[CZ_REAL_DATE]="$CI_REAL_DATE"
    CZ_E[CZ_REAL_UNAME]="$CI_REAL_UNAME"
}

# ci_case NAME FUNCTION: runs FUNCTION in a fresh sandbox. The case fails when an
# assertion fails or when a tool nobody planned ran.
ci_case() {
    # shellcheck disable=SC2034  # read by cz_case_end in lib.sh
    CZ_NAME="$1"; CZ_CASE_FAILS=0
    ci_sandbox_new
    "$2"
    cz_case_end
}

ci_drop_tool() {  # $1 = a tool the program must not find on PATH
    rm -f "$CZ_TOOLS/$1" "$CZ_CASE/bin/$1"
}
ci_uname() { printf '%s\n' "$1" > "$CZ_CASE/uname.out"; cp "$CI_STUBS/uname" "$CZ_CASE/bin/uname"; }

# ci_run PROGRAM ARGS...: runs `bash PROGRAM ARGS` under env -i from the case's
# home. Sets CZ_RC and leaves $CZ_CASE/stdout and $CZ_CASE/stderr apart.
ci_run() {
    local prog="$1"; shift
    local pairs=() k
    for k in "${!CZ_E[@]}"; do pairs+=("$k=${CZ_E[$k]}"); done
    ( umask 022; cd "$CZ_HOME" && env -i "${pairs[@]}" timeout 120 bash "$prog" "$@" \
        > "$CZ_CASE/stdout" 2> "$CZ_CASE/stderr" < /dev/null )
    CZ_RC=$?
}
ci_install()   { ci_run "$CZ_TREE/install.sh" "$@"; }
ci_newprof()   { ci_run "$CZ_TREE/new-profile.sh" "$@"; }
ci_cron()      { ci_run "$CZ_TREE/platform/posix/install-cron.sh" "$@"; }
ci_launchd()   { ci_run "$CZ_TREE/platform/macos/install-launchd.sh" "$@"; }
ci_alert()     { ci_run "$CZ_TREE/platform/linux/alert.sh" "$@"; }
ci_evals()     { ci_run "$CZ_TREE/evals/run-evals.sh" "$@"; }

# ci_deploy [ARGS]: a real install into the case's home, then the call logs are
# emptied so the case sees only what its own program does.
ci_deploy() {
    ci_install "$@"
    if [ "$CZ_RC" != 0 ]; then cz_note_fail "setup: install.sh $* exited $CZ_RC: $(tr '\n' ' ' < "$CZ_CASE/stderr" | cut -c1-200)"; fi
    ci_reset_logs
}
ci_reset_logs() { rm -f "$CZ_CASE"/*.calls "$CZ_CASE"/systemctl.stamps; }

# ci_tree_git TAG: makes the case's tree a git checkout with one commit and, when
# TAG is not empty, that tag on it.
ci_tree_git() {
    local gitcmd=(env -i PATH="$CZ_TOOLS" HOME="$CZ_HOME" LC_ALL=C GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
        GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
        GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
        GIT_AUTHOR_DATE="1767225600 +0000" GIT_COMMITTER_DATE="1767225600 +0000"
        git -C "$CZ_TREE")
    "${gitcmd[@]}" init -q -b main || { echo "characterization: git setup failed" >&2; exit 2; }
    "${gitcmd[@]}" add -A || { echo "characterization: git setup failed" >&2; exit 2; }
    "${gitcmd[@]}" commit -q -m base || { echo "characterization: git setup failed" >&2; exit 2; }
    if [ -n "${1:-}" ]; then "${gitcmd[@]}" tag "$1" || exit 2; fi
    # shellcheck disable=SC2034  # read by the cases that sourced this file
    CI_GIT=("${gitcmd[@]}")
}

# --- snapshots ---------------------------------------------------------------

# ci_snap DIR: every path under DIR with type, mode, size and modification time
# (nanoseconds), sorted. Two equal snapshots mean nothing under DIR was created,
# removed, rewritten or touched.
ci_snap() { ( cd "$1" && find . -printf '%p %y %m %s %T@\n' | LC_ALL=C sort ); }

# ci_manifest DIR: every regular file as "sha256 owner-bits path", sorted. The
# owner bits (-rwx or -rw-) only: the group and other bits follow the umask of
# whoever made the checkout.
ci_manifest() {
    ( cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
        printf '%s %s %s\n' "$(sha256sum < "$f" | cut -c1-64)" "$(stat -c %A "$f" | cut -c1-4)" "$f"
    done )
}

# --- golden files --------------------------------------------------------------

# ci_norm FILE: prints FILE with the case's tree, home and case paths replaced by
# @TREE@, @HOME@ and @CASE@, trailing newlines intact.
ci_norm() {
    local text; text="$(cat "$1"; printf x)"; text="${text%x}"
    text="${text//"$CZ_TREE"/@TREE@}"; text="${text//"$CZ_HOME"/@HOME@}"; text="${text//"$CZ_CASE"/@CASE@}"
    printf '%s' "$text"
}

ci_expect_golden_file() {  # $1 = golden name, $2 = a file holding the actual text
    local g="$CI_GOLDEN/$1"
    if [ "${CZ_REGEN_GOLDEN:-}" = 1 ]; then
        mkdir -p "$(dirname "$g")"; cp "$2" "$g"
        cz_note_fail "regenerated golden $1: unset CZ_REGEN_GOLDEN and review the file"
        return
    fi
    if [ ! -f "$g" ]; then cz_note_fail "missing golden file $1"; return; fi
    cmp -s "$g" "$2" || cz_note_fail "golden $1 differs: $(diff "$g" "$2" | head -8 | tr '\n' '|' | cut -c1-300)"
}

# ci_golden_stream stdout|stderr NAME: the stream, paths normalised, against golden NAME.
ci_golden_stream() {
    ci_norm "$CZ_CASE/$1" > "$CZ_CASE/norm.$1"
    ci_expect_golden_file "$2" "$CZ_CASE/norm.$1"
}

# ci_golden_path NAME FILE: FILE, paths normalised, against golden NAME.
ci_golden_path() {  # $1 = golden name, $2 = file to normalise then compare
    ci_norm "$2" > "$CZ_CASE/norm.path"
    ci_expect_golden_file "$1" "$CZ_CASE/norm.path"
}

# ci_dump DIR FILES...: the named files under DIR (all regular files when none are
# named), each as a "=== path ===" header and its bytes. Used for goldens of
# generated directories, which a person can read.
ci_dump() {
    local dir="$1"; shift
    local f files=("$@")
    if [ "${#files[@]}" -eq 0 ]; then
        mapfile -t files < <(cd "$dir" && find . -type f | LC_ALL=C sort)
    fi
    for f in "${files[@]}"; do
        printf '=== %s ===\n' "$f"; cat "$dir/$f"
    done
}

# --- assertions the lib does not have ----------------------------------------------

# ci_expect_calls FILE LINES...: the whole call log of a stub, line for line.
# With no lines the log must be absent or empty.
ci_expect_calls() {
    local f="$CZ_CASE/$1"; shift
    local want="$CZ_CASE/want.calls"
    if [ "$#" -eq 0 ]; then : > "$want"; else printf '%s\n' "$@" > "$want"; fi
    if [ ! -e "$f" ]; then : > "$CZ_CASE/empty.calls"; f="$CZ_CASE/empty.calls"; fi
    cmp -s "$want" "$f" || cz_note_fail "$(basename "$f") differs. expected: $(tr '\n' '|' < "$want" | cut -c1-300) got: $(tr '\n' '|' < "$f" | cut -c1-300)"
}

# ci_expect_bytes FILE TEXT: FILE holds exactly TEXT, every byte, newlines included.
ci_expect_bytes() {
    printf '%s' "$2" > "$CZ_CASE/want.bytes"
    cmp -s "$CZ_CASE/want.bytes" "$1" || cz_note_fail "$(basename "$1") differs. expected: $(od -c < "$CZ_CASE/want.bytes" | head -3 | tr -s ' ' | tr '\n' '|' | cut -c1-200) got: $(od -c < "$1" | head -3 | tr -s ' ' | tr '\n' '|' | cut -c1-200)"
}

ci_expect_same_snap() {  # $1 = label, $2 = snapshot before, $3 = snapshot after (files)
    cmp -s "$2" "$3" || cz_note_fail "$1 changed: $(diff "$2" "$3" | head -6 | tr '\n' '|' | cut -c1-300)"
}

ci_mode() { stat -c %a "$1" 2>/dev/null || echo missing; }

# --- fixture profiles ------------------------------------------------------------

# ci_fixture_profiles: replaces the tree's profiles/ with three small synthetic
# ones, so goldens do not move when a real profile's prompts or deny list change.
#   sysknife  4 tasks, STATE_DIR under $HOME/.local/state/sysknife-maint
#   magent    2 tasks, STATE_DIR under $HOME/.local/state/magent-maint
#   _template placeholders in profile.env, deny.json and prompts/review.md;
#             notes.txt has none.
ci_fixture_profiles() {
    local p="$CZ_TREE/profiles"
    rm -rf "$p"; mkdir -p "$p/sysknife/prompts" "$p/magent" "$p/_template/prompts"
    printf '%s\n' '{"spelled_everywhere": ["cargo publish", "maintainer-merge receipt"], "credential_paths": ["~/.ssh/**"]}' > "$p/sysknife/deny.json"
    cp "$p/sysknife/deny.json" "$p/magent/deny.json"
    cat > "$p/sysknife/profile.env" <<'ENV'
PROFILE_NAME="sysknife"
REPO_PATH="${MAINTAINER_REPO_PATH:-$HOME/.local/state/sysknife-maint/checkout}"
STATE_DIR="${MAINTAINER_STATE_DIR:-$HOME/.local/state/sysknife-maint}"
TASKS="review issues ci audit"
MIN_HOURS_review=6
MIN_HOURS_issues=36
MIN_HOURS_ci=60
MIN_HOURS_audit=108
ENV
    cat > "$p/magent/profile.env" <<'ENV'
PROFILE_NAME="magent"
REPO_PATH="${MAINTAINER_REPO_PATH:-$HOME/.local/state/magent-maint/checkout}"
STATE_DIR="${MAINTAINER_STATE_DIR:-$HOME/.local/state/magent-maint}"
TASKS="review issues"
MIN_HOURS_review=6
MIN_HOURS_issues=36
ENV
    printf 'sysknife prompt\n' > "$p/sysknife/prompts/review.md"
    cat > "$p/_template/profile.env" <<'ENV'
PROFILE_NAME="__PROFILE__"
REPO_PATH="${MAINTAINER_REPO_PATH:-__REPO_PATH__}"
REPO_SLUG="__SLUG__"
MAINTAINER_NAME="__MAINTAINER_NAME__"
GH_ACCOUNT="__GH_ACCOUNT__"
STATE_DIR="${MAINTAINER_STATE_DIR:-$HOME/.local/state/__PROFILE__-maint}"
TASKS="review issues"
MIN_HOURS_review=6
MIN_HOURS_issues=36
ENV
    cat > "$p/_template/deny.json" <<'JSON'
{"spelled_everywhere": ["gh pr merge", "__PROFILE__ publish"], "credential_paths": ["~/.ssh/**"]}
JSON
    printf 'Review __SLUG__ as __MAINTAINER_NAME__ (__GH_ACCOUNT__), twice: __SLUG__.\n' > "$p/_template/prompts/review.md"
    printf 'nothing to substitute here\n' > "$p/_template/notes.txt"
}
