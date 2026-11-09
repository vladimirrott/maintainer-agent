#!/usr/bin/env bash
# Helpers for the characterization of the orchestrator (lib/run.sh, lib/profile.sh,
# lib/backends/*). Sourced by run-*.sh after lib.sh, never run on its own.
#
# What is under test: the lib/ tree of MX_TREE, copied into every case. The copy
# gets a fixture profile named fx, so nothing reads the real profiles, and a
# fixture preamble, so the prompt bytes are written out in the tests. The
# program runs under `env -i` with a PATH made of two directories only: the case's
# stub directory and a directory of symlinks to the real tools run.sh needs. A
# tool that is in neither (claude, codex, opencode, cursor-agent, podman, systemctl)
# is simply absent, which is how the "not on PATH" refusals are reached.
#
# Stubs: gh, the maintainer helper, claude, codex, opencode, cursor-agent,
# notify-send, loginctl, sleep, date and flock all log their argv and the part of
# their environment the test cares about. date answers from a fixed clock. flock
# and gh answer from files, so a case says what a call returns.
#
# A later port of run.sh to Rust is held to the same cases by setting RZ_RUNNER to
# the command that replaces `bash <tree>/lib/run.sh`.

# shellcheck disable=SC2034  # RZ_* names are read by the case files that source this
RZ_TOKEN="ghp_FIXTURE0123456789abcdefghij"
RZ_EPOCH=1767225600            # 2026-01-01T00:00:00Z, the fixture clock
RZ_STAMP="2026-01-01T00-00"
RZ_ISO="2026-01-01T00:00:00+00:00"
RZ_RUNID="$RZ_STAMP-review"

# The tools run.sh, profile.sh, the backends and the helper stubs use. Each is
# linked into one directory so PATH holds nothing else.
RZ_TOOL_NAMES="awk basename bash cat chmod cmp cp cut dash dirname env false find git grep head id ln ls mkdir mktemp mv python3 readlink rm sed sh sort stat tail tee touch tr true uniq wc xargs timeout"

rz_init() {
    RZ_TOOLS="$CZ_ROOT/tools"; mkdir -p "$RZ_TOOLS"
    local t p
    for t in $RZ_TOOL_NAMES; do
        p="$(PATH="$CZ_BASE_PATH" command -v "$t")" \
            || { echo "run characterization: the host has no '$t'" >&2; exit 2; }
        ln -s "$p" "$RZ_TOOLS/$t"
    done
    RZ_REAL_DATE="$(PATH="$CZ_BASE_PATH" command -v date)" || exit 2
    RZ_REAL_FLOCK="$(PATH="$CZ_BASE_PATH" command -v flock)" || { echo "run characterization: no flock" >&2; exit 2; }
    RZ_BASH="$(PATH="$CZ_BASE_PATH" command -v bash)"
    RZ_TIMEOUT="$(PATH="$CZ_BASE_PATH" command -v timeout)"
    : "${RZ_RUNNER:=}"
    [ -f "$MX_TREE/lib/run.sh" ] || { echo "run characterization: no lib/run.sh under MX_TREE=$MX_TREE" >&2; exit 2; }
    rz_stubs_write
    rz_tree_base
}

# --- the stubs ----------------------------------------------------------------

rz_stubs_write() {
    RZ_STUBS="$CZ_ROOT/stubs"; mkdir -p "$RZ_STUBS"
    cat > "$RZ_STUBS/gh" <<'STUB'
#!/usr/bin/env bash
# Answers from files under $CZ_CASE_DIR/gh. Call N of a kind reads KEY.N.out and
# KEY.N.rc when they exist, otherwise KEY.out and KEY.rc. A call with no answer
# exits 99 and is logged as unplanned. Logs argv and whether GH_TOKEN, which must
# never be printed, equals the fixture token.
d="${CZ_CASE_DIR:?}/gh"
line=""
for a in "$@"; do line="$line$(printf '%q' "$a") "; done
printf '%s\n' "${line% }" >> "$d/calls"
tok=unset
if [ -n "${GH_TOKEN+x}" ]; then
    if [ "$GH_TOKEN" = "$(cat "$CZ_CASE_DIR/token")" ]; then tok=match; else tok=other; fi
fi
gt=unset; [ -n "${GITHUB_TOKEN+x}" ] && gt=set
printf '%s %s GH_TOKEN=%s GITHUB_TOKEN=%s\n' "${1:-}" "${2:-}" "$tok" "$gt" >> "$d/envlog"
case "${1:-} ${2:-}" in
    "auth switch") key=auth-switch ;;
    "api user")    key=api-user ;;
    "auth token")  key=auth-token ;;
    *)             key="" ;;
