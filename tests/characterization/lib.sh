#!/usr/bin/env bash
# Shared helpers for the characterization tests of bin/maintainer-merge.
# Sourced by gate-*.sh, never run on its own.
#
# A characterization test records what the BASH program does today, including
# behaviour that looks wrong. It never changes the program. Where the bash
# program does something a later port is meant to change, the comment above the
# case says "pins current behaviour, see plan decision F<n>".
#
# Tree: MX_TREE names the tree whose bin/maintainer-merge is under test. It
# defaults to the checkout that holds this file, so the same cases can run
# against a second tree (a port, or a mutated copy) by exporting MX_TREE.
#
# Isolation: every case gets a fresh sandbox with its own stub directory first
# on PATH, its own HOME, its own state directory and its own signing key. The
# program runs under `env -i`, so nothing ambient reaches it. gh, podman, docker,
# curl, wget and ssh are stubs: nothing here reaches GitHub, a container or the
# network. Any call a case did not plan fails the case (see cz_case_end).

set -uo pipefail
# A git hook runs the suite with GIT_DIR and friends set for the commit in
# progress. Every fixture repository below would inherit them and write into the
# caller's index, so none of them survive this line.
# shellcheck disable=SC2046  # the names are git's own fixed list, one per word
unset $(git rev-parse --local-env-vars)

CZ_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MX_TREE="${MX_TREE:-$(cd "$CZ_LIB_DIR/../.." && pwd)}"
CZ_MM="$MX_TREE/bin/maintainer-merge"
CZ_GOLDEN="$CZ_LIB_DIR/golden"
CZ_BASE_PATH="$PATH"

CZ_N=0; CZ_P=0; CZ_F=0
CZ_NAME=""; CZ_CASE_FAILS=0
declare -A CZ_E=()

# --- start and finish ---------------------------------------------------------

# Refuses to run against a tree that has no gate: a suite that selects nothing
# passes, and that is the failure this check exists to prevent.
cz_init() {
    if [ ! -f "$CZ_MM" ]; then
        printf 'characterization: no bin/maintainer-merge under MX_TREE=%s\n' "$MX_TREE" >&2
        exit 2
    fi
    CZ_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cz.XXXXXX")" || exit 2
    trap 'rm -rf "$CZ_ROOT"' EXIT
    CZ_SEQ=0
}

# Prints one machine-readable summary line. The runner demands it, so a file
# that crashes before the end cannot read as a pass.
cz_finish() {
    printf 'SUMMARY cases=%d pass=%d fail=%d\n' "$CZ_N" "$CZ_P" "$CZ_F"
    [ "$CZ_N" -gt 0 ] && [ "$CZ_F" -eq 0 ]
}

# cz_case NAME FUNCTION: runs FUNCTION in a fresh sandbox. The case passes when
# every assertion inside it held and the program made no call nobody planned.
cz_case() {
    CZ_NAME="$1"; CZ_CASE_FAILS=0
    cz_sandbox_new
    "$2"
    cz_case_end
}

cz_note_fail() {  # $1 = what failed
    CZ_CASE_FAILS=$((CZ_CASE_FAILS + 1))
    printf '    %s\n' "$1" | sed -n '1,12p'
}

cz_case_end() {
    # A call to gh or to a tool the case did not plan returns 99 and is logged.
    # Without this check the program could swallow the 99 and the case would
    # read the swallowed answer as the behaviour.
    if [ -s "$CZ_CASE/gh/unplanned" ]; then
        cz_note_fail "the program made a gh call the case did not plan: $(head -1 "$CZ_CASE/gh/unplanned")"
    fi
    if [ -s "$CZ_CASE/unplanned-tools" ]; then
        cz_note_fail "the program ran a tool the case did not plan: $(head -1 "$CZ_CASE/unplanned-tools")"
    fi
    CZ_N=$((CZ_N + 1))
    if [ "$CZ_CASE_FAILS" -eq 0 ]; then
        CZ_P=$((CZ_P + 1)); printf 'PASS  %s\n' "$CZ_NAME"
    else
        CZ_F=$((CZ_F + 1)); printf 'FAIL  %s\n' "$CZ_NAME"
    fi
}

