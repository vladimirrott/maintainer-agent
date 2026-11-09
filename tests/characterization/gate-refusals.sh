#!/usr/bin/env bash
# Characterization: every refusal of `maintainer-merge merge` that a stubbed gh
# and a scratch state directory can reach. Each case asserts the exit code by
# value (never "non-zero"), that stdout is empty, which stderr line carries the
# decision, and that gh pr merge was never called.
#
# The order of the checks is part of the behaviour, and several cases pin it by
# arranging two faults at once and asserting which one is reported.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cz_init

# --- before the receipt: PROD_GLOBS, lease, merge lock ---------------------------

case_no_prod_globs() {
    cz_merge_ready 7
    cz_set PROD_GLOBS ""
    cz_mm merge 7
    cz_expect_refusal 1 "maintainer-merge: this profile declares no PROD_GLOBS, so nothing can say"
    cz_expect_stderr_has 'PROD_GLOBS="bin/* lib/* scripts/* .github/*"'
    cz_expect_gh_log
}
cz_case "refusal: no PROD_GLOBS exits 1 before any gh call" case_no_prod_globs

case_lease_held() {
    cz_merge_ready 7
    cz_lease 7 run:other
    cz_mm merge 7
    cz_expect_refusal 1 "maintainer-merge: will not merge #7: another actor has leased it."
    cz_expect_stderr_has "#7 held by run:other (run)"
    cz_expect_gh_log
}
cz_case "refusal: a live lease held by another actor exits 1 before any gh call" case_lease_held

case_lease_unreadable() {
    cz_merge_ready 7
    mkdir -p "$CZ_STATE/leases"; printf 'not a lease\n' > "$CZ_STATE/leases/pr-7.json"
    cz_mm merge 7
    cz_expect_refusal 1 "maintainer-merge: could not read the lease on #7, so I will not merge it:"
    cz_expect_gh_log
}
cz_case "refusal: an unreadable lease exits 1 (the question could not be asked) before any gh call" case_lease_unreadable

case_lease_order() {
    cz_merge_ready 7
    cz_lease 7 run:other
    cz_set PROD_GLOBS ""
    cz_mm merge 7
    cz_expect_refusal 1 "maintainer-merge: will not merge #7: another actor has leased it."
}
cz_case "refusal order: the lease is checked before PROD_GLOBS" case_lease_order

case_prod_globs_before_identity() {
    cz_merge_ready 7
    cz_set PROD_GLOBS ""
    cz_gh api-user someone-else
    cz_mm merge 7
    cz_expect_refusal 1 "maintainer-merge: this profile declares no PROD_GLOBS, so nothing can say"
}
cz_case "refusal order: PROD_GLOBS is checked before the gh identity" case_prod_globs_before_identity

case_lock_held() {
    cz_merge_ready 7
    printf '1' > "$CZ_CASE/flock.rc"
    cz_mm merge 7
    cz_expect_refusal 1 "maintainer-merge: another merge of #7 is already running in this state directory."
    cz_expect_stderr_has "$CZ_RECEIPTS/.merge-7.lock"
    cz_check "flock calls" "$(cat "$CZ_CASE/flock.calls")" "-n 200"
    cz_expect_gh_log \
        "$(cz_argv auth switch --hostname github.com --user testuser)" \
        "$(cz_argv api user --jq .login)"
    cz_expect_file "$CZ_RECEIPTS/7.json"
}
cz_case "refusal: a held merge lock exits 1 after the identity check and before any pull request read" case_lock_held

# --- the receipt ------------------------------------------------------------------

case_no_receipt() {
    cz_repo_basic; cz_pr_ref 7 "$CZ_C0"; cz_gh_baseline "$CZ_C0"
    cz_mm merge 7
    cz_expect_refusal 1 "maintainer-merge: no verification receipt for #7. Prove the guard bites, then: maintainer-merge receipt 7 <sha> '<proof>'"
}
cz_case "refusal: no receipt exits 1" case_no_receipt

# The signature check runs a python3 that prints a traceback of its own when the
# file is not JSON, so the decision is on stderr but not on its first line.
case_receipt_not_json() {
    cz_merge_ready 7
    cz_receipt 7 "$CZ_C0" observed not-json
    cz_mm merge 7
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr_has "maintainer-merge: receipt for #7 is not readable JSON"
    cz_expect_gh_count "pr merge" 0
}
cz_case "refusal: a receipt that is not JSON exits 1" case_receipt_not_json

case_receipt_unsigned() {
    cz_merge_ready 7
    cz_receipt 7 "$CZ_C0" observed no-signature
    cz_mm merge 7
    cz_expect_refusal 1 "maintainer-merge: the receipt for #7 carries no signature, so it was not written by"
}
cz_case "refusal: a receipt with no signature exits 1" case_receipt_unsigned