esac
if [ -n "$key" ]; then
    n=0; [ -e "$d/$key.count" ] && n="$(cat "$d/$key.count")"
    n=$((n + 1)); printf '%s' "$n" > "$d/$key.count"
    if [ -e "$d/$key.$n.out" ] || [ -e "$d/$key.$n.rc" ]; then base="$key.$n"; else base="$key"; fi
fi
if [ -z "$key" ] || { [ ! -e "$d/$base.out" ] && [ ! -e "$d/$base.rc" ]; }; then
    printf '%s\n' "${line% }" >> "$d/unplanned"
    echo "stub gh: unplanned call: $*" >&2
    exit 99
fi
[ -e "$d/$base.out" ] && cat "$d/$base.out"
[ -e "$d/$base.err" ] && cat "$d/$base.err" >&2
rc=0; [ -e "$d/$base.rc" ] && rc="$(cat "$d/$base.rc")"
exit "$rc"
STUB
    cat > "$RZ_STUBS/maintainer" <<'STUB'
#!/usr/bin/env bash
# The helper run.sh calls as $HELPER. Logs one line per call to h/calls, with the
# pid argument of run-lease replaced by <ppid> when it is this process's parent
# (run.sh) and <other-pid> when it is not. Logs the environment it was given to
# h/envlog, one VAR=value line per variable per call. Answers from h/VERB.out,
# h/VERB.err and h/VERB.rc.
d="${CZ_CASE_DIR:?}/h"
verb="${1:-}"
args=("$@")
if [ "$verb" = run-lease ] && [ "${#args[@]}" -ge 3 ]; then
    if [ "${args[2]}" = "$PPID" ]; then args[2]='<ppid>'; else args[2]='<other-pid>'; fi
fi
line=""
for a in "${args[@]}"; do line="$line$(printf '%q' "$a") "; done
printf '%s\n' "${line% }" >> "$d/calls"
for v in MAINTAINER_PROFILE MAINTAINER_TASK MAINTAINER_TASKS MAINTAINER_SKILL MAINTAINER_REPO MAINTAINER_SLUG \
         MAINTAINER_STATE MAINTAINER_ACCOUNT MAINTAINER_POST MAINTAINER_IN_RUN MAINTAINER_FORCE MAINTAINER_SCRIPTS \
         MAINTAINER_VERSION MAINTAINER_COMMIT PROD_GLOBS CLAIM_LABEL PROFILE_DIR REPO_PATH GITHUB_TOKEN; do
    if [ -n "${!v+x}" ]; then printf '%s %s=%s\n' "$verb" "$v" "${!v}" >> "$d/envlog"
    else printf '%s %s=<unset>\n' "$verb" "$v" >> "$d/envlog"; fi
done
tok=unset
if [ -n "${GH_TOKEN+x}" ]; then
    if [ "$GH_TOKEN" = "$(cat "$CZ_CASE_DIR/token")" ]; then tok=match; else tok=other; fi
fi
printf '%s GH_TOKEN=%s\n' "$verb" "$tok" >> "$d/envlog"
printf '%s PWD=%s\n' "$verb" "$PWD" >> "$d/envlog"
[ -e "$d/$verb.out" ] && cat "$d/$verb.out"
[ -e "$d/$verb.err" ] && cat "$d/$verb.err" >&2
rc=0; [ -e "$d/$verb.rc" ] && rc="$(cat "$d/$verb.rc")"
exit "$rc"
STUB
    cat > "$RZ_STUBS/backend" <<'STUB'