# --- the sandbox --------------------------------------------------------------

cz_stub_tool() {  # $1 = name: a tool that must never run in this case
    cat > "$CZ_CASE/bin/$1" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "${CZ_CASE_DIR:?}/unplanned-tools"
echo "stub: $(basename "$0") must not run in this case" >&2
exit 99
STUB
    chmod +x "$CZ_CASE/bin/$1"
}

cz_sandbox_new() {
    CZ_SEQ=$((CZ_SEQ + 1))
    CZ_CASE="$CZ_ROOT/case-$CZ_SEQ"
    mkdir -p "$CZ_CASE/bin" "$CZ_CASE/gh" "$CZ_CASE/home" "$CZ_CASE/state"
    CZ_STATE="$CZ_CASE/state"; CZ_RECEIPTS="$CZ_STATE/receipts"
    CZ_REPO="$CZ_CASE/repo"
    CZ_TICK=0; CZ_GIT_DATE="1767225600 +0000"
    cp "$CZ_GOLDEN/receipt.key" "$CZ_CASE/receipt.key"

    # gh: every answer is a file under $CZ_CASE_DIR/gh, named for the call and
    # holding what the real gh would print AFTER its own --jq filter. A call
    # with no file exits 99 and is logged, so a call nobody planned fails the
    # case instead of returning an empty string. Every argv is logged with %q
    # quoting, one call per line, so a case can assert the exact argument list.
    cat > "$CZ_CASE/bin/gh" <<'STUB'
#!/usr/bin/env bash
d="${CZ_CASE_DIR:?}/gh"
line=""
for a in "$@"; do line="$line$(printf '%q' "$a") "; done
printf '%s\n' "${line% }" >> "$d/calls"
json=""; prev=""
for a in "$@"; do [ "$prev" = "--json" ] && json="$a"; prev="$a"; done
case "${1:-} ${2:-}" in
    "auth switch") key="auth-switch" ;;
    "api user")    key="api-user" ;;
    "pr view")     key="pr-view.${json%%,*}" ;;
    "pr checks")   key="pr-checks" ;;
    "pr merge")    key="pr-merge" ;;
    "api --paginate") key="api-reviews" ;;
    "api -X")      key="api-put" ;;
    *)             key="" ;;
esac
if [ -z "$key" ] || { [ ! -e "$d/$key.out" ] && [ ! -e "$d/$key.rc" ]; }; then
    printf '%s\n' "${line% }" >> "$d/unplanned"
    echo "stub gh: unplanned call: $*" >&2
    exit 99
fi
[ -e "$d/$key.out" ] && cat "$d/$key.out"
[ -e "$d/$key.err" ] && cat "$d/$key.err" >&2
rc=0; [ -e "$d/$key.rc" ] && rc="$(cat "$d/$key.rc")"
exit "$rc"
STUB
    # flock: exits with the code in flock.rc (default 0) and logs its argv.
    # The merge lock is the only caller. A stub keeps the case independent of
    # the host's flock and lets a case say "the lock is held" without a second
    # process.
    cat > "$CZ_CASE/bin/flock" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CZ_CASE_DIR:?}/flock.calls"
