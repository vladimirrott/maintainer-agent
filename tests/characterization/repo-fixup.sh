#!/usr/bin/env bash
# Characterization: `maintainer-repo fixup <pr> [--dry-run]`. The command line,
# every refusal (each is a `die`, exit 1, one line on stderr), the heads-up
# comment path, and the push path: a scratch clone of the contributor's branch,
# an optional rebase, a patch, a commit credited to the author, a push, and the
# read-back from the pull request.
#
# fixup asks `maintainer fixup-check` for every decision. That program is a
# separate Python tool with its own tests; here a fake one, placed beside a copy
# of maintainer-repo, answers with the key=value lines the real one prints. The
# clone and push URLs (https://github.com/<fork>.git) are redirected by git's
# url.<base>.insteadOf to bare repositories in the case directory, so git runs
# for real and nothing reaches the network. Commit dates are fixed through the
# environment.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib-dr.sh"
dr_init

USAGE='usage: maintainer-repo fixup <pr> [--dry-run]'
ACCT_ARGV="$(cz_argv auth switch --hostname github.com --user testuser)"
ME_ARGV="$(cz_argv api user --jq '[.id,.login]|@tsv')"
AUTHOR_ARGV="$(cz_argv api users/bob --jq '[.id,.login]|@tsv')"
VIEW_ARGV="$(cz_argv pr view 7 --repo o/r --json headRefOid --jq .headRefOid)"
MARKER='<!-- maintainer-fixup-notice -->'
COMMITTER='testuser <42+testuser@users.noreply.github.com>'
COMMITTER_RE='testuser <42\+testuser@users\.noreply\.github\.com>'

PATCH_TYPO=$'diff --git a/docs.md b/docs.md\n--- a/docs.md\n+++ b/docs.md\n@@ -1 +1,2 @@\n one\n+two'
PATCH_COUNT3=$'diff --git a/docs.md b/docs.md\n--- a/docs.md\n+++ b/docs.md\n@@ -1 +1,2 @@\n one\n+there are 3 tests'
PATCH_COUNT13=$'diff --git a/docs.md b/docs.md\n--- a/docs.md\n+++ b/docs.md\n@@ -1 +1,2 @@\n one\n+there are 13 tests'

# --- the fixture -------------------------------------------------------------------

