#!/usr/bin/env bash
# Characterization: what `maintainer-merge merge` does on its way to `gh pr
# merge`. Covers the success path (argv, output, exit code, call order), the
# POST=off rehearsal, how the board of checks is read when `gh pr checks`
# exits non-zero, and the identity gate.
#
# Every case records the bash program as it behaves today. None of them changes
# it. A case whose comment says "pins current behaviour" records something a
# later port may be meant to change.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cz_init

APPROVED_7='  #7: approved, 1 checks pass, 0 skipped, 0 fail, 0 pending, 0 cancelled, receipt valid'

# --- 1. the success path -----------------------------------------------------

# The argv of `gh pr merge` was pinned only by a grep of the source. Here the
# program runs and the stub records what it was called with.
case_merge_argv() {
    cz_merge_ready 7
    cz_mm merge 7
    cz_expect_rc 0
    cz_expect_gh_count "pr merge" 1
    cz_expect_gh_line "$(cz_argv pr merge 7 --repo o/r --squash --delete-branch --match-head-commit "$CZ_C0")"
}
cz_case "merge success: gh pr merge argv carries --squash, --delete-branch and --match-head-commit <head>" case_merge_argv

case_merge_stdout() {
    cz_merge_ready 7
    cz_mm merge 7
    cz_expect_rc 0
    # gh's own stdout from `pr merge` passes straight through, between the
    # gate's "approved" line and its "merged" line.
    cz_expect_stdout \
        "$APPROVED_7" \
        "stub gh: pr merge ran" \
        "  merged #7" \
        "  #7 closes no issue, so nothing was closed by this merge." \
        "    If it resolves one, close it by hand and say which commit did it."
    cz_expect_stderr_empty
}
cz_case "merge success: exit 0, five stdout lines, empty stderr" case_merge_stdout

case_merge_consumes_receipt() {
    cz_merge_ready 7
    cz_mm merge 7
    cz_expect_rc 0
    cz_expect_no_file "$CZ_RECEIPTS/7.json"
    cz_expect_file "$CZ_RECEIPTS/.merge-7.lock"
    cz_check "flock calls" "$(cat "$CZ_CASE/flock.calls")" "-n 200"
    cz_check "temporary branch mm-7 removed" "$(cz_git branch --list 'mm-*')" ""
}
cz_case "merge success: the receipt is deleted, the merge lock is taken with flock -n 200, mm-7 is removed" case_merge_consumes_receipt

case_merge_call_order() {
    cz_merge_ready 7
    cz_mm merge 7
    cz_expect_rc 0
    cz_expect_gh_log \
        "$(cz_argv auth switch --hostname github.com --user testuser)" \
        "$(cz_argv api user --jq .login)" \
        "$(cz_argv pr view 7 --repo o/r --json headRefOid --jq .headRefOid)" \
        "$(cz_argv pr view 7 --repo o/r --json mergeStateStatus --jq .mergeStateStatus)" \
        "$(cz_argv pr view 7 --repo o/r --json reviewDecision --jq .reviewDecision)" \
        "$(cz_argv pr view 7 --repo o/r --json closingIssuesReferences --jq '.closingIssuesReferences[].number')" \
        "$(cz_argv pr checks 7 --repo o/r --json name,bucket)" \
        "$(cz_argv pr merge 7 --repo o/r --squash --delete-branch --match-head-commit "$CZ_C0")"
}
cz_case "merge success: the complete gh call sequence, in order" case_merge_call_order

case_merge_failure() {
    cz_merge_ready 7
    cz_gh pr-merge "gh: merge conflict" 1
    cz_mm merge 7
    cz_expect_rc 1
    cz_expect_stdout "$APPROVED_7" "gh: merge conflict"
    cz_expect_stderr "maintainer-merge: merge failed"
    cz_expect_file "$CZ_RECEIPTS/7.json"
}
cz_case "merge: when gh pr merge fails the exit code is 1, the message is on stderr and the receipt stays" case_merge_failure

