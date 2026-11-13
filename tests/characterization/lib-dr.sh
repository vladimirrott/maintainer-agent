#!/usr/bin/env bash
# Shared helpers for the characterization tests of bin/maintainer-doctor and
# bin/maintainer-repo. Sourced by doctor-*.sh and repo-*.sh, never run alone.
#
# It builds on lib.sh (assertions, fixture repository, per-case sandbox) and does
# not edit it. The difference from the merge-gate cases is the PATH. The doctor
# reads host facts (podman images, systemd units, which agent CLI is installed,
# the operating system), so a case's PATH holds only two directories: the case's
# own stub directory and a farm of symlinks to the plain tools the programs need
# (bash, git, python3, sed, grep, and so on). Nothing else on the host is
# reachable. A tool that is not in either directory does not exist for the
# program, and any attempt to run one is logged as unplanned and fails the case
# (BASH_ENV installs a command_not_found_handle for that).
#
# The stubs log every call with argv in %q form. gh, podman, systemctl and
# systemd-run answer from files under the case directory; a call with no answer
# file exits 99 and fails the case, so no stub returns a value nobody planned.

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DR_DOCTOR="$MX_TREE/bin/maintainer-doctor"
DR_REPO="$MX_TREE/bin/maintainer-repo"

# Plain tools the two programs use, resolved once from the host. `type -P`
# ignores shell functions and aliases.
DR_TOOL_NAMES="bash sh env python3 git sed grep awk sort uniq cut tr head tail wc cat ls find dirname basename readlink stat date mktemp rm mkdir rmdir touch cp mv chmod sha256sum paste sleep timeout true false tee tar xargs ln"

dr_init() {
    local p
    for p in "$DR_DOCTOR" "$DR_REPO"; do
        if [ ! -f "$p" ]; then
            printf 'characterization: no %s under MX_TREE=%s\n' "${p##*/}" "$MX_TREE" >&2
            exit 2
        fi
    done
    cz_init
    DR_TOOLS="$CZ_ROOT/tools"; mkdir -p "$DR_TOOLS"
    local t path
    for t in $DR_TOOL_NAMES; do
        path="$(PATH=/usr/local/bin:/usr/bin:/bin type -P "$t")" || { printf 'characterization: host has no %s\n' "$t" >&2; exit 2; }
        ln -s "$path" "$DR_TOOLS/$t"
    done
    DR_REAL_GREP="$DR_TOOLS/grep"
    # shellcheck disable=SC2034  # read by the case files that source this one
    DR_REAL_GIT="$DR_TOOLS/git"
    # shellcheck disable=SC2034
    DR_ME="$(id -u)"
}

# --- the case sandbox ---------------------------------------------------------

# dr_case NAME FUNCTION: a fresh sandbox, then FUNCTION, then the usual verdict.
dr_case() {
    # shellcheck disable=SC2034  # both are read by cz_case_end in lib.sh
    CZ_NAME="$1"
    # shellcheck disable=SC2034
    CZ_CASE_FAILS=0
    cz_sandbox_new
    dr_reset
    "$2"
    cz_case_end
}

dr_stub_file() {  # $1 = name, body on stdin
    cat > "$CZ_CASE/bin/$1"
    bash -n "$CZ_CASE/bin/$1" || { echo "characterization: stub $1 does not parse" >&2; exit 2; }
    chmod +x "$CZ_CASE/bin/$1"
}