#!/usr/bin/env bash
# One stub for claude, codex, opencode and cursor-agent. Logs to b/NAME.* : argv
# (one call per line), the last argument byte for byte, stdin byte for byte, the
# environment the backend files set, the working directory and where fd 9 points.
# Then it runs the case's b/behave hook (shell code, sourced), prints b/out and
# b/err and exits with b/rc.
name="$(basename "$0")"
d="${CZ_CASE_DIR:?}/b"
line=""
for a in "$@"; do line="$line$(printf '%q' "$a") "; done
printf '%s\n' "${line% }" >> "$d/$name.argv"
if [ "$#" -gt 0 ]; then printf '%s' "${!#}" > "$d/$name.lastarg"; fi
cat > "$d/$name.stdin"
for v in MAX_THINKING_TOKENS CLAUDE_CODE_SUBAGENT_MODEL MAINTAINER_SETTINGS MAINTAINER_CURSOR_DIR CURSOR_CONFIG_DIR \
         OPENCODE_CONFIG GROQ_API_KEY MAINTAINER_POST MAINTAINER_TASK MAINTAINER_SCRIPTS PROFILE_DIR REPO_PATH GITHUB_TOKEN; do
    if [ -n "${!v+x}" ]; then printf '%s=%s\n' "$v" "${!v}" >> "$d/$name.env"
    else printf '%s=<unset>\n' "$v" >> "$d/$name.env"; fi
done
tok=unset
if [ -n "${GH_TOKEN+x}" ]; then
    if [ "$GH_TOKEN" = "$(cat "$CZ_CASE_DIR/token")" ]; then tok=match; else tok=other; fi
fi
printf 'GH_TOKEN=%s\nPWD=%s\nfd9=%s\n' "$tok" "$PWD" "$(readlink "/proc/$$/fd/9" 2>/dev/null || echo none)" >> "$d/$name.env"
# shellcheck disable=SC1091
[ -f "$d/behave" ] && . "$d/behave"
[ -e "$d/out" ] && cat "$d/out"
[ -e "$d/err" ] && cat "$d/err" >&2
rc=0; [ -e "$d/rc" ] && rc="$(cat "$d/rc")"
exit "$rc"
STUB
    cat > "$RZ_STUBS/notify-send" <<'STUB'
#!/usr/bin/env bash
line=""
for a in "$@"; do line="$line$(printf '%q' "$a") "; done
printf '%s|DISPLAY=%s|DBUS=%s\n' "${line% }" "${DISPLAY-<unset>}" "${DBUS_SESSION_BUS_ADDRESS-<unset>}" >> "${CZ_CASE_DIR:?}/notify.calls"
exit 0
STUB
    cat > "$RZ_STUBS/loginctl" <<'STUB'
#!/usr/bin/env bash
line=""
for a in "$@"; do line="$line$(printf '%q' "$a") "; done
printf '%s\n' "${line% }" >> "${CZ_CASE_DIR:?}/loginctl.calls"
[ -e "$CZ_CASE_DIR/loginctl.out" ] && cat "$CZ_CASE_DIR/loginctl.out"
exit 0
STUB
    cat > "$RZ_STUBS/sleep" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CZ_CASE_DIR:?}/sleep.calls"
exit 0
STUB
    cat > "$RZ_STUBS/date" <<'STUB'
#!/usr/bin/env bash
# A fixed clock: every call answers for the instant in $CZ_CASE_DIR/now (epoch
# seconds), so the log names and the Provenance line are the same on every run.
now="$(cat "${CZ_CASE_DIR:?}/now")"
exec "$RZ_REAL_DATE" -d "@$now" "$@"
STUB
    cat > "$RZ_STUBS/flock" <<'STUB'
#!/usr/bin/env bash
# Logs argv, optionally stamps the file named in flock.touch with the fixture
# clock (to simulate a run ahead of this one promoting the cadence stamp while
# this one waited), and
# exits with flock.rc (default 0).
printf '%s\n' "$*" >> "${CZ_CASE_DIR:?}/flock.calls"
[ -e "$CZ_CASE_DIR/flock.touch" ] && touch -d "@$(cat "$CZ_CASE_DIR/now")" "$(cat "$CZ_CASE_DIR/flock.touch")"
rc=0; [ -e "$CZ_CASE_DIR/flock.rc" ] && rc="$(cat "$CZ_CASE_DIR/flock.rc")"
exit "$rc"
STUB
    local s
    for s in gh maintainer backend notify-send loginctl sleep date flock; do
        bash -n "$RZ_STUBS/$s" || { echo "run characterization: stub $s does not parse" >&2; exit 2; }
        chmod +x "$RZ_STUBS/$s"
    done
    export RZ_REAL_DATE
}