# The pin is the head read from GitHub at the moment of the merge, not the head
# the receipt was earned at.
case_merge_pins_current_head() {
    cz_repo_basic
    cz_write docs/a.md "changed after the receipt"; cz_commit docs-only C1
    cz_pr_ref 7 "$C1"
    cz_gh_baseline "$C1"
    cz_receipt 7 "$CZ_C0" observed
    cz_mm merge 7
    cz_expect_rc 0
    cz_expect_gh_line "$(cz_argv pr merge 7 --repo o/r --squash --delete-branch --match-head-commit "$C1")"
}
cz_case "merge success: --match-head-commit names the head GitHub reports, not the receipt's head" case_merge_pins_current_head

# F9, FIXED here. This case first pinned the old behaviour: the head was read with
# no check of gh's exit status, a gh that failed there left it empty, and the
# merge went ahead with an empty --match-head-commit argument, so the one fence
# that stops a late push from being merged unchecked was gone. The merge now
# refuses before it reads any other fact. The Rust gate must refuse the same way.
case_merge_head_read_fails() {
    cz_merge_ready 7
    cz_gh pr-view.headRefOid "" 1
    cz_mm merge 7
    cz_expect_refusal 1 "maintainer-merge: could not read the head commit of #7; refusing to merge without a head to pin it to"
}
cz_case "merge: a failed read of the head refuses, and gh pr merge is never called (F9, fixed)" case_merge_head_read_fails

case_merge_head_read_empty() {
    cz_merge_ready 7
    cz_gh pr-view.headRefOid "" 0
    cz_mm merge 7
    cz_expect_refusal 1 "maintainer-merge: the head commit of #7 came back as '', which is not a commit id; refusing to merge without a head to pin it to"
}
cz_case "merge: an empty head from a successful read refuses (F9, fixed)" case_merge_head_read_empty

case_merge_head_read_garbage() {
    cz_merge_ready 7
    cz_gh pr-view.headRefOid "NOT-A-COMMIT" 0
    cz_mm merge 7
    cz_expect_refusal 1 "maintainer-merge: the head commit of #7 came back as 'NOT-A-COMMIT', which is not a commit id; refusing to merge without a head to pin it to"
}
cz_case "merge: a head that is not a commit id refuses (F9, fixed)" case_merge_head_read_garbage

# --- 2. POST=off ---------------------------------------------------------------

case_post_off() {
    cz_merge_ready 7
    cz_set MAINTAINER_POST off
    cz_mm merge 7
    cz_expect_rc 0
    cz_expect_gh_count "pr merge" 0
    cz_expect_stdout \
        "$APPROVED_7" \
        "  POST=off: every condition holds and the merge is NOT being made" \
        "           re-run with posting on to land it"
    cz_expect_stderr_empty
    cz_expect_file "$CZ_RECEIPTS/7.json"
}
cz_case "POST=off: no gh pr merge, two rehearsal lines on stdout, exit 0, receipt kept" case_post_off

# Pins current behaviour. identity() runs before any rehearsal check, so a
# rehearsal still switches the global gh account.
case_post_off_identity() {
    cz_merge_ready 7
    cz_set MAINTAINER_POST off
    cz_mm merge 7
    cz_expect_rc 0
    cz_expect_gh_line "$(cz_argv auth switch --hostname github.com --user testuser)"
    cz_expect_gh_line "$(cz_argv api user --jq .login)"
}
cz_case "POST=off: the gh account is still switched and confirmed (pins current behaviour)" case_post_off_identity

case_post_off_refusal_first() {
    cz_merge_ready 7
    cz_set MAINTAINER_POST off
    cz_gh pr-view.reviewDecision REVIEW_REQUIRED
    cz_mm merge 7
    cz_expect_refusal 1 "maintainer-merge: #7 reviewDecision is 'REVIEW_REQUIRED', not APPROVED"
}
cz_case "POST=off: a failed condition still refuses with exit 1 on stderr" case_post_off_refusal_first