case_receipt_bad_signature() {
    cz_merge_ready 7
    cz_receipt 7 "$CZ_C0" observed bad-signature
    cz_mm merge 7
    cz_expect_refusal 1 "maintainer-merge: the receipt for #7 does not match its signature: it was edited"
}
cz_case "refusal: a receipt with a wrong signature exits 1" case_receipt_bad_signature

case_receipt_edited() {
    cz_merge_ready 7
    cz_receipt 7 "$CZ_C0" observed edited
    cz_mm merge 7
    cz_expect_refusal 1 "maintainer-merge: the receipt for #7 does not match its signature: it was edited"
}
cz_case "refusal: a receipt edited after signing exits 1" case_receipt_edited

case_receipt_wrong_key() {
    cz_merge_ready 7
    printf 'a different key\n' > "$CZ_CASE/other.key"
    cz_set MAINTAINER_RECEIPT_KEY "$CZ_CASE/other.key"
    cz_mm merge 7
    cz_expect_refusal 1 "maintainer-merge: the receipt for #7 does not match its signature: it was edited"
}
cz_case "refusal: a receipt signed with another key exits 1" case_receipt_wrong_key

case_receipt_no_key() {
    cz_merge_ready 7
    cz_set MAINTAINER_RECEIPT_KEY "$CZ_CASE/missing.key"
    cz_mm merge 7
    cz_expect_refusal 1 "maintainer-merge: no receipt key at $CZ_CASE/missing.key; run ./install.sh"
}
cz_case "refusal: a missing signing key exits 1" case_receipt_no_key

# A copy of another pull request's receipt carries a valid signature. The
# filename is not signed, so the gate reads the pr field back.
case_receipt_copied() {
    cz_merge_ready 7
    cz_receipt 1 "$CZ_C0" observed
    cp "$CZ_RECEIPTS/1.json" "$CZ_RECEIPTS/7.json"
    cz_mm merge 7
    cz_expect_refusal 1 "maintainer-merge: the receipt at $CZ_RECEIPTS/7.json was earned for #1, not #7."
}
cz_case "refusal: a receipt copied from another pull request exits 1" case_receipt_copied

case_receipt_asserted_in_run() {
    cz_merge_ready 7
    cz_receipt 7 "$CZ_C0" asserted
    cz_set MAINTAINER_IN_RUN review
    cz_mm merge 7
    cz_expect_refusal 1 "maintainer-merge: the receipt for #7 is 'asserted', not 'observed'. An unattended run merges"
}
cz_case "refusal: an asserted receipt in an unattended run exits 1" case_receipt_asserted_in_run

# Pins current behaviour. Any kind other than observed or dependency is
# described as ASSERTED and may be spent by a human, whatever the word was.
case_receipt_unknown_kind() {
    cz_merge_ready 7
    cz_receipt 7 "$CZ_C0" made-up-kind
    cz_mm merge 7
    cz_expect_rc 0
    cz_expect_stdout_has "  the receipt is ASSERTED, not observed: it records a claim a"
    cz_expect_gh_count "pr merge" 1
}
cz_case "receipt kind: an unknown kind outside a run is called ASSERTED and merges (pins current behaviour)" case_receipt_unknown_kind

case_receipt_unknown_kind_in_run() {
    cz_merge_ready 7
    cz_receipt 7 "$CZ_C0" made-up-kind
    cz_set MAINTAINER_IN_RUN review
    cz_mm merge 7
    cz_expect_refusal 1 "maintainer-merge: the receipt for #7 is 'made-up-kind', not 'observed'. An unattended run merges"
}
cz_case "receipt kind: an unknown kind in an unattended run is refused and named" case_receipt_unknown_kind_in_run

case_receipt_asserted_by_human() {
    cz_merge_ready 7
    cz_receipt 7 "$CZ_C0" asserted
    cz_mm merge 7
    cz_expect_rc 0
    cz_expect_stdout_has "  the receipt is ASSERTED, not observed: it records a claim a"
    cz_expect_stderr_empty
}
cz_case "receipt kind: an asserted receipt outside a run merges and says ASSERTED on stdout" case_receipt_asserted_by_human

case_receipt_dependency() {
    cz_merge_ready 7
    cz_receipt 7 "$CZ_C0" dependency
    cz_set MAINTAINER_IN_RUN review
    cz_mm merge 7
    cz_expect_rc 0
    cz_expect_stdout_has "  the receipt is a DEPENDENCY receipt: nothing but dependency metadata"
}
cz_case "receipt kind: a dependency receipt merges even in an unattended run" case_receipt_dependency

# --- the pull request on GitHub ------------------------------------------------------

case_review_not_approved() {
    cz_merge_ready 7
    cz_gh pr-view.reviewDecision "$RV"
    cz_mm merge 7
    cz_expect_refusal 1 "maintainer-merge: #7 reviewDecision is '$RV', not APPROVED"
}
for RV in REVIEW_REQUIRED CHANGES_REQUESTED ""; do
    cz_case "refusal: reviewDecision '$RV' exits 1" case_review_not_approved
done