dr_reset() {
    # Throw away what lib.sh set up: its PATH reaches the host.
    rm -rf "${CZ_CASE:?}/bin" "${CZ_CASE:?}/gh"
    mkdir -p "$CZ_CASE/bin" "$CZ_CASE/gh" "$CZ_CASE/calls" "$CZ_CASE/ans" "$CZ_CASE/tmp" "$CZ_CASE/cwd"
    : > "$CZ_CASE/gh/calls"
    DR_HOME="$CZ_CASE/home"; DR_SHARE="$DR_HOME/.local/share/maintainer"
    DR_PROFILE=magent
    unset DR_P; declare -gA DR_P=()

    cat > "$CZ_CASE/benv.sh" <<'EOF'
command_not_found_handle() {
    local line
    if [ -r "${CZ_CASE_DIR:?}/ans/notfound-ok" ]; then
        while IFS= read -r line; do
            if [ "$line" = "$1" ]; then printf '%s\n' "$*" >> "$CZ_CASE_DIR/calls/notfound"; return 127; fi
        done < "$CZ_CASE_DIR/ans/notfound-ok"
    fi
    printf '%s\n' "$*" >> "$CZ_CASE_DIR/unplanned-tools"
    echo "not planned: $1: command not found" >&2
    return 127
}
EOF

    # gh: answers by key from $CZ_CASE/gh/<key>.out and .rc (see cz_gh in lib.sh).
    dr_stub_file gh <<'STUB'
#!/usr/bin/env bash
d="${CZ_CASE_DIR:?}/gh"
line=""
for a in "$@"; do line="$line$(printf '%q' "$a") "; done
printf '%s\n' "${line% }" >> "$d/calls"
case "${1:-} ${2:-}" in
    "auth switch") key="auth-switch" ;;
    "auth token")  key="auth-token" ;;
    "api user")    key="api-user" ;;
    "api users/"*) key="api-author" ;;
    "run list")    key="run-list" ;;
    "pr list")     key="pr-list" ;;
    "pr view")     key="pr-view.${3:-}" ;;
    "pr comment")  key="pr-comment"
        prev=""
        for a in "$@"; do
            [ "$prev" = "--body-file" ] && cat "$a" > "$d/comment-body"
            prev="$a"
        done ;;
    *)             key="" ;;
esac
if [ -z "$key" ] || { [ ! -e "$d/$key.out" ] && [ ! -e "$d/$key.rc" ] && [ ! -e "$d/$key.fromgit" ]; }; then
    printf '%s\n' "${line% }" >> "$d/unplanned"
    echo "stub gh: unplanned call: $*" >&2
    exit 99
fi
# A key can run a script first (<key>.run): a case uses it to change the world
# between two of the program's steps, as a second writer would.
[ -e "$d/$key.run" ] && bash "$d/$key.run" >&2
# A key can also answer from a git ref: the file <key>.fromgit holds "REPO REF".
if [ -e "$d/$key.fromgit" ]; then
    read -r repo ref < "$d/$key.fromgit"
    git -C "$repo" rev-parse "$ref"
    exit $?
fi
[ -e "$d/$key.out" ] && cat "$d/$key.out"
rc=0; [ -e "$d/$key.rc" ] && rc="$(cat "$d/$key.rc")"
exit "$rc"
STUB

    # systemctl: three calls, each answered from a file.
    dr_stub_file systemctl <<'STUB'
#!/usr/bin/env bash
a="${CZ_CASE_DIR:?}/ans"
line=""; for x in "$@"; do line="$line$(printf '%q' "$x") "; done
printf '%s\n' "${line% }" >> "${CZ_CASE_DIR}/calls/systemctl"
case "${1:-} ${2:-}" in
    "--user show-environment") key="sc-env" ;;
    "--user list-timers")      key="sc-timers" ;;
    "--user list-unit-files")  key="sc-units" ;;
    *) key="" ;;
esac
if [ -z "$key" ] || [ ! -e "$a/$key.rc" ]; then
    printf 'systemctl %s\n' "$*" >> "${CZ_CASE_DIR}/unplanned-tools"
    exit 99
fi
[ -e "$a/$key.out" ] && cat "$a/$key.out"
exit "$(cat "$a/$key.rc")"
STUB

    dr_stub_file loginctl <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CZ_CASE_DIR:?}/calls/loginctl"
if [ ! -e "$CZ_CASE_DIR/ans/loginctl.out" ]; then
    printf 'loginctl %s\n' "$*" >> "$CZ_CASE_DIR/unplanned-tools"; exit 99