rc=0; [ -e "${CZ_CASE_DIR:?}/flock.rc" ] && rc="$(cat "$CZ_CASE_DIR/flock.rc")"
exit "$rc"
STUB
    chmod +x "$CZ_CASE/bin/gh" "$CZ_CASE/bin/flock"
    local t
    for t in podman docker curl wget ssh; do cz_stub_tool "$t"; done
    for t in gh flock podman; do
        bash -n "$CZ_CASE/bin/$t" || { echo "characterization: stub $t does not parse" >&2; exit 2; }
    done
    : > "$CZ_CASE/gh/calls"

    CZ_E=()
    CZ_E[PATH]="$CZ_CASE/bin:$CZ_BASE_PATH"
    CZ_E[HOME]="$CZ_CASE/home"
    CZ_E[LC_ALL]=C
    CZ_E[TZ]=UTC
    CZ_E[LOGNAME]=fixture-user
    CZ_E[USER]=fixture-user
    CZ_E[GIT_CONFIG_NOSYSTEM]=1
    CZ_E[GIT_CONFIG_GLOBAL]=/dev/null
    CZ_E[GIT_TERMINAL_PROMPT]=0
    CZ_E[CZ_CASE_DIR]="$CZ_CASE"
    CZ_E[MAINTAINER_STATE]="$CZ_STATE"
    CZ_E[MAINTAINER_ACCOUNT]=testuser
    CZ_E[MAINTAINER_SLUG]=o/r
    CZ_E[MAINTAINER_REPO]="$CZ_REPO"
    CZ_E[MAINTAINER_RECEIPT_KEY]="$CZ_CASE/receipt.key"
    CZ_E[PROD_GLOBS]='crates/*/src/*'
}

cz_set()   { CZ_E["$1"]="$2"; }   # $1 = variable, $2 = value, for the program
cz_unset() { unset "CZ_E[$1]"; }

# --- running the program ------------------------------------------------------

# cz_mm ARGS...: runs bin/maintainer-merge in the case's environment. Sets
# CZ_RC and leaves the two streams in $CZ_CASE/stdout and $CZ_CASE/stderr,
# captured apart so a case can say which stream carried a message.
cz_mm() {
    local pairs=() k
    for k in "${!CZ_E[@]}"; do pairs+=("$k=${CZ_E[$k]}"); done
    env -i "${pairs[@]}" timeout 120 bash "$CZ_MM" "$@" \
        > "$CZ_CASE/stdout" 2> "$CZ_CASE/stderr" < /dev/null
    CZ_RC=$?
}

# --- gh stub data -------------------------------------------------------------

# cz_gh KEY TEXT [RC]: what the stub prints for the call KEY, and its exit code.
# Empty TEXT means the call prints nothing, which is not the same as no file.
cz_gh() {
    if [ -n "$2" ]; then printf '%s\n' "$2" > "$CZ_CASE/gh/$1.out"; else : > "$CZ_CASE/gh/$1.out"; fi
    printf '%s' "${3:-0}" > "$CZ_CASE/gh/$1.rc"
}

# cz_gh_baseline HEAD: a pull request that merges: approved, clean, one passing
# check, closing nothing, at head HEAD.
cz_gh_baseline() {
    cz_gh auth-switch ""
    cz_gh api-user "testuser"
    cz_gh pr-view.headRefOid "$1"
    cz_gh pr-view.mergeStateStatus CLEAN
    cz_gh pr-view.reviewDecision APPROVED
    cz_gh pr-view.closingIssuesReferences ""
    cz_gh pr-checks '[{"name":"rust","bucket":"pass"}]'
    cz_gh pr-merge "stub gh: pr merge ran"
}

# cz_argv ARGS...: one gh call as the stub logs it, for exact comparison.
cz_argv() {
    local a line=""
    for a in "$@"; do line="$line$(printf '%q' "$a") "; done
    printf '%s' "${line% }"
}

# --- fixture repository -------------------------------------------------------

cz_git() {
    env -i PATH="$CZ_BASE_PATH" HOME="$CZ_CASE/home" LC_ALL=C \
        GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
        GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
        GIT_AUTHOR_DATE="$CZ_GIT_DATE" GIT_COMMITTER_DATE="$CZ_GIT_DATE" \
        git -C "$CZ_REPO" "$@"
}

cz_repo_init() {
    mkdir -p "$CZ_REPO"
    cz_git init -q -b main || { echo "characterization: git init failed" >&2; exit 2; }
    cz_git remote add origin "$CZ_REPO"
}

cz_write() {  # $1 = path inside the repository, $2 = content
    mkdir -p "$(dirname "$CZ_REPO/$1")"
    printf '%s\n' "$2" > "$CZ_REPO/$1"
}