# Pins current behaviour. The read of reviewDecision has no status check, so a
# failing gh refuses only because an empty string is not APPROVED.
case_review_read_fails() {
    cz_merge_ready 7
    cz_gh pr-view.reviewDecision "" 1
    cz_mm merge 7
    cz_expect_refusal 1 "maintainer-merge: #7 reviewDecision is '', not APPROVED"
}
cz_case "refusal: a failed read of reviewDecision refuses as an empty decision (pins current behaviour)" case_review_read_fails

case_closes_unreadable() {
    cz_merge_ready 7
    cz_gh pr-view.closingIssuesReferences "gh: HTTP 502" 1
    cz_mm merge 7
    cz_expect_refusal 1 "maintainer-merge: #7: I could not read which issues this closes:"
    cz_expect_stderr_has "  gh: HTTP 502"
}
cz_case "refusal: closing issues that cannot be read exits 1 and shows gh's error" case_closes_unreadable

case_state() {
    cz_merge_ready 7
    cz_gh pr-view.mergeStateStatus "$ST_IN"
    cz_mm merge 7
    cz_expect_refusal 1 "maintainer-merge: $ST_OUT"
}
state_case() {  # $1 = mergeStateStatus, $2 = expected first stderr line without the prefix
    ST_IN="$1"; ST_OUT="$2"
    cz_case "refusal: mergeStateStatus '$1' exits 1" case_state
}
state_case BEHIND  "#7 is BEHIND its base; its checks describe a different tree. Update the branch and let it re-run. When it is approved and only that is missing: maintainer-merge update 7"
state_case DIRTY   "#7 has conflicts (mergeStateStatus DIRTY)"
state_case BLOCKED "#7 is BLOCKED: a required review or check is missing"
state_case UNKNOWN "#7 mergeStateStatus is 'UNKNOWN'; only CLEAN and HAS_HOOKS may merge"
state_case UNSTABLE "#7 mergeStateStatus is 'UNSTABLE'; only CLEAN and HAS_HOOKS may merge"
state_case ""      "#7 mergeStateStatus is ''; only CLEAN and HAS_HOOKS may merge"

case_state_has_hooks() {
    cz_merge_ready 7
    cz_gh pr-view.mergeStateStatus HAS_HOOKS
    cz_mm merge 7
    cz_expect_rc 0
    cz_expect_gh_count "pr merge" 1
}
cz_case "mergeStateStatus HAS_HOOKS merges, like CLEAN" case_state_has_hooks

# The review is read before the state, and both before the checks.
case_review_before_state() {
    cz_merge_ready 7
    cz_gh pr-view.reviewDecision REVIEW_REQUIRED
    cz_gh pr-view.mergeStateStatus DIRTY
    cz_gh pr-checks '[{"name":"a","bucket":"fail"}]' 1
    cz_mm merge 7
    cz_expect_refusal 1 "maintainer-merge: #7 reviewDecision is 'REVIEW_REQUIRED', not APPROVED"
}
cz_case "refusal order: the review decision is reported before the merge state and the checks" case_review_before_state

case_state_before_checks() {
    cz_merge_ready 7
    cz_gh pr-view.mergeStateStatus DIRTY
    cz_gh pr-checks '[{"name":"a","bucket":"fail"}]' 1
    cz_mm merge 7
    cz_expect_refusal 1 "maintainer-merge: #7 has conflicts (mergeStateStatus DIRTY)"
}
cz_case "refusal order: the merge state is reported before the checks" case_state_before_checks

case_checks_before_staleness() {
    cz_repo_basic
    cz_write crates/x/src/lib.rs "fn main() { changed(); }"; cz_commit prod-change C1
    cz_pr_ref 7 "$C1"; cz_gh_baseline "$C1"; cz_receipt 7 "$CZ_C0" observed
    cz_gh pr-checks '[{"name":"a","bucket":"fail"}]' 1
    cz_mm merge 7
    cz_expect_refusal 1 "maintainer-merge: #7 has 1 failing check(s)"
}
cz_case "refusal order: the checks are reported before the staleness check" case_checks_before_staleness

case_fetch_fails() {
    cz_merge_ready 7
    cz_git update-ref -d refs/pull/7/head
    cz_mm merge 7
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr_has "maintainer-merge: cannot fetch #7"
    cz_expect_gh_count "pr merge" 0
}
cz_case "refusal: a pull request ref that cannot be fetched exits 1" case_fetch_fails

# --- the repository --------------------------------------------------------------------

# Every refusal above leaves the receipt where it was, so the gate can be run
# again once the cause is fixed.
case_receipt_kept_on_refusal() {
    cz_merge_ready 7
    cz_gh pr-view.reviewDecision REVIEW_REQUIRED
    cz_mm merge 7
    cz_expect_rc 1
    cz_expect_file "$CZ_RECEIPTS/7.json"
    cz_check "temporary branch removed" "$(cz_git branch --list 'mm-*')" ""
}
cz_case "refusal: the receipt is kept" case_receipt_kept_on_refusal

cz_finish