# --- the tree under test --------------------------------------------------------

# One copy of MX_TREE/lib per file of cases, with a fixture preamble and prose
# file, the real transcript filter, and a VERSION stamp. Each case copies it again.
rz_tree_base() {
    RZ_TREE_BASE="$CZ_ROOT/treebase"
    mkdir -p "$RZ_TREE_BASE/scripts" "$RZ_TREE_BASE/profiles"
    cp -a "$MX_TREE/lib" "$RZ_TREE_BASE/lib"
    cp -a "$MX_TREE/scripts/transcript.py" "$RZ_TREE_BASE/scripts/transcript.py"
    printf 'CORE doctrine for __MAINTAINER__ working on __SLUG__ (again __MAINTAINER__)\n' > "$RZ_TREE_BASE/lib/preamble-core.md"
    printf 'PROSE-STYLE rules\n' > "$RZ_TREE_BASE/lib/prose-style.md"
    printf 'version=9.9.9\ncommit=abc1234\n' > "$RZ_TREE_BASE/VERSION"
    local f
    for f in run.sh profile.sh defaults.env failure-shapes.json; do
        [ -f "$RZ_TREE_BASE/lib/$f" ] || { echo "run characterization: lib/$f missing under MX_TREE" >&2; exit 2; }
    done
    for f in claude codex cursor opencode; do
        [ -f "$RZ_TREE_BASE/lib/backends/$f.sh" ] || { echo "run characterization: lib/backends/$f.sh missing" >&2; exit 2; }
    done
}

# --- a case -------------------------------------------------------------------

# rz_setup: call first in every case function, after cz_case made its sandbox. It
# replaces the merge-gate environment of lib.sh with the orchestrator's: a tree
# copy, a fixture profile, scratch HOME and state, stubs and default answers.
rz_setup() {
    CZ_E=()
    RZ_HOME="$CZ_CASE/home"; RZ_STATE="$RZ_HOME/.local/state/fx-maint"
    RZ_TREE="$CZ_CASE/tree"; RZ_PROFILE_DIR="$RZ_TREE/profiles/fx"
    RZ_LOGS="$RZ_STATE/logs"; RZ_TMP="$CZ_CASE/tmp"
    mkdir -p "$RZ_HOME/.local/bin" "$RZ_STATE/checkout/.git" "$RZ_TMP" "$CZ_CASE/h" "$CZ_CASE/b"
    cp -a "$RZ_TREE_BASE" "$RZ_TREE"
    printf '%s\n' "$RZ_TOKEN" > "$CZ_CASE/token"
    printf '%s\n' "$RZ_EPOCH" > "$CZ_CASE/now"
    : > "$CZ_CASE/gh/envlog"
    local s
    for s in gh notify-send loginctl sleep date flock; do cp "$RZ_STUBS/$s" "$CZ_CASE/bin/$s"; done
    for s in claude codex opencode cursor-agent; do cp "$RZ_STUBS/backend" "$CZ_CASE/bin/$s"; done
    cp "$RZ_STUBS/maintainer" "$RZ_HOME/.local/bin/maintainer"
    cz_stub_tool systemctl
    rz_profile_write
    # What the real tools would print, so a case that does not care still gets a
    # run that works from the first call to the last.
    cz_gh_rz auth-switch "" 0
    cz_gh_rz api-user "fxacct" 0
    cz_gh_rz auth-token "$RZ_TOKEN" 0
    printf '=== maintainer %s ===\nskill        fixture-skill\n' "$RZ_RUNID" > "$CZ_CASE/h/start.out"
    printf 'finished %s\n' "$RZ_RUNID" > "$CZ_CASE/h/finish.out"
    printf 'digest-line-from-helper\n' > "$CZ_CASE/h/digest.out"
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"agent says hello"},{"type":"tool_use","name":"Bash","input":{"command":"echo hi"}}]}}' > "$CZ_CASE/b/out"
    : > "$CZ_CASE/h/calls"
    CZ_E[PATH]="$CZ_CASE/bin:$RZ_TOOLS"
    CZ_E[HOME]="$RZ_HOME"
    CZ_E[LC_ALL]=C
    CZ_E[TZ]=UTC
    CZ_E[USER]=fixture-user
    CZ_E[LOGNAME]=fixture-user
    CZ_E[TMPDIR]="$RZ_TMP"
    CZ_E[CZ_CASE_DIR]="$CZ_CASE"
    CZ_E[RZ_REAL_DATE]="$RZ_REAL_DATE"
    CZ_E[GIT_CONFIG_NOSYSTEM]=1
    CZ_E[GIT_CONFIG_GLOBAL]=/dev/null
    CZ_E[GIT_TERMINAL_PROMPT]=0
    CZ_E[MAINTAINER_GH_BACKOFF]=0
}