# cz_commit MESSAGE VARIABLE: commits everything and names the commit in VARIABLE.
# The commit date advances one second per commit, so the history is the same
# on every run.
cz_commit() {
    CZ_TICK=$((CZ_TICK + 1)); CZ_GIT_DATE="$((1767225600 + CZ_TICK)) +0000"
    cz_git add -A >/dev/null && cz_git commit -q -m "$1" \
        || { echo "characterization: git commit failed" >&2; exit 2; }
    printf -v "$2" '%s' "$(cz_git rev-parse HEAD)"
}

cz_pr_ref() { cz_git update-ref "refs/pull/$1/head" "$2"; }  # $1 = pr, $2 = sha

# cz_repo_basic: main with one commit holding a production file and a doc.
# Names the commit in CZ_C0.
cz_repo_basic() {
    cz_repo_init
    cz_write crates/x/src/lib.rs "fn main() {}"
    cz_write docs/a.md "hello"
    cz_commit base CZ_C0
}

# cz_merge_ready PR: a pull request that merges. The fixture repository, its
# pull ref, the baseline gh answers and an observed receipt, all at CZ_C0.
cz_merge_ready() {
    cz_repo_basic
    cz_pr_ref "$1" "$CZ_C0"
    cz_gh_baseline "$CZ_C0"
    cz_receipt "$1" "$CZ_C0" observed
}

# cz_lease PR HOLDER: a live lease on PR held by someone else. It expires in 2100.
cz_lease() {
    mkdir -p "$CZ_STATE/leases"
    printf '{"acquired": 4102444800, "holder": "%s", "kind": "run", "note": "", "pr": %s, "renewed": 4102444800, "ttl_seconds": 3600}\n' \
        "$2" "$1" > "$CZ_STATE/leases/pr-$1.json"
}

# --- receipts -----------------------------------------------------------------

# cz_receipt PR HEAD KIND [MODE]: writes $RECEIPTS/PR.json the way the gate
# writes one (json.dump, indent 2, HMAC-SHA256 over the unsigned bytes), signed
# with the case's key by code that is independent of the program. The golden
# known-answer cases prove this writer and the program agree, so a case that
# needs a receipt it cannot earn here (no container) can still have one.
# MODE: ok (default), no-signature, bad-signature, edited (changed after
# signing), not-json, or other-pr (the signed pr field names pull request 999).
cz_receipt() {
    mkdir -p "$CZ_RECEIPTS"
    python3 - "$CZ_RECEIPTS/$1.json" "$CZ_CASE/receipt.key" "$1" "$2" "$3" "${4:-ok}" <<'PYEOF' \
        || { echo "characterization: could not write a receipt fixture" >&2; exit 2; }
import hashlib, hmac, json, sys
out, key_path, pr, head, kind, mode = sys.argv[1:7]
d = {"pr": 999 if mode == "other-pr" else int(pr), "head": head, "kind": kind,
     "suite": "rust", "proof": "characterization fixture",
     "recorded_at": "2026-01-01T00:00:00+00:00", "recorded_by": "fixture-user"}
if mode == "not-json":
    open(out, "w").write("this is not json")
    sys.exit(0)
key = open(key_path).read().strip().encode()
sig = hmac.new(key, json.dumps(d, indent=2).encode(), hashlib.sha256).hexdigest()
if mode == "edited":
    d["head"] = "0" * 40
if mode != "no-signature":
    d["signature"] = ("0" * 64) if mode == "bad-signature" else sig
json.dump(d, open(out, "w"), indent=2)
PYEOF
}

# --- assertions ---------------------------------------------------------------

cz_check() {  # $1 = label, $2 = actual, $3 = expected
    [ "$2" = "$3" ] || cz_note_fail "$1: expected '$3', got '$2'"
}

cz_expect_rc() {  # $1 = the exit code, by value
    [ "$CZ_RC" = "$1" ] || cz_note_fail "exit code: expected $1, got $CZ_RC (stderr: $(tr '\n' ' ' < "$CZ_CASE/stderr" | cut -c1-200))"
}