fi
cat "$CZ_CASE_DIR/ans/loginctl.out"
STUB

    dr_stub_file uname <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" != "-s" ]; then
    printf 'uname %s\n' "$*" >> "${CZ_CASE_DIR:?}/unplanned-tools"; exit 99
fi
if [ -e "${CZ_CASE_DIR:?}/ans/uname" ]; then cat "$CZ_CASE_DIR/ans/uname"; else echo Linux; fi
STUB

    dr_stub_file id <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" != "-un" ]; then
    printf 'id %s\n' "$*" >> "${CZ_CASE_DIR:?}/unplanned-tools"; exit 99
fi
echo idfallback
STUB

    dr_stub_file claude <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CZ_CASE_DIR:?}/calls/claude"
if [ "${1:-}" = "--version" ]; then printf '2.0.0 (Claude Code)\nsecond line\n'; exit 0; fi
printf 'claude %s\n' "$*" >> "$CZ_CASE_DIR/unplanned-tools"; exit 99
STUB

    # podman: the doctor's four probes. Each answers from ans/podman-*.
    dr_stub_file podman <<'STUB'
#!/usr/bin/env bash
a="${CZ_CASE_DIR:?}/ans"
line=""; for x in "$@"; do line="$line$(printf '%q' "$x") "; done
printf '%s\n' "${line% }" >> "${CZ_CASE_DIR}/calls/podman"
case "${1:-} ${2:-}" in
    "system migrate") exit 0 ;;
    "image exists")   key="podman-exists" ;;
    "image inspect")  key="podman-inspect" ;;
    "run --rm")
        case " $* " in
            *" docker.io/library/busybox:latest true "*) key="podman-cold" ;;
            *) key="podman-probe" ;;
        esac ;;
    *) key="" ;;
esac
if [ -z "$key" ] || [ ! -e "$a/$key.rc" ]; then
    printf 'podman %s\n' "$*" >> "${CZ_CASE_DIR}/unplanned-tools"
    exit 99
fi
[ -e "$a/$key.out" ] && cat "$a/$key.out"
exit "$(cat "$a/$key.rc")"
STUB

    # systemd-run: the bare probe `--user --wait --pipe --quiet true` answers
    # from systemd-run-bare, the hardened extraction from systemd-run-probe.
    dr_stub_file systemd-run <<'STUB'
#!/usr/bin/env bash
a="${CZ_CASE_DIR:?}/ans"
line=""; for x in "$@"; do line="$line$(printf '%q' "$x") "; done
printf '%s\n' "${line% }" >> "${CZ_CASE_DIR}/calls/systemd-run"
if [ "$#" -eq 5 ] && [ "${5:-}" = true ]; then key="systemd-run-bare"; else key="systemd-run-probe"; fi
if [ ! -e "$a/$key.rc" ]; then
    printf 'systemd-run %s\n' "$*" >> "${CZ_CASE_DIR}/unplanned-tools"; exit 99
fi
[ -e "$a/$key.out" ] && cat "$a/$key.out"
exit "$(cat "$a/$key.rc")"
STUB

    # grep: logs its argv, then runs the real one. The doctor's token scan puts
    # the token in grep's argv (plan decision F4) and this is how a case sees it.
    dr_stub_file grep <<STUB
#!/usr/bin/env bash
line=""; for x in "\$@"; do line="\$line\$(printf '%q' "\$x") "; done
printf '%s\n' "\${line% }" >> "\${CZ_CASE_DIR:?}/calls/grep"
exec "$DR_REAL_GREP" "\$@"
STUB

    : > "$CZ_CASE/calls/systemctl"; : > "$CZ_CASE/calls/loginctl"; : > "$CZ_CASE/calls/claude"
    : > "$CZ_CASE/calls/podman"; : > "$CZ_CASE/calls/systemd-run"; : > "$CZ_CASE/calls/grep"

    CZ_E=()
    CZ_E[PATH]="$CZ_CASE/bin:$DR_TOOLS"
    CZ_E[HOME]="$DR_HOME"
    CZ_E[LC_ALL]=C
    CZ_E[TZ]=UTC
    CZ_E[LOGNAME]=fixture-user
    CZ_E[USER]=fixture-user
    CZ_E[TMPDIR]="$CZ_CASE/tmp"
    CZ_E[GIT_CONFIG_NOSYSTEM]=1
    CZ_E[GIT_CONFIG_GLOBAL]=/dev/null
    CZ_E[GIT_TERMINAL_PROMPT]=0
    CZ_E[CZ_CASE_DIR]="$CZ_CASE"
    CZ_E[BASH_ENV]="$CZ_CASE/benv.sh"
    mkdir -p "$DR_HOME"
}