# fx_up [SIGNED]: the tree copy with a fake fixup-check, the base repository o/r
# and the contributor's fork alice/r on branch fix-1 (one commit, FX_F1 on top
# of FX_B0), the git redirection, the gh answers of a clean run, and an answer
# from fixup-check for items typo:docs.md. With SIGNED the branch's commit
# carries a Signed-off-by line.
fx_up() {
    dr_tree profile.sh defaults.env
    cat > "$CZ_CASE/tree/bin/maintainer" <<'PY'
#!/usr/bin/env python3
import os, sys
d = os.environ["CZ_CASE_DIR"]
log = d + "/calls/fixup-check"
with open(log, "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
n = len(open(log).read().splitlines())
name = "fixup-check.out"
if n > 1 and os.path.exists(d + "/ans/fixup-check.again.out"):
    name = "fixup-check.again.out"
if os.path.exists(d + "/ans/fixup-check.err"):
    sys.stderr.write(open(d + "/ans/fixup-check.err").read())
sys.stdout.write(open(d + "/ans/" + name).read())
sys.exit(int(open(d + "/ans/fixup-check.rc").read()) if os.path.exists(d + "/ans/fixup-check.rc") else 0)
PY
    python3 -m py_compile "$CZ_CASE/tree/bin/maintainer" || { echo "characterization: fake fixup-check does not compile" >&2; exit 2; }
    rm -rf "$CZ_CASE/tree/bin/__pycache__"
    : > "$CZ_CASE/calls/fixup-check"

    # The repositories. CZ_REPO is the scratch work tree used to build them.
    FX_REMOTES="$CZ_CASE/remotes"
    mkdir -p "$FX_REMOTES/o" "$FX_REMOTES/alice"
    local r
    for r in "$FX_REMOTES/o/r.git" "$FX_REMOTES/alice/r.git"; do
        env -i PATH="$CZ_BASE_PATH" HOME="$CZ_CASE/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
            git init -q --bare -b main "$r" || exit 2
    done
    cz_repo_init
    cz_write README.md "base"
    cz_commit base FX_B0
    cz_git push -q "$FX_REMOTES/o/r.git" main || exit 2
    cz_git push -q "$FX_REMOTES/alice/r.git" main || exit 2
    cz_git checkout -q -b fix-1
    cz_write docs.md "one"
    if [ "${1:-}" = SIGNED ]; then cz_commit $'docs: add one\n\nSigned-off-by: Bob <bob@example.invalid>' FX_F1; else cz_commit "docs: add one" FX_F1; fi
    cz_git push -q "$FX_REMOTES/alice/r.git" fix-1 || exit 2
    cz_git checkout -q main
    FX_F1S="$(cz_git rev-parse --short "$FX_F1")"
    FX_FORK="$FX_REMOTES/alice/r.git"
    FX_BASE="$FX_REMOTES/o/r.git"

    dr_repo_env
    CZ_E[MAINTAINER_GH_BACKOFF]=0
    CZ_E[GIT_CONFIG_COUNT]=1
    CZ_E[GIT_CONFIG_KEY_0]="url.$FX_REMOTES/.insteadOf"
    CZ_E[GIT_CONFIG_VALUE_0]="https://github.com/"
    CZ_E[GIT_AUTHOR_DATE]="1767225700 +0000"
    CZ_E[GIT_COMMITTER_DATE]="1767225700 +0000"

    cz_gh auth-switch ""
    cz_gh api-user "$(printf '42\ttestuser')"
    cz_gh api-author "$(printf '7\tbob')"
    printf '%s refs/heads/fix-1\n' "$FX_FORK" > "$CZ_CASE/gh/pr-view.7.fromgit"
    printf "%s\n" "$PATCH_TYPO" > "$CZ_CASE/fix.patch"
    fx_check ready "typo:docs.md"
}

# fx_check STATE ITEMS [PATCH]: what fixup-check answers. KEY=VALUE words after
# these replace a line, or drop it when the value is empty.
fx_check() {
    local -A f=( [state]="$1" [head]="$FX_F1" [base]=main [branch]=fix-1 [fork]=alice/r [author]=bob
                 [items]="$2" [patch]="${3:-$CZ_CASE/fix.patch}" [notice_marker]="$MARKER"
                 [notice_due]=2026-11-20 [notice_days]=5 [review_age]=12 )
    shift 2; [ "$#" -gt 0 ] && shift
    local kv
    for kv in "$@"; do f["${kv%%=*}"]="${kv#*=}"; done
    local k out=""
    for k in state head base branch fork author items patch notice_marker notice_due notice_days review_age; do
        [ -n "${f[$k]}" ] && out="$out$k=${f[$k]}"$'\n'
    done
    printf '%s' "$out" > "$CZ_CASE/ans/fixup-check.out"
    printf '0' > "$CZ_CASE/ans/fixup-check.rc"
}

fx() { dr_run "$CZ_CASE/tree/bin/maintainer-repo" fixup "$@"; }
fx_count() { find "$CZ_STATE" -maxdepth 1 -name "$1" | wc -l | tr -d ' '; }   # entries of the state directory matching a name
fx_no_scratch() { cz_check "scratch directories left in the state directory" "$(fx_count 'fixup-*')" "0"; }
fx_fork_head() { cz_git --git-dir="$FX_FORK" rev-parse refs/heads/fix-1; }

# fx_die CODE MESSAGE: the refusal as it appears: exit 1, nothing on stdout, one
# line on stderr, and no scratch directory left over.
fx_die() {
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr "maintainer-repo: $1"
    fx_no_scratch
}

# --- the command line --------------------------------------------------------------------

case_usage_none() {
    fx_up
    fx
    cz_expect_rc 64
    cz_expect_stdout_empty
    cz_expect_stderr "$USAGE"
    cz_expect_gh_log
    dr_expect_calls fixup-check
}
dr_case "usage: fixup with no argument prints the usage line and exits 64, before any gh call" case_usage_none

USAGE_WORD=""
case_usage_word() {
    fx_up
    fx "$USAGE_WORD"
    cz_expect_rc 64
    cz_expect_stdout_empty
    cz_expect_stderr "$USAGE"
    cz_expect_gh_log
    dr_expect_calls fixup-check
}
for USAGE_WORD in abc 12x -7 1.5 ""; do
    dr_case "usage: the pull request '$USAGE_WORD' is not all digits, so the usage line prints and the exit code is 64" case_usage_word
done

case_usage_flag_only() {
    fx_up
    fx --dry-run
    cz_expect_rc 64
    cz_expect_stderr "$USAGE"
}
dr_case "usage: --dry-run with no pull request number is the usage error" case_usage_flag_only

case_usage_bad_after_good() {
    fx_up
    fx 7 abc
    cz_expect_rc 64
    cz_expect_stderr "$USAGE"
    dr_expect_calls fixup-check
}
dr_case "usage: a non-numeric word after a good number cancels it, so '7 abc' is the usage error" case_usage_bad_after_good

# Pins current behaviour: with two numbers the last one wins.
case_usage_last_number() {
    fx_up
    fx 8 7 --dry-run
    cz_expect_rc 0
    dr_expect_calls fixup-check "fixup-check 7"
}
dr_case "usage: with two numbers the last one is the pull request (pins current behaviour)" case_usage_last_number

# --- fixup-check and the account ------------------------------------------------------------------

case_check_fails() {
    fx_up
    printf '3' > "$CZ_CASE/ans/fixup-check.rc"
    printf 'refused: not ripe\n' > "$CZ_CASE/ans/fixup-check.err"
    fx 7
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr "refused: not ripe"
    cz_expect_gh_log
    dr_expect_calls fixup-check "fixup-check 7"
}
dr_case "check: a failing fixup-check ends the run with exit 1, its stderr passed through, and no gh call" case_check_fails

case_check_incomplete() {
    fx_up
    fx_check ready "typo:docs.md" "" branch=
    fx 7
    fx_die "fixup-check answered without a state, head, branch, fork or items; refusing to act on that"
    cz_expect_gh_log
}
dr_case "check: an answer with no branch is refused with a one-line message and no gh call" case_check_incomplete

case_check_no_fork() {
    fx_up
    fx_check ready "typo:docs.md" "" fork=
    fx 7
    fx_die "fixup-check answered without a state, head, branch, fork or items; refusing to act on that"
}
dr_case "check: an answer with no fork is refused" case_check_no_fork

case_check_no_state() {
    fx_up
    fx_check "" "typo:docs.md"
    fx 7
    fx_die "fixup-check answered without a state, head, branch, fork or items; refusing to act on that"
}
dr_case "check: an answer with no state is refused" case_check_no_state

case_check_no_head() {
    fx_up
    fx_check ready "typo:docs.md" "" head=
    fx 7
    fx_die "fixup-check answered without a state, head, branch, fork or items; refusing to act on that"
}
dr_case "check: an answer with no head is refused" case_check_no_head

case_check_no_items() {
    fx_up
    fx_check ready "" 
    fx 7
    fx_die "fixup-check answered without a state, head, branch, fork or items; refusing to act on that"
}
dr_case "check: an answer with no items is refused the same way" case_check_no_items

case_acct_api_fails() {
    fx_up
    cz_gh api-user "" 1
    fx 7
    fx_die "gh could not confirm an account"
    cz_expect_gh_log "$ACCT_ARGV" "$ME_ARGV"
}
dr_case "account: a failing gh api user is 'could not confirm an account'; auth switch was tried first" case_acct_api_fails

case_acct_non_numeric() {
    fx_up
    cz_gh api-user "$(printf 'abc\ttestuser')"
    fx 7
    fx_die "gh did not return a numeric account id"
}
dr_case "account: a non-numeric account id is refused" case_acct_non_numeric

case_acct_empty_id() {
    fx_up
    cz_gh api-user "$(printf '\ttestuser')"
    fx 7
    fx_die "gh did not return a numeric account id"
}
dr_case "account: an empty account id is refused" case_acct_empty_id

case_acct_wrong() {
    fx_up
    cz_gh api-user "$(printf '42\tsomeoneelse')"
    fx 7
    fx_die "gh is authenticated as 'someoneelse', not testuser"
}
dr_case "account: a different login is refused, naming both" case_acct_wrong

case_acct_case() {
    fx_up
    cz_gh api-user "$(printf '42\tTestUser')"
    fx 7 --dry-run
    cz_expect_rc 0
    cz_expect_stdout_has "as TestUser <42+TestUser@users.noreply.github.com>"
}
dr_case "account: the login match ignores case and the commit identity uses gh's spelling" case_acct_case

case_acct_switch_fails() {
    fx_up
    cz_gh auth-switch "" 1
    fx 7 --dry-run
    cz_expect_rc 0
}
dr_case "account: a failing gh auth switch is ignored when gh api user answers" case_acct_switch_fails

# --- the heads-up comment --------------------------------------------------------------------------

BODY_LINES=(
    "This has had no reply for 12 days since my review, and what is left is mechanical (typo, test-count)."
    ""
    "I will push a fixup for it to your branch after 2026-11-20 unless you push first. Your commits stay yours, and I will credit you on anything I add. If you would rather do it yourself, push or reply and I will leave it alone."
    ""
    "$MARKER"
)
body_text() { printf '%s\n' "${BODY_LINES[@]}"; }

notice_up() { fx_up; fx_check notice "typo:docs.md test-count:docs.md"; }

case_notice_dry() {
    notice_up
    fx 7 --dry-run
    cz_expect_rc 0
    cz_expect_stdout \
        "  would post this heads-up on #7 (ripe after 2026-11-20, 5 days):" \
        "    ${BODY_LINES[0]}" \
        "    " \
        "    ${BODY_LINES[2]}" \
        "    " \
        "    ${BODY_LINES[4]}"
    cz_expect_stderr_empty
    cz_expect_gh_count "pr comment" 0
    dr_expect_calls fixup-check "fixup-check 7"
}
dr_case "notice: --dry-run prints the heads-up body indented, with the ripe date and the days, and posts nothing" case_notice_dry

case_notice_post_off() {
    notice_up
    cz_set MAINTAINER_POST off
    fx 7
    cz_expect_rc 0
    cz_expect_stdout_has "  POST=off: rehearsing, nothing will be posted or pushed"
    cz_expect_stdout_has "  would post this heads-up on #7 (ripe after 2026-11-20, 5 days):"
    cz_expect_gh_count "pr comment" 0
    cz_check "first stdout line" "$(head -1 "$CZ_CASE/stdout")" "  POST=off: rehearsing, nothing will be posted or pushed"
}
dr_case "notice: MAINTAINER_POST=off makes a real run a rehearsal, with the POST=off line first" case_notice_post_off

case_notice_post() {
    notice_up
    printf '%s\n' "state=ready" > "$CZ_CASE/ans/fixup-check.again.out"
    cz_gh pr-comment "" 0
    fx 7
    cz_expect_rc 0
    cz_expect_stdout "  posted the heads-up on #7; a fixup may follow after 2026-11-20"
    cz_expect_stderr_empty
    local got; got="$(sed -n 's#fixup-notice\.[A-Za-z0-9]*#fixup-notice.X#; 3p' "$CZ_CASE/gh/calls")"
    cz_check "the pr comment call" "$got" "$(cz_argv pr comment 7 --repo o/r --body-file "$CZ_STATE/fixup-notice.X")"
    printf '%s' "$(body_text)" > "$CZ_CASE/want.body"
    cmp -s "$CZ_CASE/want.body" "$CZ_CASE/gh/comment-body" || cz_note_fail "the posted body differs: $(tr '\n' '|' < "$CZ_CASE/gh/comment-body" | cut -c1-200)"
    cz_check "gh calls" "$(wc -l < "$CZ_CASE/gh/calls")" "3"
    dr_expect_calls fixup-check "fixup-check 7" "fixup-check 7"
    fx_no_scratch
    cz_check "notice files left in the state directory" "$(fx_count 'fixup-notice*')" "0"
}
dr_case "notice: a real run posts the body without a trailing newline through a temp file, asks fixup-check again, and removes the file" case_notice_post

case_notice_readback_not_ripe() {
    notice_up
    printf 'state=skip\nreason=heads-up is not ripe yet\n' > "$CZ_CASE/ans/fixup-check.again.out"
    cz_gh pr-comment "" 0
    fx 7
    cz_expect_rc 0
    cz_expect_stdout "  posted the heads-up on #7; a fixup may follow after 2026-11-20"
}
dr_case "notice: a read-back that says 'heads-up is not ripe' confirms the post" case_notice_readback_not_ripe

case_notice_post_fails() {
    notice_up
    cz_gh pr-comment "" 1
    fx 7
    fx_die "could not post the heads-up on #7"
    cz_check "notice files left in the state directory" "$(fx_count 'fixup-notice*')" "0"
}
dr_case "notice: a failing gh pr comment is 'could not post the heads-up' and the temp file is removed" case_notice_post_fails

case_notice_unread() {
    notice_up
    printf 'state=notice\n' > "$CZ_CASE/ans/fixup-check.again.out"
    cz_gh pr-comment "" 0
    fx 7
    fx_die "posted the heads-up but could not read it back on #7, so I cannot say the author was told"
}
dr_case "notice: a read-back that still says 'notice' is refused, so the author is not reported as told" case_notice_unread

# --- the fixup itself: refusals before a push ------------------------------------------------------------

case_clone_fails() {
    fx_up
    fx_check ready "typo:docs.md" "" fork=nobody/none
    fx 7
    fx_die "could not clone nobody/none fix-1"
}
dr_case "fixup: a fork that cannot be cloned is 'could not clone <fork> <branch>'" case_clone_fails

case_moved() {
    fx_up
    fx_check ready "typo:docs.md" "" head=0123456789012345678901234567890123456789
    fx 7
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr "maintainer-repo: fix-1 has moved since the check (now $FX_F1S, checked 0123456789012345678901234567890123456789); nothing was pushed"
    fx_no_scratch
}
dr_case "fixup: a branch whose head is not the checked head is refused with both hashes" case_moved

case_no_patch() {
    fx_up
    fx_check ready "typo:docs.md" "" patch=
    fx 7
    fx_die "no patch for: typo"
}
dr_case "fixup: a mechanical item with no patch is refused, naming the kind" case_no_patch

case_patch_file_missing() {
    fx_up
    fx_check ready "typo:docs.md" "" patch="$CZ_CASE/nowhere.patch"
    fx 7
    fx_die "no patch for: typo"
}
dr_case "fixup: a patch path that is not a file is refused the same way" case_patch_file_missing

case_patch_not_applying() {
    fx_up
    printf '%s' $'diff --git a/docs.md b/docs.md\n--- a/docs.md\n+++ b/docs.md\n@@ -1 +1,2 @@\n nothing\n+two' > "$CZ_CASE/fix.patch"
    fx 7
    fx_die "the patch does not apply to fix-1 after any rebase; nothing was pushed"
    cz_check "fork head" "$(fx_fork_head)" "$FX_F1"
}
dr_case "fixup: a patch that does not apply is refused and the fork is untouched" case_patch_not_applying

case_nothing_changes() {
    fx_up
    fx_check ready "rebase"
    fx 7
    fx_die "the fixup would change nothing on fix-1"
}
dr_case "fixup: a rebase of a branch already on the base changes nothing and is refused" case_nothing_changes

case_base_fetch_fails() {
    fx_up
    rm -rf "$FX_BASE"
    fx_check ready "rebase"
    fx 7
    fx_die "could not fetch main from o/r"
}
dr_case "fixup: a base repository that cannot be fetched is 'could not fetch <base> from <slug>'" case_base_fetch_fails

fx_base_moves() {  # $1 = file, $2 = content: a new commit on the base's main
    cz_git checkout -q main
    cz_write "$1" "$2"; cz_commit "base moves" FX_B1
    cz_git push -q "$FX_BASE" main || exit 2
}

case_rebase_conflict() {
    fx_up
    fx_base_moves docs.md "zero"
    fx_check ready "rebase"
    fx 7
    fx_die "the rebase onto main conflicts. Resolving conflicts is not automated; nothing was pushed"
    cz_check "fork head" "$(fx_fork_head)" "$FX_F1"
}
dr_case "fixup: a conflicting rebase is refused as not automated and the fork is untouched" case_rebase_conflict

# --- the test count -------------------------------------------------------------------------------------------

case_count_no_cmd() {
    fx_up
    printf "%s\n" "$PATCH_COUNT3" > "$CZ_CASE/fix.patch"
    fx_check ready "test-count:docs.md"
    fx 7
    fx_die "this profile declares no FIXUP_COUNT_CMD, so a test count would be typed rather than derived"
}
dr_case "test-count: with no FIXUP_COUNT_CMD the item is refused" case_count_no_cmd

case_count_not_number() {
    fx_up
    printf "%s\n" "$PATCH_COUNT3" > "$CZ_CASE/fix.patch"
    fx_check ready "test-count:docs.md"
    cz_set FIXUP_COUNT_CMD 'echo many'
    fx 7
    fx_die "FIXUP_COUNT_CMD did not print a whole number, so no count could be derived"
}
dr_case "test-count: a count command that does not print a whole number is refused" case_count_not_number

case_count_mismatch() {
    fx_up
    printf "%s\n" "$PATCH_COUNT13" > "$CZ_CASE/fix.patch"
    fx_check ready "test-count:docs.md"
    cz_set FIXUP_COUNT_CMD 'echo 3'
    fx 7
    fx_die "the patch does not state 3, the count FIXUP_COUNT_CMD derives; a typed count is refused"
}
dr_case "test-count: a patch stating 13 when the command derives 3 is refused (whole-number match)" case_count_mismatch

case_count_ok() {
    fx_up
    printf "%s\n" "$PATCH_COUNT3" > "$CZ_CASE/fix.patch"
    fx_check ready "test-count:docs.md"
    cz_set FIXUP_COUNT_CMD 'printf " 3 \n"'
    fx 7 --dry-run
    cz_expect_rc 0
    cz_expect_stdout_has "  plan: test-count:docs.md on alice/r fix-1, $FX_F1S -> "
    cz_expect_stdout_has "    fixup: test-count from the review"
}
dr_case "test-count: a patch that states the derived count passes, and the commit names the kind" case_count_ok

# --- scratch space and the commit ---------------------------------------------------------

case_no_scratch_dir() {
    fx_up
    cz_set MAINTAINER_STATE "$CZ_CASE/no-such-state-dir"
    fx 7
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_check "last stderr line" "$(tail -1 "$CZ_CASE/stderr")" "maintainer-repo: no scratch directory"
    cz_expect_gh_count "pr view" 0
}
dr_case "fixup: a state directory that cannot hold the scratch clone is 'no scratch directory', before any clone or push" case_no_scratch_dir

case_no_scratch_file() {
    notice_up
    cz_set MAINTAINER_STATE "$CZ_CASE/no-such-state-dir"
    fx 7
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_check "last stderr line" "$(tail -1 "$CZ_CASE/stderr")" "maintainer-repo: no scratch file"
    cz_expect_gh_count "pr comment" 0
}
dr_case "notice: a state directory that cannot hold the body file is 'no scratch file', before anything is posted" case_no_scratch_file

case_commit_fails() {
    fx_up
    CZ_E[GIT_CONFIG_COUNT]=2
    CZ_E[GIT_CONFIG_KEY_1]=commit.cleanup
    CZ_E[GIT_CONFIG_VALUE_1]=bogus
    fx 7
    fx_die "could not commit the patch"
    cz_check "fork head" "$(fx_fork_head)" "$FX_F1"
}
dr_case "fixup: a commit that git refuses is 'could not commit the patch' and the fork is untouched" case_commit_fails

# --- the author lookup -------------------------------------------------------------------------------------------

case_author_fails() {
    fx_up
    cz_gh api-author "" 1
    fx 7
    fx_die "could not look up bob"
    cz_expect_gh_line "$AUTHOR_ARGV"
}
dr_case "author: a failing user lookup is 'could not look up <author>'" case_author_fails

case_author_non_numeric() {
    fx_up
    cz_gh api-author "$(printf 'xx\tbob')"
    fx 7
    fx_die "gh did not return a numeric id for bob"
}
dr_case "author: a non-numeric author id is refused" case_author_non_numeric

case_author_other() {
    fx_up
    cz_gh api-author "$(printf '7\trobert')"
    fx 7
    fx_die "the API answered for 'robert', not bob"
}
dr_case "author: a login that differs from the author is refused, naming both" case_author_other

# --- the plan, the rehearsal and the push ------------------------------------------------------------------------------

case_dry_plan() {
    fx_up
    fx 7 --dry-run
    cz_expect_rc 0
    cz_expect_stdout_has "  plan: typo:docs.md on alice/r fix-1, $FX_F1S -> "
    cz_expect_matches stdout "^  plan: typo:docs\\.md on alice/r fix-1, $FX_F1S -> [0-9a-f]{7,}, as $COMMITTER_RE\$"
    cz_expect_stdout_has "    fixup: typo from the review"
    cz_expect_stdout_has "    Co-authored-by: bob <7+bob@users.noreply.github.com>"
    cz_expect_stdout_has "    +two"
    cz_expect_stdout_has "  rehearsal: nothing was pushed"
    cz_expect_lacks stdout "would be rewritten"
    cz_expect_lacks stdout "Signed-off-by"
    cz_check "fork head" "$(fx_fork_head)" "$FX_F1"
    cz_expect_gh_log "$ACCT_ARGV" "$ME_ARGV" "$AUTHOR_ARGV"
    fx_no_scratch
}
dr_case "fixup: --dry-run prints the plan, the commit and its patch indented, 'rehearsal: nothing was pushed', and leaves the fork alone" case_dry_plan

case_dry_post_off() {
    fx_up
    cz_set MAINTAINER_POST off
    fx 7
    cz_expect_rc 0
    cz_check "first stdout line" "$(head -1 "$CZ_CASE/stdout")" "  POST=off: rehearsing, nothing will be posted or pushed"
    cz_expect_stdout_has "  rehearsal: nothing was pushed"
    cz_check "fork head" "$(fx_fork_head)" "$FX_F1"
    cz_expect_gh_count "pr view" 0
}
dr_case "fixup: MAINTAINER_POST=off turns a real run into a rehearsal with the POST=off line first" case_dry_post_off

case_signoff() {
    fx_up SIGNED
    fx 7 --dry-run
    cz_expect_rc 0
    cz_expect_stdout_has "    Signed-off-by: testuser <42+testuser@users.noreply.github.com>"
}
dr_case "fixup: when the branch's commits carry Signed-off-by the fixup commit is signed off by the account" case_signoff

case_no_signoff() {
    fx_up
    fx 7 --dry-run
    cz_expect_lacks stdout "Signed-off-by"
}
dr_case "fixup: without Signed-off-by on the branch the fixup commit has none" case_no_signoff

case_kinds_sorted() {
    fx_up
    fx_check ready "typo:docs.md docs:docs.md typo:other"
    fx 7 --dry-run
    cz_expect_rc 0
    cz_expect_stdout_has "  plan: typo:docs.md docs:docs.md typo:other on alice/r fix-1, $FX_F1S -> "
    cz_expect_stdout_has "    fixup: docs, typo from the review"
}
dr_case "fixup: the commit subject lists the distinct kinds, sorted, joined with commas" case_kinds_sorted

case_push() {
    fx_up
    fx 7
    cz_expect_rc 0
    local new; new="$(fx_fork_head)"
    cz_expect_stdout_has "  plan: typo:docs.md on alice/r fix-1, $FX_F1S -> ${new:0:7}, as $COMMITTER"
    cz_expect_stdout_has "  fixup pushed to alice/r fix-1; #7 is now at $new (read back from GitHub)"
    cz_expect_stderr_empty
    [ "$new" != "$FX_F1" ] || cz_note_fail "the fork branch did not move"
    cz_check "parent of the pushed commit" "$(cz_git --git-dir="$FX_FORK" rev-parse "$new^")" "$FX_F1"
    cz_check "author and committer" "$(cz_git --git-dir="$FX_FORK" log -1 --format='%an <%ae>|%cn <%ce>' "$new")" "$COMMITTER|$COMMITTER"
    cz_check "message" "$(cz_git --git-dir="$FX_FORK" log -1 --format=%B "$new")" "fixup: typo from the review

Co-authored-by: bob <7+bob@users.noreply.github.com>"
    cz_check "docs.md on the fork" "$(cz_git --git-dir="$FX_FORK" show "$new:docs.md" | tr '\n' ' ')" "one two "
    cz_expect_gh_log "$ACCT_ARGV" "$ME_ARGV" "$AUTHOR_ARGV" "$VIEW_ARGV"
    fx_no_scratch
}
dr_case "fixup: a real run adds one commit to the fork, credits the author, reads the head back once, and says so" case_push

case_push_rebase() {
    fx_up
    fx_base_moves README.md "base moved"
    fx_check ready "rebase typo:docs.md"
    fx 7
    cz_expect_rc 0
    local new; new="$(fx_fork_head)"
    cz_expect_stdout_has "  fixup pushed to alice/r fix-1; #7 is now at $new (read back from GitHub)"
    cz_check "the base commit is an ancestor" "$(cz_git --git-dir="$FX_FORK" merge-base --is-ancestor "$FX_B1" "$new" && echo yes)" "yes"
    cz_check "the old head is not an ancestor" "$(cz_git --git-dir="$FX_FORK" merge-base --is-ancestor "$FX_F1" "$new" && echo yes || echo no)" "no"
    cz_check "message" "$(cz_git --git-dir="$FX_FORK" log -1 --format=%s "$new")" "fixup: typo from the review"
}
dr_case "fixup: a rebase plus a patch rewrites the branch on top of the base and pushes with a lease" case_push_rebase

case_dry_rebase() {
    fx_up
    fx_base_moves README.md "base moved"
    fx_check ready "rebase"
    fx 7 --dry-run
    cz_expect_rc 0
    cz_expect_stdout_has "  plan: rebase on alice/r fix-1, $FX_F1S -> "
    cz_expect_stdout_has "  the branch would be rewritten (force-with-lease against $FX_F1)"
    cz_expect_stdout_has "  rehearsal: nothing was pushed"
    cz_check "fork head" "$(fx_fork_head)" "$FX_F1"
    cz_expect_gh_log "$ACCT_ARGV" "$ME_ARGV"
}
dr_case "fixup: a rebase rehearsal says the branch would be rewritten with a lease against the checked head, and asks gh for no author" case_dry_rebase

case_trailer_spelling() {
    fx_up
    cz_gh api-author "$(printf '7\tBob')"
    fx 7 --dry-run
    cz_expect_rc 0
    cz_expect_stdout_has "    Co-authored-by: Bob <7+Bob@users.noreply.github.com>"
}
dr_case "fixup: the Co-authored-by trailer uses the login as GitHub spells it, not as fixup-check named the author" case_trailer_spelling

# The contributor's branch is untrusted text. Hooks that git would run from a
# template directory (post-checkout on clone, pre-commit and commit-msg on commit,
# pre-push on push), a core.fsmonitor command and commit.gpgsign=true in the
# environment must change nothing.
case_hooks_inert() {
    fx_up
    local t="$CZ_CASE/template" h
    mkdir -p "$t/hooks"
    for h in post-checkout pre-commit commit-msg pre-push reference-transaction; do
        printf '#!/bin/sh\necho %s >> "%s/hook-ran"\nexit 0\n' "$h" "$CZ_CASE" > "$t/hooks/$h"
        chmod +x "$t/hooks/$h"
    done
    printf '#!/bin/sh\necho fsmonitor >> "%s/hook-ran"\nexit 0\n' "$CZ_CASE" > "$CZ_CASE/fsmonitor.sh"
    chmod +x "$CZ_CASE/fsmonitor.sh"
    CZ_E[GIT_TEMPLATE_DIR]="$t"
    CZ_E[GIT_CONFIG_COUNT]=3
    CZ_E[GIT_CONFIG_KEY_1]=commit.gpgsign
    CZ_E[GIT_CONFIG_VALUE_1]=true
    CZ_E[GIT_CONFIG_KEY_2]=core.fsmonitor
    # shellcheck disable=SC2034  # CZ_E is read by dr_run
    CZ_E[GIT_CONFIG_VALUE_2]="$CZ_CASE/fsmonitor.sh"
    fx 7
    cz_expect_rc 0
    cz_expect_stdout_has "  fixup pushed to alice/r fix-1; #7 is now at $(fx_fork_head) (read back from GitHub)"
    cz_expect_no_file "$CZ_CASE/hook-ran"
    cz_check "message" "$(cz_git --git-dir="$FX_FORK" log -1 --format=%s refs/heads/fix-1)" "fixup: typo from the review"
}
dr_case "fixup: template hooks, an fsmonitor command and a signing setting in the environment do not run on the scratch clone (core.hooksPath=/dev/null, gpgsign=false)" case_hooks_inert

# A second writer moves the contributor's branch after the clone and before the
# push. gh's answer for the author lookup, which happens in between, is the moment.
fx_second_writer() {  # moves fork fix-1 to a commit the clone has never seen
    cz_git checkout -q -b other "$FX_F1"
    cz_write other.txt "somebody else"
    cz_commit "second writer" FX_F2
    cz_git push -q "$FX_FORK" other || exit 2
    cz_git checkout -q main
    printf '#!/bin/bash\ngit --git-dir=%s update-ref refs/heads/fix-1 %s\n' "$FX_FORK" "$FX_F2" > "$CZ_CASE/gh/api-author.run"
}

case_race_plain() {
    fx_up
    fx_second_writer
    fx 7
    cz_expect_rc 1
    cz_expect_stderr "maintainer-repo: the push was refused (the branch moved); nothing was overwritten"
    cz_check "fork head" "$(fx_fork_head)" "$FX_F2"
    fx_no_scratch
}
dr_case "fixup: a branch that moved after the clone makes the plain push fail and the other writer's commit stays" case_race_plain

case_race_lease() {
    fx_up
    fx_base_moves README.md "base moved"
    fx_check ready "rebase typo:docs.md"
    fx_second_writer
    fx 7
    cz_expect_rc 1
    cz_expect_stderr "maintainer-repo: the push was refused (the branch moved, or the lease failed); nothing was overwritten"
    cz_check "fork head" "$(fx_fork_head)" "$FX_F2"
    fx_no_scratch
}
dr_case "fixup: a branch that moved after the clone makes the leased push fail and the other writer's commit stays" case_race_lease

case_push_refused() {
    fx_up
    cat > "$FX_FORK/hooks/pre-receive" <<'HOOK'
#!/bin/sh
exit 1
HOOK
    chmod +x "$FX_FORK/hooks/pre-receive"
    fx 7
    cz_expect_rc 1
    cz_expect_stderr "maintainer-repo: the push was refused (the branch moved); nothing was overwritten"
    cz_expect_matches stdout "^  plan: typo:docs\\.md on alice/r fix-1, $FX_F1S -> [0-9a-f]{7,}, as $COMMITTER_RE\$"
    fx_no_scratch
    cz_check "fork head" "$(fx_fork_head)" "$FX_F1"
}
dr_case "fixup: a push the remote rejects is 'the push was refused (the branch moved)'" case_push_refused

case_push_refused_rewrite() {
    fx_up
    fx_base_moves README.md "base moved"
    fx_check ready "rebase"
    cat > "$FX_FORK/hooks/pre-receive" <<'HOOK'
#!/bin/sh
exit 1
HOOK
    chmod +x "$FX_FORK/hooks/pre-receive"
    fx 7
    cz_expect_rc 1
    cz_expect_stderr "maintainer-repo: the push was refused (the branch moved, or the lease failed); nothing was overwritten"
    cz_expect_stdout_has "  plan: rebase on alice/r fix-1, $FX_F1S -> "
    fx_no_scratch
    cz_check "fork head" "$(fx_fork_head)" "$FX_F1"
}
dr_case "fixup: a rejected rewrite says 'the branch moved, or the lease failed'" case_push_refused_rewrite

case_readback_mismatch() {
    fx_up
    rm -f "$CZ_CASE/gh/pr-view.7.fromgit"
    cz_gh pr-view.7 "$FX_F1"
    fx 7
    cz_expect_rc 1
    cz_expect_stdout_has "  plan: typo:docs.md"
    local new; new="$(fx_fork_head)"
    cz_expect_stderr "maintainer-repo: pushed $new but #7 reports $FX_F1 as its head: NOT confirmed, look at it before anything else"
    cz_expect_gh_count "pr view" 3
    fx_no_scratch
}
dr_case "fixup: a head that GitHub does not report after the push is 'NOT confirmed', after 3 reads" case_readback_mismatch

case_readback_empty() {
    fx_up
    rm -f "$CZ_CASE/gh/pr-view.7.fromgit"
    cz_gh pr-view.7 "" 0
    cz_set MAINTAINER_GH_TRIES 2
    fx 7
    cz_expect_rc 1
    local new; new="$(fx_fork_head)"
    cz_expect_stderr "maintainer-repo: pushed $new but #7 reports nothing as its head: NOT confirmed, look at it before anything else"
    cz_expect_gh_count "pr view" 2
}
dr_case "fixup: an empty read-back says 'reports nothing' and MAINTAINER_GH_TRIES sets the number of reads" case_readback_empty

cz_finish
