#!/usr/bin/env bash
# Characterization: the exit codes and streams of `maintainer-merge update`.
# The existing suite drives update through every refusal. These cases pin the
# parts it leaves open: the exit code 3 ("this needs the author, not a retry"),
# which stream carries each message, and the exact argv of the PUT.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cz_init

# update_ready STATE CROSS MODIFY AUTHOR: pull request 7 at the fixture head,
# with a receipt for that head, this account's approval at that head, and the
# JSON `gh pr view` returns for the facts update reads.
update_ready() {
    cz_repo_basic
    cz_pr_ref 7 "$CZ_C0"
    cz_gh_baseline "$CZ_C0"
    cz_receipt 7 "$CZ_C0" observed
    cz_gh pr-view.headRefOid "$(printf '{"headRefOid":"%s","mergeStateStatus":"%s","reviewDecision":"APPROVED","author":{"login":"%s"},"isCrossRepository":%s,"maintainerCanModify":%s}' \
        "$CZ_C0" "$1" "$4" "$2" "$3")"
    cz_gh api-reviews "$(printf '{"user":{"login":"testuser"},"state":"APPROVED","commit_id":"%s"}' "$CZ_C0")"
}

ready_line() { printf '  #7: BEHIND, approved by testuser at %s, receipt valid, no other lease' "${CZ_C0:0:8}"; }

case_update_clean() {
    update_ready CLEAN false false contrib
    cz_mm update 7
    cz_expect_rc 0
    cz_expect_stdout "  #7 is CLEAN: nothing to update"
    cz_expect_stderr_empty
    cz_expect_gh_count "update-branch" 0
}
cz_case "update: a CLEAN pull request is nothing to update: exit 0, one stdout line, no PUT" case_update_clean

case_update_dirty() {
    update_ready DIRTY false false contrib
    cz_mm update 7
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr_first "maintainer-merge: #7 has conflicts (mergeStateStatus DIRTY). Conflicts are never resolved by this agent; the author resolves them."
    cz_expect_gh_count "update-branch" 0
}
cz_case "update: conflicts exit 1 on stderr, never 3" case_update_dirty

# Exit 3 is its own answer: the author has to press the button.
case_update_fork_no_edits() {
    update_ready BEHIND true false contrib
    cz_mm update 7
    cz_expect_rc 3
    cz_expect_stdout_empty
    cz_expect_stderr "maintainer-merge: will not update #7: the author must press Update branch; they have not allowed maintainer edits"
    cz_expect_gh_count "update-branch" 0
}
cz_case "update: a fork that does not allow maintainer edits exits 3 with the message on stderr" case_update_fork_no_edits

case_update_post_off() {
    update_ready BEHIND false false contrib
    cz_set MAINTAINER_POST off
    cz_mm update 7
    cz_expect_rc 0
    cz_expect_stdout \
        "$(ready_line)" \
        "  POST=off: every condition holds and the branch is NOT being updated" \
        "           it would run: gh api -X PUT repos/o/r/pulls/7/update-branch -f expected_head_sha=$CZ_C0"
    cz_expect_stderr_empty
    cz_expect_gh_count "update-branch" 0
}
cz_case "update: POST=off prints the PUT it would run on stdout, exits 0 and makes no PUT" case_update_post_off

case_update_put_argv() {
    update_ready BEHIND false false contrib
    cz_gh api-put "gh: Resource not accessible by integration (HTTP 403)" 1
    cz_mm update 7
    cz_expect_rc 3
    cz_expect_stdout "$(ready_line)"
    cz_expect_stderr_first "maintainer-merge: will not update #7: the author must press Update branch; GitHub did not let this account push to the head repository:"
    cz_expect_stderr_has "    gh: Resource not accessible by integration (HTTP 403)"
    cz_expect_gh_line "$(cz_argv api -X PUT repos/o/r/pulls/7/update-branch -f "expected_head_sha=$CZ_C0")"
    cz_expect_gh_line "$(cz_argv api --paginate repos/o/r/pulls/7/reviews --jq '.[]')"
}
cz_case "update: a 403 on the PUT exits 3; the PUT argv names expected_head_sha; the ready line is on stdout" case_update_put_argv

case_update_put_other_failure() {
    update_ready BEHIND false false contrib
    cz_gh api-put "gh: Server Error (HTTP 500)" 1
    cz_mm update 7
    cz_expect_rc 1
    cz_expect_stdout "$(ready_line)"
    cz_expect_stderr_first "maintainer-merge: GitHub refused the update of #7, so nothing was updated:"
}
cz_case "update: any other PUT failure exits 1, not 3" case_update_put_other_failure

cz_finish