# dr_present NAME...: tools that exist on PATH and must not run (command -v finds them).
dr_present() { local t; for t in "$@"; do cz_stub_tool "$t"; done; }
# dr_absent NAME...: removes a default stub, so the tool is not on PATH.
dr_absent() { local t; for t in "$@"; do rm -f "$CZ_CASE/bin/$t"; done; }

dr_ans() {  # $1 = key, $2 = text printed ("" for nothing), $3 = exit code (default 0)
    if [ -n "$2" ]; then printf '%s\n' "$2" > "$CZ_CASE/ans/$1.out"; else : > "$CZ_CASE/ans/$1.out"; fi
    printf '%s' "${3:-0}" > "$CZ_CASE/ans/$1.rc"
}
dr_ans_rc() { printf '%s' "$2" > "$CZ_CASE/ans/$1.rc"; }   # exit code only, no output file

dr_calls() { cat "$CZ_CASE/calls/$1"; }   # one stub's call log
dr_expect_calls() {  # $1 = stub, then the expected call lines (none: no calls)
    local who="$1"; shift
    local want="$CZ_CASE/want.calls.$who"
    if [ "$#" -eq 0 ]; then : > "$want"; else printf '%s\n' "$@" > "$want"; fi
    cmp -s "$want" "$CZ_CASE/calls/$who" \
        || cz_note_fail "$who calls differ. expected: $(tr '\n' '|' < "$want" | cut -c1-300) got: $(tr '\n' '|' < "$CZ_CASE/calls/$who" | cut -c1-300)"
}
dr_expect_call_line() {  # $1 = stub, $2 = one whole call line
    grep -qxF -- "$2" "$CZ_CASE/calls/$1" \
        || cz_note_fail "$1 was never called as: $2 (calls: $(tr '\n' '|' < "$CZ_CASE/calls/$1" | cut -c1-300))"
}

# --- running a program --------------------------------------------------------

# dr_run PROGRAM ARGS...: runs a bash program in the case's environment from an
# empty working directory. Sets CZ_RC; the streams go to $CZ_CASE/{stdout,stderr}.
dr_run() {
    local prog="$1"; shift
    local pairs=() k
    for k in "${!CZ_E[@]}"; do pairs+=("$k=${CZ_E[$k]}"); done
    ( cd "$CZ_CASE/cwd" && env -i "${pairs[@]}" timeout 120 bash "$prog" "$@" \
        > "$CZ_CASE/stdout" 2> "$CZ_CASE/stderr" < /dev/null )
    # shellcheck disable=SC2034  # read by the cz_expect_* helpers in lib.sh
    CZ_RC=$?
}
dr_doctor() { dr_run "$DR_DOCTOR" "$@"; }

# --- a git repository with a real remote -------------------------------------

# dr_git_remote: CZ_REPO is a working repository whose origin is a bare
# repository in the case directory. Main holds one commit (CZ_C0).
dr_git_remote() {
    DR_ORIGIN="$CZ_CASE/origin.git"
    mkdir -p "$DR_ORIGIN"
    env -i PATH="$CZ_BASE_PATH" HOME="$CZ_CASE/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        git -C "$DR_ORIGIN" init -q --bare -b main || { echo "characterization: git init --bare failed" >&2; exit 2; }
    cz_repo_init
    cz_git remote set-url origin "$DR_ORIGIN"
    cz_write README.md "hello"
    cz_commit base CZ_C0
    cz_git push -q origin main || { echo "characterization: first push failed" >&2; exit 2; }
}