# Compares a stream byte for byte with the lines given, each ended by a newline.
cz_expect_stream() {  # $1 = stdout|stderr, then the expected lines
    local which="$1"; shift
    local want="$CZ_CASE/want.$which"
    if [ "$#" -eq 0 ]; then : > "$want"; else printf '%s\n' "$@" > "$want"; fi
    if ! cmp -s "$want" "$CZ_CASE/$which"; then
        cz_note_fail "$which differs. expected: $(tr '\n' '|' < "$want" | cut -c1-240) got: $(tr '\n' '|' < "$CZ_CASE/$which" | cut -c1-240)"
    fi
}
cz_expect_stdout() { cz_expect_stream stdout "$@"; }
cz_expect_stderr() { cz_expect_stream stderr "$@"; }
cz_expect_stdout_empty() { cz_expect_stream stdout; }
cz_expect_stderr_empty() { cz_expect_stream stderr; }

cz_expect_has() {  # $1 = stdout|stderr, $2 = a fixed string
    local text; text="$(cat "$CZ_CASE/$1")"
    grep -qF -- "$2" <<<"$text" \
        || cz_note_fail "$1 lacks '$2': $(tr '\n' '|' <<<"$text" | cut -c1-240)"
}
cz_expect_lacks() {  # $1 = stdout|stderr, $2 = a fixed string
    local text; text="$(cat "$CZ_CASE/$1")"
    if grep -qF -- "$2" <<<"$text"; then
        cz_note_fail "$1 holds '$2' and must not: $(tr '\n' '|' <<<"$text" | cut -c1-240)"
    fi
}
cz_expect_stdout_has() { cz_expect_has stdout "$1"; }
cz_expect_stderr_has() { cz_expect_has stderr "$1"; }
cz_expect_matches() {  # $1 = stdout|stderr, $2 = an extended regular expression
    local text; text="$(cat "$CZ_CASE/$1")"
    grep -qE -- "$2" <<<"$text" \
        || cz_note_fail "$1 does not match /$2/: $(tr '\n' '|' <<<"$text" | cut -c1-240)"
}

# The whole gh call log, line for line. Each argument is one call, written with
# cz_argv.
cz_expect_gh_log() {
    local want="$CZ_CASE/want.gh"
    if [ "$#" -eq 0 ]; then : > "$want"; else printf '%s\n' "$@" > "$want"; fi
    cmp -s "$want" "$CZ_CASE/gh/calls" \
        || cz_note_fail "gh calls differ. expected: $(tr '\n' '|' < "$want" | cut -c1-300) got: $(tr '\n' '|' < "$CZ_CASE/gh/calls" | cut -c1-300)"
}
cz_gh_count() {  # $1 = a fixed string -> how many logged gh calls contain it
    local n; n="$(grep -cF -- "$1" "$CZ_CASE/gh/calls")"
    printf '%s' "${n:-0}"
}
cz_expect_gh_count() {  # $1 = a fixed string, $2 = how many calls hold it
    cz_check "gh calls containing '$1'" "$(cz_gh_count "$1")" "$2"
}

cz_expect_file() { [ -e "$1" ] || cz_note_fail "missing: $1"; }
cz_expect_no_file() { [ ! -e "$1" ] || cz_note_fail "exists and must not: $1"; }

# The first line of stderr. Most refusals are one `die`, whose first
# line is the whole decision; the lines after it only explain.
cz_expect_stderr_first() {  # $1 = the line
    cz_check "first stderr line" "$(head -1 "$CZ_CASE/stderr")" "$1"
}

# A refusal as the gate gives one: the exit code by value, nothing on stdout,
# the first stderr line, and no gh pr merge call.
cz_expect_refusal() {  # $1 = exit code, $2 = first stderr line
    cz_expect_rc "$1"
    cz_expect_stdout_empty
    cz_expect_stderr_first "$2"
    cz_expect_gh_count "pr merge" 0
}

cz_expect_gh_line() {  # $1 = one call written with cz_argv, which must appear in the log
    grep -qxF -- "$1" "$CZ_CASE/gh/calls" \
        || cz_note_fail "gh was never called as: $1 (calls: $(tr '\n' '|' < "$CZ_CASE/gh/calls" | cut -c1-300))"
}