# Pins current behaviour. Only the exact word "off" rehearses. Any other value,
# including a different case, posts.
case_post_not_off() {
    cz_merge_ready 7
    cz_set MAINTAINER_POST "$POST_VALUE"
    cz_mm merge 7
    cz_expect_rc 0
    cz_expect_gh_count "pr merge" 1
    cz_expect_stdout_has "  merged #7"
}
for POST_VALUE in OFF Off false 0 no; do
    cz_case "POST=$POST_VALUE is not a rehearsal: the merge is made (pins current behaviour)" case_post_not_off
done

# --- 5. the board of checks, when gh pr checks exits non-zero ------------------

# gh pr checks exits 1 on a failure and 8 while checks are pending. The program
# does not read the exit status of that call. It reads the buckets from stdout.
case_checks() {
    cz_merge_ready 7
    cz_gh pr-checks "$CK_JSON" "$CK_GHRC"
    cz_mm merge 7
    cz_expect_rc "$CK_WANT_RC"
    if [ "$CK_WANT_RC" = 0 ]; then
        cz_expect_gh_count "pr merge" 1
        cz_expect_stdout_has "$CK_WANT_SAY"
        cz_expect_stderr_empty
    else
        cz_expect_stdout_empty
        cz_expect_stderr "maintainer-merge: $CK_WANT_ERR"
        cz_expect_gh_count "pr merge" 0
    fi
}
checks_case() {  # $1 name, $2 json, $3 gh exit status, $4 expected rc, $5 stderr line or "", $6 stdout fragment
    CK_JSON="$2"; CK_GHRC="$3"; CK_WANT_RC="$4"; CK_WANT_ERR="$5"; CK_WANT_SAY="${6:-}"
    cz_case "$1" case_checks
}
P='{"name":"a","bucket":"pass"}'
S='{"name":"b","bucket":"skipping"}'
F='{"name":"c","bucket":"fail"}'
D='{"name":"d","bucket":"pending"}'
C='{"name":"e","bucket":"cancel"}'

checks_case "checks: one pass, gh exits 0: merges" "[$P]" 0 0 "" "1 checks pass, 0 skipped, 0 fail, 0 pending, 0 cancelled"
# Pins current behaviour. gh exits 1, the buckets say pass, the program merges.
checks_case "checks: all pass but gh exits 1: the exit status is ignored and it merges (pins current behaviour)" "[$P]" 1 0 "" "1 checks pass"
checks_case "checks: pass and skipping, gh exits 0: merges and counts both" "[$P,$S]" 0 0 "" "1 checks pass, 1 skipped"
checks_case "checks: one fail, gh exits 1: refuses with exit 1" "[$P,$F]" 1 1 "#7 has 1 failing check(s)"
# gh exits 0 with a failing bucket: the program believes the bucket, not the status.
checks_case "checks: one fail but gh exits 0: still refuses" "[$P,$F]" 0 1 "#7 has 1 failing check(s)"
checks_case "checks: one pending, gh exits 8: refuses with exit 1" "[$P,$D]" 8 1 "#7 has 1 pending check(s)"
checks_case "checks: one cancelled, gh exits 1: refuses with exit 1" "[$P,$C]" 1 1 "#7 has 1 cancelled check(s); a cancelled check never reported a verdict. Re-run it."
checks_case "checks: every check skipped: refuses, nothing ran" "[$S,$S]" 0 1 "#7: all 2 checks were skipped, so nothing ran"
checks_case "checks: an empty list: refuses" "[]" 0 1 "#7 has an empty check list; an empty board is a failure, not a pass"
checks_case "checks: gh prints nothing and exits 1: refuses as no checks at all" "" 1 1 "#7 reported no checks at all; refusing"
checks_case "checks: a bucket the gate does not know: refuses" "[$P,{\"name\":\"f\",\"bucket\":\"weird\"}]" 0 1 "#7: 1 of 2 checks are pass or skipping; the rest are in a bucket this gate does not accept"
# The order of the refusals when several buckets are bad.
checks_case "checks: fail and pending together: the failure is reported first" "[$F,$D]" 1 1 "#7 has 1 failing check(s)"
checks_case "checks: pending and cancelled together: the pending count is reported first" "[$D,$C]" 8 1 "#7 has 1 pending check(s)"
checks_case "checks: fail and cancelled together: the failure is reported first" "[$F,$C]" 1 1 "#7 has 1 failing check(s)"