# dr_commit_push MESSAGE VARIABLE: a commit on the current branch, pushed to origin.
dr_commit_push() {
    cz_write "f$CZ_TICK.txt" "$1"
    cz_commit "$1" "$2"
    cz_git push -q origin HEAD || { echo "characterization: push failed" >&2; exit 2; }
}

# dr_branch NAME merged|open: a branch with one commit, pushed to origin. A
# merged one is fast-forwarded into main and main is pushed; an open one is not.
# The checkout ends on main either way, and the local branch is kept.
dr_branch() {
    # shellcheck disable=SC2034  # named by cz_commit
    local sha
    cz_git checkout -q -b "$1" || exit 2
    cz_write "b-${1//\//-}.txt" "$1"
    cz_commit "work on $1" sha
    cz_git push -q origin "$1" || exit 2
    cz_git checkout -q main || exit 2
    if [ "$2" = merged ]; then
        cz_git merge -q --ff-only "$1" || exit 2
        cz_git push -q origin main || exit 2
    fi
}

dr_ls_remote() { cz_git ls-remote --heads origin | sed 's/^[0-9a-f]*\trefs\/heads\///' | sort | paste -sd' ' -; }
dr_local_branches() { cz_git for-each-ref --format='%(refname:short)' refs/heads | sort | paste -sd' ' -; }

# --- the doctor's installation -------------------------------------------------

DR_ESC=$'\033'
dr_exp_head()  { printf '%s\n' "" "${DR_ESC}[1m$1${DR_ESC}[0m"; }
dr_exp_ok()    { printf '%s\n' "  ${DR_ESC}[32mok${DR_ESC}[0m    $1"; }
dr_exp_warn()  { printf '%s\n' "  ${DR_ESC}[33mwarn${DR_ESC}[0m  $1"; [ -n "${2:-}" ] && printf '%s\n' "        fix: $2"; return 0; }
dr_exp_fail()  { printf '%s\n' "  ${DR_ESC}[31mFAIL${DR_ESC}[0m  $1"; [ -n "${2:-}" ] && printf '%s\n' "        fix: $2"; return 0; }
dr_exp_sum()   { printf '%s\n' "" "  ${DR_ESC}[1m$1 ok, $2 warning(s), $3 failure(s)${DR_ESC}[0m"; }

# The exact stdout lines of one finding, as the program prints them.
dr_line_ok()   { printf '  %s[32mok%s[0m    %s' "$DR_ESC" "$DR_ESC" "$1"; }
dr_line_warn() { printf '  %s[33mwarn%s[0m  %s' "$DR_ESC" "$DR_ESC" "$1"; }
dr_line_fail() { printf '  %s[31mFAIL%s[0m  %s' "$DR_ESC" "$DR_ESC" "$1"; }

# dr_has_finding KIND MESSAGE [FIX]: stdout holds exactly that finding line, and
# for a FIX the line right after it is the fix line. KIND is ok, warn or fail.
# With no FIX the next line must not be a fix line.
dr_has_finding() {
    local kind="$1" msg="$2" fix="${3:-}" line
    line="$("dr_line_$kind" "$msg")"
    local n; n="$(grep -nxF -- "$line" "$CZ_CASE/stdout" | head -1 | cut -d: -f1)"
    if [ -z "$n" ]; then
        cz_note_fail "no $kind line '$msg' in stdout: $(tr '\n' '|' < "$CZ_CASE/stdout" | tr -d "$DR_ESC" | cut -c1-260)"
        return 0
    fi
    local next; next="$(sed -n "$((n + 1))p" "$CZ_CASE/stdout")"
    if [ -n "$fix" ]; then
        cz_check "the fix line after '$msg'" "$next" "        fix: $fix"
    else
        case "$next" in "        fix: "*) cz_note_fail "'$msg' carries a fix line and the case expects none: $next" ;; esac
    fi
}
# dr_lacks_finding MESSAGE_FRAGMENT: no stdout line holds the fragment.
dr_lacks() { cz_expect_lacks stdout "$1"; }