cz_gh_rz() {  # $1 = key (or key.N), $2 = what gh prints, $3 = its exit code
    if [ -n "$2" ]; then printf '%s\n' "$2" > "$CZ_CASE/gh/$1.out"; else : > "$CZ_CASE/gh/$1.out"; fi
    printf '%s' "$3" > "$CZ_CASE/gh/$1.rc"
}

# The fixture profile. Same shape as profiles/magent/profile.env: every tunable
# that the real one reads from MAINTAINER_* keeps that spelling.
rz_profile_write() {
    mkdir -p "$RZ_PROFILE_DIR/prompts"
    cat > "$RZ_PROFILE_DIR/profile.env" <<'PROFILE'
PROFILE_NAME="fx"
REPO_PATH="${MAINTAINER_REPO_PATH:-$HOME/.local/state/fx-maint/checkout}"
REPO_ORIGIN="${MAINTAINER_REPO_ORIGIN:-}"
REPO_SLUG="fx/repo"
MAINTAINER_NAME="Fixture Maintainer"
GH_ACCOUNT="fxacct"
STATE_DIR="${MAINTAINER_STATE_DIR:-$HOME/.local/state/fx-maint}"
HELPER="$HOME/.local/bin/maintainer"
TASKS="review issues"
MODEL_review="opus"
MODEL_issues="opus"
THINKING_review=31999
THINKING_issues=16000
SUBAGENT_MODEL_review="sonnet"
MIN_HOURS_review=6
MIN_HOURS_issues=36
POST="${MAINTAINER_POST:-on}"
PROSE_STYLE="${MAINTAINER_PROSE_STYLE:-stop-slop}"
BACKEND="${MAINTAINER_BACKEND:-claude}"
CLAIM_LABEL=""
PROD_GLOBS="bin/* lib/*"
PROFILE
    printf 'COMMON-PREAMBLE for fx\nsecond preamble line\n' > "$RZ_PROFILE_DIR/prompts/common-preamble.md"
    printf 'TASK review body\n' > "$RZ_PROFILE_DIR/prompts/review.md"
    printf 'TASK issues body\n' > "$RZ_PROFILE_DIR/prompts/issues.md"
    printf '{"permissions": {"deny": []}}\n' > "$RZ_PROFILE_DIR/settings.json"
    printf '{"model": "x"}\n' > "$RZ_PROFILE_DIR/opencode.json"
}
rz_profile_add() { printf '%s\n' "$1" >> "$RZ_PROFILE_DIR/profile.env"; }  # later lines win
rz_wall() {  # renders the rehearsal walls for every backend
    printf '{"permissions": {"deny": ["gh issue create"]}}\n' > "$RZ_PROFILE_DIR/settings-rehearsal.json"
    printf '{"model": "rehearsal"}\n' > "$RZ_PROFILE_DIR/opencode-rehearsal.json"
    mkdir -p "$RZ_PROFILE_DIR/cursor-rehearsal" "$RZ_PROFILE_DIR/cursor"
    printf '{}\n' > "$RZ_PROFILE_DIR/cursor-rehearsal/cli-config.json"
    printf '{}\n' > "$RZ_PROFILE_DIR/cursor/cli-config.json"
}