# Pins current behaviour. The python that counts the buckets runs inside a
# command substitution whose own status is never read, so unreadable JSON
# surfaces as five empty counts and the "not a number" refusal, not as the
# "could not read the check list" refusal written for it.
case_checks_not_json() {
    cz_merge_ready 7
    cz_gh pr-checks "this is not json" 0
    cz_mm merge 7
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr_has "maintainer-merge: the check counts for #7 came back as ''/''/''/''/''/'', which is not a number. Refusing."
    cz_expect_lacks stderr "could not read the check list"
    cz_expect_gh_count "pr merge" 0
}
cz_case "checks: output that is not JSON refuses with the 'not a number' message (pins current behaviour)" case_checks_not_json

# --- 7. identity() -------------------------------------------------------------

LOGIN_HINT="if the token was rejected, run gh auth login -h github.com as testuser"

case_identity_api_fails() {
    cz_merge_ready 7
    cz_gh api-user '{"message":"Bad credentials"}' 1
    cz_mm merge 7
    cz_expect_refusal 1 "maintainer-merge: gh could not confirm an account (gh exited 1); $LOGIN_HINT"
    cz_expect_gh_log \
        "$(cz_argv auth switch --hostname github.com --user testuser)" \
        "$(cz_argv api user --jq .login)"
}
cz_case "identity: gh api user fails: exit 1, message on stderr, nothing else is asked" case_identity_api_fails

case_identity_api_exit_code() {
    cz_merge_ready 7
    cz_gh api-user "" 4
    cz_mm merge 7
    cz_expect_refusal 1 "maintainer-merge: gh could not confirm an account (gh exited 4); $LOGIN_HINT"
}
cz_case "identity: the message carries gh's own exit code" case_identity_api_exit_code

case_identity_other_login() {
    cz_merge_ready 7
    cz_gh api-user someone-else
    cz_mm merge 7
    cz_expect_refusal 1 "maintainer-merge: gh is authenticated as 'someone-else', not testuser"
}
cz_case "identity: another login: exit 1, message on stderr" case_identity_other_login

case_identity_empty_login() {
    cz_merge_ready 7
    cz_gh api-user "" 0
    cz_mm merge 7
    cz_expect_refusal 1 "maintainer-merge: gh is authenticated as 'unknown', not testuser"
}
cz_case "identity: gh succeeds with no login: the message says 'unknown'" case_identity_empty_login

case_identity_case_insensitive() {
    cz_merge_ready 7
    cz_gh api-user TestUser
    cz_mm merge 7
    cz_expect_rc 0
    cz_expect_gh_count "pr merge" 1
}
cz_case "identity: a login that differs only in case is the same account" case_identity_case_insensitive

case_identity_account_case() {
    cz_merge_ready 7
    cz_set MAINTAINER_ACCOUNT TestUser
    cz_mm merge 7
    cz_expect_rc 0
    cz_expect_gh_line "$(cz_argv auth switch --hostname github.com --user TestUser)"
}
cz_case "identity: the profile account is passed to gh auth switch as written, and compared without case" case_identity_account_case

# Pins current behaviour. The status of `gh auth switch` is discarded. Only the
# login that `gh api user` reports decides.
case_identity_switch_fails() {
    cz_merge_ready 7
    cz_gh auth-switch "" 1
    cz_mm merge 7
    cz_expect_rc 0
    cz_expect_gh_count "pr merge" 1
}
cz_case "identity: a failing gh auth switch is ignored when gh api user names the right login (pins current behaviour)" case_identity_switch_fails

case_identity_before_receipt() {
    cz_repo_basic
    cz_gh_baseline "$CZ_C0"
    cz_gh api-user someone-else
    cz_mm merge 7
    cz_expect_refusal 1 "maintainer-merge: gh is authenticated as 'someone-else', not testuser"
}
cz_case "identity: is checked before the receipt is read (no receipt exists, the identity message wins)" case_identity_before_receipt

cz_finish