# dr_summary OK WARN FAIL: the closing count line.
dr_summary() {
    local want="  ${DR_ESC}[1m$1 ok, $2 warning(s), $3 failure(s)${DR_ESC}[0m"
    cz_check "summary line" "$(tail -1 "$CZ_CASE/stdout")" "$want"
}

dr_p() { DR_P["$1"]="$2"; dr_write_profile; }          # sets a profile.env variable
dr_p_unset() { unset "DR_P[$1]"; dr_write_profile; }
dr_write_profile() {
    local pdir="$DR_SHARE/profiles/$DR_PROFILE" k
    mkdir -p "$pdir"
    : > "$pdir/profile.env"
    for k in "${!DR_P[@]}"; do printf '%s=%q\n' "$k" "${DR_P[$k]}" >> "$pdir/profile.env"; done
}

# dr_settings N [EXTRA...]: a deny wall of N rules, with a Read(~/ rule, written
# to the profile's settings.json. EXTRA rules are appended to the list.
dr_settings() {
    local out="$1" n="$2"; shift 2
    python3 - "$out" "$n" "$@" <<'PYEOF'
import json, sys
out, n, extra = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
rules = ["Bash(rule%d:*)" % i for i in range(n - 1 - len(extra))] + ["Read(~/.ssh/**)"] + extra
json.dump({"permissions": {"deny": rules}}, open(out, "w"))
PYEOF
}

# dr_install: a healthy deployment of profile magent, for Linux, with every
# answer a healthy machine gives. Individual cases then break one thing.
dr_install() {
    local pdir="$DR_SHARE/profiles/$DR_PROFILE" bin="$DR_HOME/.local/bin"
    mkdir -p "$pdir" "$DR_SHARE/backends" "$bin" "$CZ_STATE"
    printf '#!/bin/sh\n' > "$DR_SHARE/run.sh"; chmod +x "$DR_SHARE/run.sh"
    printf '#!/bin/sh\n' > "$DR_SHARE/run-instance.sh"; chmod +x "$DR_SHARE/run-instance.sh"
    printf 'backend\n' > "$DR_SHARE/backends/claude.sh"
    printf '#!/bin/sh\n' > "$bin/maintainer"; chmod +x "$bin/maintainer"
    printf '#!/bin/sh\n' > "$bin/maintainer-merge"; chmod +x "$bin/maintainer-merge"
    DR_P=()
    DR_P[REPO_SLUG]=o/r
    DR_P[REPO_PATH]="$CZ_REPO"
    DR_P[GH_ACCOUNT]=testuser
    DR_P[STATE_DIR]="$CZ_STATE"
    DR_P[POST]=off
    DR_P[REQUIRED_COMMANDS]="gh git"
    dr_write_profile
    printf '{}\n' > "$pdir/deny.json"
    dr_settings "$pdir/settings.json" 120
    dr_settings "$pdir/settings-rehearsal.json" 120

    # The repository the deployment came from: one commit, clean, with an origin
    # ref that equals HEAD. VERSION records its short head.
    cz_repo_init
    cz_write README.md "hello"
    cz_commit base CZ_C0
    cz_git update-ref refs/remotes/origin/main HEAD
    DR_SHORT="$(cz_git rev-parse --short HEAD)"
    printf 'commit=%s\ninstalled_from=%s\n' "$DR_SHORT" "$CZ_REPO" > "$DR_SHARE/VERSION"
    mkdir -p "$DR_HOME/.config/systemd/user"
    printf '[Service]\n' > "$DR_HOME/.config/systemd/user/podman-userns-warmup.service"

    dr_healthy_answers
}