rz_set_backend_out() { printf '%s\n' "$1" > "$CZ_CASE/b/out"; }
rz_backend_behave() { cat > "$CZ_CASE/b/behave"; }   # shell code the backend stub runs, from stdin

# --- running ------------------------------------------------------------------

rz_pairs() {
    RZ_PAIRS=()
    local k
    for k in "${!CZ_E[@]}"; do RZ_PAIRS+=("$k=${CZ_E[$k]}"); done
}

# rz_run ARGS...: run.sh <ARGS>. Sets CZ_RC; the two streams land in
# $CZ_CASE/stdout and $CZ_CASE/stderr, apart.
rz_run() {
    rz_pairs
    # The outer braces take the "Terminated" line this shell prints when the run
    # dies of a signal, so it does not land in the runner's output.
    if [ -n "$RZ_RUNNER" ]; then
        # shellcheck disable=SC2086  # RZ_RUNNER is a command line of plain words
        { env -i "${RZ_PAIRS[@]}" "$RZ_TIMEOUT" 60 $RZ_RUNNER "$@" > "$CZ_CASE/stdout" 2> "$CZ_CASE/stderr" < /dev/null; } 2>/dev/null
    else
        { env -i "${RZ_PAIRS[@]}" "$RZ_TIMEOUT" 60 "$RZ_BASH" "$RZ_TREE/lib/run.sh" "$@" > "$CZ_CASE/stdout" 2> "$CZ_CASE/stderr" < /dev/null; } 2>/dev/null
    fi
    CZ_RC=$?
}

# rz_drive CODE: runs bash -c CODE in the same environment, with RZ_TREE and
# RZ_PROFILE_DIR exported, for the pieces of run.sh that cannot be reached
# through the whole program (a backend's own argv, the classifier on one log).
rz_drive() {
    CZ_E[RZ_TREE]="$RZ_TREE"; CZ_E[PROFILE_DIR]="$RZ_PROFILE_DIR"
    rz_pairs
    env -i "${RZ_PAIRS[@]}" "$RZ_TIMEOUT" 60 "$RZ_BASH" -c "$1" > "$CZ_CASE/stdout" 2> "$CZ_CASE/stderr" < /dev/null
    CZ_RC=$?
}

# --- reading what the run left ------------------------------------------------