# The answers every external tool gives on a healthy host.
dr_healthy_answers() {
    cz_gh api-user "testuser"
    cz_gh auth-token "ghp_FAKEFAKEFAKEFAKEFAKE0000"
    cz_gh run-list "$(dr_runs success 3)"
    dr_ans sc-env "" 0
    dr_ans sc-timers "$(printf 'Mon 2026-01-05 10:00:00 UTC 3h left Mon 2026-01-05 04:00:00 UTC 3h ago maintainer@magent-review.timer maintainer@magent-review.service\nMon 2026-01-05 22:00:00 UTC 15h left Sun 2026-01-04 22:00:00 UTC 9h ago maintainer@magent-issues.timer maintainer@magent-issues.service')" 0
    dr_ans sc-units "" 0
    dr_ans loginctl yes
    dr_ans podman-cold "" 0
}
# dr_iso_ago HOURS: the UTC time HOURS hours and 20 minutes ago, ISO 8601 with a
# Z. Epoch arithmetic, because `date -d "N hours M minutes ago"` is not portable.
dr_iso_ago() { date -u -d "@$(( $(date +%s) - $1 * 3600 - 1200 ))" +%Y-%m-%dT%H:%M:%SZ; }

# dr_runs CONCLUSION HOURS_AGO [WORKFLOW [STATUS]]: the JSON `gh run list` prints
# for one run created HOURS_AGO hours and 20 minutes ago.
dr_runs() {
    local ts; ts="$(dr_iso_ago "$2")"
    printf '[{"workflowName":"%s","status":"%s","conclusion":"%s","createdAt":"%s","url":"https://example.invalid/run/%s"}]' \
        "${3:-CI}" "${4:-completed}" "$1" "$ts" "$2"
}

# dr_exp_healthy [quick]: the whole stdout of a doctor run on the healthy
# deployment of dr_install, one line per element.
dr_exp_healthy() {
    dr_exp_head "Deployment"
    dr_exp_ok "installed at $DR_SHARE"
    dr_exp_ok "no nested profiles/ or backends/"
    dr_exp_ok "run.sh is executable"
    dr_exp_ok "run-instance.sh is executable"
    dr_exp_ok "maintainer on PATH and executable"
    dr_exp_ok "maintainer-merge on PATH and executable"
    dr_exp_head "Profile and containment"
    dr_exp_ok "profile 'magent' present"
    dr_exp_ok "deny wall generated, 120 rules"
    dr_exp_ok "credential Read rules use the home-relative form that actually denies"
    dr_exp_ok "rehearsal wall present, 120 rules (POST=off posts nothing)"
    dr_exp_head "Backend"
    dr_exp_ok "backend 'claude' installed"
    dr_exp_ok "claude on PATH (2.0.0 (Claude Code))"
    dr_exp_head "Commands the prompts tell the agent to run"
    dr_exp_ok "gh resolves"
    dr_exp_ok "git resolves"
    dr_exp_head "GitHub identity"
    dr_exp_ok "gh is testuser"
    dr_exp_head "Posting"
    dr_exp_ok "POST=off: this profile writes reports and drafts, and posts nothing"
    dr_exp_head "Repository"
    dr_exp_ok "repo at $CZ_REPO"
    dr_exp_ok "working tree clean"
    dr_exp_ok "not ahead of origin/main"
    dr_exp_ok "no workflow on main has been red for 6h or more"
    dr_exp_head "Scheduler"
    dr_exp_ok "2 systemd timer(s) enabled for magent"
    dr_exp_ok "lingering on: timers run without a login session"
    dr_exp_head "Container verification"
    if [ "${1:-}" = quick ]; then
        dr_exp_warn "skipped (--quick)"
    else
        dr_exp_ok "podman runs from cold"
        dr_exp_ok "userns warm-up unit installed (hardened units can reuse the namespace)"
    fi
    dr_exp_head "Sandbox"
    dr_exp_ok "no systemd user unit to probe on this machine"
    dr_exp_head "Audit trail"
    dr_exp_ok "0 run report(s), 0 open receipt(s)"
    dr_exp_ok "no receipt outlives its pull request"
    dr_exp_ok "no lease has gone 12h without a renewal"
    dr_exp_ok "state directory writable"
    dr_exp_ok "no pinned token left on disk by an earlier run"
    dr_exp_ok "every task has completed since its last failure"
    printf '%s\n' "" "${DR_ESC}[1mDeployed code${DR_ESC}[0m"
    dr_exp_ok "deployed code is that tree's HEAD ($DR_SHORT)"
    if [ "${1:-}" = quick ]; then dr_exp_sum 30 1 0; else dr_exp_sum 32 0 0; fi
}

# dr_tree PARTS...: a copy of the program files in $CZ_CASE/tree, so a case can
# take away what the program looks for beside itself. PARTS: profile.sh and
# defaults.env (the two files of lib/) to include. Both programs are copied.
dr_tree() {
    local t="$CZ_CASE/tree" p
    mkdir -p "$t/bin" "$t/lib"
    cp "$DR_DOCTOR" "$t/bin/maintainer-doctor"; cp "$DR_REPO" "$t/bin/maintainer-repo"
    for p in "$@"; do cp "$MX_TREE/lib/$p" "$t/lib/$p" || { echo "characterization: no lib/$p" >&2; exit 2; }; done
}

# dr_os NAME [LAUNCHD_LIST_TEXT]: the host reports operating system NAME. For
# Darwin a launchctl stub answers `list` with the text given.
dr_os() {
    printf '%s\n' "$1" > "$CZ_CASE/ans/uname"
    if [ "$1" = Darwin ]; then
        printf '%s' "${2:-}" > "$CZ_CASE/ans/launchctl.out"
        dr_stub_file launchctl <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CZ_CASE_DIR:?}/calls/launchctl"
if [ "${1:-}" != list ]; then printf 'launchctl %s\n' "$*" >> "$CZ_CASE_DIR/unplanned-tools"; exit 99; fi
cat "$CZ_CASE_DIR/ans/launchctl.out"
STUB
        : > "$CZ_CASE/calls/launchctl"
    fi
}

# dr_expect_missing NAME: the program is expected to try to run NAME although it
# is not installed (it gets "command not found"). Without this a call to a tool
# that does not exist fails the case. dr_expect_missing_calls checks the tries.
dr_expect_missing() { printf '%s\n' "$1" >> "$CZ_CASE/ans/notfound-ok"; : >> "$CZ_CASE/calls/notfound"; }
dr_expect_missing_calls() {
    local want="$CZ_CASE/want.notfound"
    if [ "$#" -eq 0 ]; then : > "$want"; else printf '%s\n' "$@" > "$want"; fi
    cmp -s "$want" "$CZ_CASE/calls/notfound" \
        || cz_note_fail "attempts to run a missing tool differ. expected: $(tr '\n' '|' < "$want") got: $(tr '\n' '|' < "$CZ_CASE/calls/notfound")"
}

# dr_repo_env: the environment maintainer-repo is run with when it has no deployed
# profile: the five names run.sh exports, and the globs of the fixture repository.
dr_repo_env() {
    CZ_E[MAINTAINER_SLUG]=o/r
    CZ_E[MAINTAINER_REPO]="$CZ_REPO"
    CZ_E[MAINTAINER_ACCOUNT]=testuser
    CZ_E[MAINTAINER_STATE]="$CZ_STATE"
    CZ_E[MAINTAINER_POST]=on
    CZ_E[PROD_GLOBS]='crates/*/src/*'
}
dr_repo() { dr_run "$DR_REPO" "$@"; }

# dr_expect_block STREAM TEXT: the lines of TEXT appear in STREAM as one
# contiguous run. (cz_expect_has with a multi-line string would pass on any one
# of its lines, because grep -F treats each line as a separate pattern.)
dr_expect_block() {
    local which="$1" text="$2"
    if ! python3 -c '
import sys
data = open(sys.argv[1]).read()
sys.exit(0 if (sys.argv[2] + "\n") in data else 1)' "$CZ_CASE/$which" "$text"; then
        cz_note_fail "$which lacks the block: $(tr '\n' '|' <<<"$text" | cut -c1-240) (got: $(tr '\n' '|' < "$CZ_CASE/$which" | cut -c1-240))"
    fi
}