# The one log of the run. A case that expects none says so with rz_expect_no_log.
rz_logfile() {
    local n=0 f first=""
    for f in "$RZ_LOGS"/*.log; do
        [ -e "$f" ] || continue
        n=$((n + 1)); [ -n "$first" ] || first="$f"
    done
    if [ "$n" -ne 1 ]; then cz_note_fail "expected exactly one log under $RZ_LOGS, found $n"; return 1; fi
    printf '%s' "$first"
}
rz_log_has() {   # a fixed string the log must contain
    local f; f="$(rz_logfile)" || return 0
    grep -qF -- "$1" "$f" || cz_note_fail "log lacks '$1': $(tr '\n' '|' < "$f" | cut -c1-300)"
}
rz_log_lacks() {
    local f; f="$(rz_logfile)" || return 0
    if grep -qF -- "$1" "$f"; then cz_note_fail "log holds '$1' and must not: $(tr '\n' '|' < "$f" | cut -c1-300)"; fi
}
rz_log_line() {  # an exact whole line of the log
    local f; f="$(rz_logfile)" || return 0
    grep -qxF -- "$1" "$f" || cz_note_fail "log has no line '$1': $(tr '\n' '|' < "$f" | cut -c1-300)"
}
rz_expect_no_log() {
    local n=0 f
    for f in "$RZ_LOGS"/*.log; do [ -e "$f" ] && n=$((n + 1)); done
    cz_check "number of logs" "$n" 0
}
rz_expect_no_logs_dir() { [ ! -e "$RZ_LOGS" ] || cz_note_fail "logs directory exists and must not: $RZ_LOGS"; }

# The helper's call log, one call per line, exactly.
rz_expect_helper() {
    local want="$CZ_CASE/want.helper"
    if [ "$#" -eq 0 ]; then : > "$want"; else printf '%s\n' "$@" > "$want"; fi
    cmp -s "$want" "$CZ_CASE/h/calls" \
        || cz_note_fail "helper calls differ. expected: $(tr '\n' '|' < "$want" | cut -c1-400) got: $(tr '\n' '|' < "$CZ_CASE/h/calls" | cut -c1-400)"
}
rz_helper_count() {  # how many helper calls start with a fixed string
    local n; n="$(grep -cF -- "$1" "$CZ_CASE/h/calls")"; printf '%s' "${n:-0}"
}
rz_expect_helper_count() { cz_check "helper calls containing '$1'" "$(rz_helper_count "$1")" "$2"; }
rz_helper_env() {  # VERB VAR -> its value as the helper saw it
    sed -n "s/^$1 $2=//p" "$CZ_CASE/h/envlog" | head -1
}

rz_gh_calls() { cat "$CZ_CASE/gh/calls"; }
rz_expect_gh() {  # the gh call log, exactly
    local want="$CZ_CASE/want.gh2"
    if [ "$#" -eq 0 ]; then : > "$want"; else printf '%s\n' "$@" > "$want"; fi
    cmp -s "$want" "$CZ_CASE/gh/calls" \
        || cz_note_fail "gh calls differ. expected: $(tr '\n' '|' < "$want" | cut -c1-400) got: $(tr '\n' '|' < "$CZ_CASE/gh/calls" | cut -c1-400)"
}

# The notify-send call log. Each argument is one whole call as cz_argv writes it,
# followed by the display and bus the stub saw.
rz_notify_count() { local n=0; [ -e "$CZ_CASE/notify.calls" ] && n="$(wc -l < "$CZ_CASE/notify.calls" | tr -d ' ')"; printf '%s' "$n"; }
rz_expect_notify_count() { cz_check "notify-send calls" "$(rz_notify_count)" "$1"; }
rz_notify_line() {  # N (1-based) -> the Nth call
    sed -n "${1}p" "$CZ_CASE/notify.calls" 2>/dev/null
}
# rz_expect_notify N URGENCY TITLE BODY: the Nth call, with the default display
# and the bus path of the current user.
rz_expect_notify() {
    local want got
    want="$(LC_ALL=C; cz_argv -u "$2" -a maintainer "$3" "$4")|DISPLAY=${5:-:0}|DBUS=unix:path=/run/user/$(id -u)/bus"
    got="$(rz_notify_line "$1")"
    [ "$got" = "$want" ] || cz_note_fail "notify call $1 differs. expected: $want got: $got"
}

rz_b() { printf '%s/b/%s' "$CZ_CASE" "$1"; }  # path of a backend stub record
rz_expect_b_argv() {  # NAME then the exact argv lines, one per call
    local name="$1"; shift
    local want="$CZ_CASE/want.argv"
    if [ "$#" -eq 0 ]; then : > "$want"; else printf '%s\n' "$@" > "$want"; fi
    if [ ! -e "$(rz_b "$name.argv")" ]; then cz_note_fail "$name was never called"; return 0; fi
    cmp -s "$want" "$(rz_b "$name.argv")" \
        || cz_note_fail "$name argv differs. expected: $(tr '\n' '|' < "$want" | cut -c1-400) got: $(tr '\n' '|' < "$(rz_b "$name.argv")" | cut -c1-400)"
}
rz_expect_b_not_called() { [ ! -e "$(rz_b "$1.argv")" ] || cz_note_fail "$1 was called and must not be: $(head -1 "$(rz_b "$1.argv")")"; }
rz_b_env() { sed -n "s/^$2=//p" "$(rz_b "$1.env")" | head -1; }   # NAME VAR
rz_expect_b_env() { cz_check "$1 env $2" "$(rz_b_env "$1" "$2")" "$3"; }

# --- file helpers -------------------------------------------------------------

rz_expect_file_has() {  # path, fixed string
    [ -e "$1" ] || { cz_note_fail "missing file: $1"; return 0; }
    grep -qF -- "$2" "$1" || cz_note_fail "$1 lacks '$2'"
}
rz_expect_file_lacks() {
    [ -e "$1" ] || { cz_note_fail "missing file: $1"; return 0; }
    if grep -qF -- "$2" "$1"; then cz_note_fail "$1 holds '$2' and must not"; fi
}

# rz_plant_leak PATH: a file that holds the pinned token, as an agent would have left.
rz_plant_leak() {
    mkdir -p "$(dirname "$1")"
    printf 'before %s after\n' "$RZ_TOKEN" > "$1"
}
RZ_MASK="REDACTED_BY_MAINTAINER_ROTATE_THIS_SECRET"

# Number of entries left in the run's TMPDIR (the prompt temp file leak, plan F6).
rz_tmp_count() { local n=0 f; for f in "$RZ_TMP"/*; do [ -e "$f" ] && n=$((n + 1)); done; printf '%s' "$n"; }

# rz_last_ran TASK SECONDS_AGO: the cadence stamp, last-<task>.json, written as
# it was SECONDS_AGO before the fixture clock (negative: in its future).
rz_last_ran() {
    mkdir -p "$RZ_STATE/state"
    printf '{}\n' > "$RZ_STATE/state/last-$1.json"
    touch -d "@$((RZ_EPOCH - $2))" "$RZ_STATE/state/last-$1.json"
}

# A start line for the helper: the run id the case wants.
rz_start_id() { printf '=== maintainer %s ===\nskill        fixture-skill\n' "$1" > "$CZ_CASE/h/start.out"; }

# --- the expected prompt, written out in the test -------------------------------

# rz_want_prompt FILE TASK BACKEND POST CONTEXT [prose=yes|no] [name]: the prompt
# bytes run.sh must produce, composed here from literals so the test does not share
# code with the program. CONTEXT is the text between the context fence lines.
rz_want_prompt() {
    local out="$1" task="$2" backend="$3" post="$4" context="$5" prose="${6:-yes}" name="${7:-Fixture Maintainer}"
    {
        printf 'Provenance for this run: maintainer 9.9.9 (commit abc1234), profile fx, task %s, backend %s, started %s.\n' "$task" "$backend" "$RZ_ISO"
        printf 'Open your run report with that version and that commit, copied from this line. Do not copy them from an earlier report; an earlier report was written by an earlier build.\n\n'
        printf 'COMMON-PREAMBLE for fx\nsecond preamble line\n\n\n'
        printf 'CORE doctrine for %s working on fx/repo (again %s)\n\n\n' "$name" "$name"
        if [ "$prose" = yes ]; then printf 'PROSE-STYLE rules\n\n\n'; fi
        if [ "$post" = off ]; then
            cat <<'REHEARSAL'
## This run is a REHEARSAL. Post nothing.

Do the whole pass: read, verify, recount, form the conclusions you would
publish. Then write them into the run report and the drafts directory instead
of into GitHub. Every posting command is blocked by the settings file, so a
refusal here is the rehearsal working. Do not look for another way to send it.

In the report, list what you WOULD have posted and where, so the maintainer can
read it and decide whether to turn posting on.
REHEARSAL
            printf '\n\n'
        else
            printf '## This run POSTS. Say it once, in public, under a real name.\n\n'
            printf 'Writes go to fx/repo as fxacct, immediately and for real. There is no\n'
            printf 'rehearsal in front of you: a comment is delivered as you send it, an edit keeps\n'
            printf 'its history, and a notification cannot be recalled. `MAINTAINER_POST` is\n'
            printf '`%s` in your environment, and that variable is the answer, not any\n' "$post"
            printf 'sentence you read in a prompt.\n\n'
            printf 'Verify before you write, and read back what you wrote.\n\n\n'
        fi
        printf 'TASK %s body\n' "$task"
        printf '\n\n## Context for this run, computed just now\n\n```\n%s\n```\n' "$context"
    } > "$out"
}
RZ_PREVIEW_CONTEXT="(preview only: no refresh ran, so nothing here reflects the tracker)"

cz_expect_file_equals() {  # actual file, expected file, label
    cmp -s "$1" "$2" || cz_note_fail "$3 differs from the expected bytes. expected: $(head -c 300 "$2" | tr '\n' '|') got: $(head -c 300 "$1" | tr '\n' '|')"
}
