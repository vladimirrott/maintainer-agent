#!/usr/bin/env bash
# Characterization: the staleness check, receipt_fresh in bin/maintainer-merge.
# It runs when the head GitHub reports differs from the head the receipt was
# earned at, and decides whether production code moved in between.
#
# Every case builds a real git repository with fixed dates, because the check is
# a sequence of real git commands (merge-base, merge-tree --write-tree, diff)
# and a stub would prove nothing. origin is the repository itself and each pull
# request's head is the ref refs/pull/<n>/head, as GitHub names it.
#
# PROD_GLOBS is crates/*/src/* in every case here.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cz_init

# fixture_update_branch EXTRA: a pull request #7 whose verified head V holds a
# production change, after main moved (also in a production path) and GitHub's
# "Update branch" merged main into the pull request, giving head P2. EXTRA is
# "none" for a plain update, or "author-push" when the author then pushed one
# more production file. The receipt is for V. Names V and P2.
fixture_update_branch() {
    cz_repo_basic
    cz_git checkout -q -b pr
    cz_write crates/x/src/lib.rs "fn main() { pr_change(); }"; cz_commit pr-work V
    cz_git checkout -q main
    cz_write crates/y/src/main_only.rs "fn main_only() {}"; cz_commit main-moves M1
    cz_git checkout -q pr
    cz_git merge -q --no-edit main || { echo "characterization: the update merge failed" >&2; exit 2; }
    if [ "$1" = author-push ]; then
        cz_write crates/x/src/extra.rs "fn extra() {}"; cz_commit author-pushes-more P2
    else
        P2="$(cz_git rev-parse HEAD)"
    fi
    cz_git checkout -q main
    cz_pr_ref 7 "$P2"
    cz_gh_baseline "$P2"
    cz_receipt 7 "$V" observed
}

# fixture_conflict RESOLUTION: main and the pull request changed the same line
# of a production file, and the author merged main in by hand. RESOLUTION is
# "keep-pr" (the file ends as the verified head had it) or "combine" (a new
# line that neither side had). The receipt is for V. Names V and P2.
fixture_conflict() {
    cz_repo_basic
    cz_git checkout -q -b pr
    cz_write crates/x/src/lib.rs "fn main() { pr_change(); }"; cz_commit pr-work V
    cz_git checkout -q main
    cz_write crates/x/src/lib.rs "fn main() { main_change(); }"; cz_commit main-moves M1
    cz_git checkout -q pr
    if cz_git merge -q --no-edit main >/dev/null 2>&1; then
        echo "characterization: the conflict fixture had no conflict" >&2; exit 2
    fi
    if [ "$1" = keep-pr ]; then
        cz_write crates/x/src/lib.rs "fn main() { pr_change(); }"
    else
        cz_write crates/x/src/lib.rs "fn main() { pr_change(); main_change(); }"
    fi
    cz_commit resolve P2
    cz_git checkout -q main
    cz_pr_ref 7 "$P2"
    cz_gh_baseline "$P2"
    cz_receipt 7 "$V" observed
}

NO_BRANCH_LEFT="temporary branch mm-7 removed"

# --- the head did not move ---------------------------------------------------------

case_head_unchanged() {
    cz_merge_ready 7
    cz_mm merge 7
    cz_expect_rc 0
    cz_expect_lacks stdout "head moved"
    cz_check "$NO_BRANCH_LEFT" "$(cz_git branch --list 'mm-*')" ""
}
cz_case "staleness: the head the receipt names is the head being merged: no comparison is printed" case_head_unchanged

# --- the head moved, nothing in production changed -------------------------------------

case_docs_only() {
    cz_repo_basic
    cz_write docs/a.md "a later edit"; cz_commit docs-only C1
    cz_pr_ref 7 "$C1"; cz_gh_baseline "$C1"; cz_receipt 7 "$CZ_C0" observed
    cz_mm merge 7
    cz_expect_rc 0
    cz_expect_stdout_has "  head moved $CZ_C0 -> ${C1:0:8}, no production diff; receipt still applies"
    cz_expect_gh_count "pr merge" 1
}
cz_case "staleness: a docs-only change after the receipt keeps it, by the strict range diff" case_docs_only

case_prod_changed() {
    cz_repo_basic
    cz_write crates/x/src/lib.rs "fn main() { changed(); }"; cz_commit prod C1
    cz_pr_ref 7 "$C1"; cz_gh_baseline "$C1"; cz_receipt 7 "$CZ_C0" observed
    cz_mm merge 7
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr \
        "maintainer-merge: production code changed since the verified head $CZ_C0:" \
        "    crates/x/src/lib.rs" \
        "  The receipt no longer describes this tree. Re-verify and record a new one."
    cz_expect_gh_count "pr merge" 0
    cz_check "$NO_BRANCH_LEFT" "$(cz_git branch --list 'mm-*')" ""
    cz_expect_file "$CZ_RECEIPTS/7.json"
}
cz_case "staleness: a production change after the receipt exits 1, lists the file on stderr, removes mm-7, keeps the receipt" case_prod_changed

case_prod_changed_lists_all() {
    cz_repo_basic
    cz_write crates/x/src/lib.rs "fn main() { changed(); }"
    cz_write crates/y/src/new.rs "fn new() {}"
    cz_write docs/a.md "docs move too"
    cz_commit prod-and-docs C1
    cz_pr_ref 7 "$C1"; cz_gh_baseline "$C1"; cz_receipt 7 "$CZ_C0" observed
    cz_mm merge 7
    cz_expect_rc 1
    cz_expect_stderr \
        "maintainer-merge: production code changed since the verified head $CZ_C0:" \
        "    crates/x/src/lib.rs" \
        "    crates/y/src/new.rs" \
        "  The receipt no longer describes this tree. Re-verify and record a new one."
}
cz_case "staleness: every changed production file is listed and a changed doc is not" case_prod_changed_lists_all

# --- the tree-merge branch: the head moved because GitHub merged main in -----------------

# main moved in a production path too. The two-dot range would call that a
# change of the pull request. The tree-merge comparison does not.
case_tree_merge_survives() {
    fixture_update_branch none
    cz_mm merge 7
    cz_expect_rc 0
    cz_expect_stdout_has "  head moved $V -> ${P2:0:8}, the tree is the clean merge of the verified head with main; receipt still applies"
    cz_expect_gh_line "$(cz_argv pr merge 7 --repo o/r --squash --delete-branch --match-head-commit "$P2")"
    cz_check "$NO_BRANCH_LEFT" "$(cz_git branch --list 'mm-*')" ""
}
cz_case "staleness: Update branch with a production change on main keeps the receipt (merge-tree branch)" case_tree_merge_survives

case_tree_merge_stale() {
    fixture_update_branch author-push
    cz_mm merge 7
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr \
        "maintainer-merge: production code changed since the verified head $V:" \
        "    crates/x/src/extra.rs" \
        "  The receipt no longer describes this tree. Re-verify and record a new one."
    cz_expect_gh_count "pr merge" 0
    cz_check "$NO_BRANCH_LEFT" "$(cz_git branch --list 'mm-*')" ""
}
cz_case "staleness: Update branch followed by an author push of production code kills the receipt (merge-tree branch)" case_tree_merge_stale

case_tree_merge_names_only_the_author() {
    fixture_update_branch author-push
    cz_mm merge 7
    cz_expect_rc 1
    cz_expect_lacks stderr "crates/y/src/main_only.rs"
}
cz_case "staleness: the file main added is not blamed on the pull request" case_tree_merge_names_only_the_author

# --- the tree-merge branch falls back when the merge conflicts ---------------------------

# merge-tree exits non-zero on a conflict, so the check falls back to the strict
# range from the verified head to the new head. The resolution is a human edit.
case_conflict_combined() {
    fixture_conflict combine
    cz_mm merge 7
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr \
        "maintainer-merge: production code changed since the verified head $V:" \
        "    crates/x/src/lib.rs" \
        "  The receipt no longer describes this tree. Re-verify and record a new one."
}
cz_case "staleness: a conflict resolved by hand into new production code kills the receipt (strict range)" case_conflict_combined

# Pins current behaviour. When the resolution leaves the production tree
# as the verified head had it, the strict range is empty and the receipt holds,
# worded "no production diff", not "the tree is the clean merge".
case_conflict_keep_pr() {
    fixture_conflict keep-pr
    cz_mm merge 7
    cz_expect_rc 0
    cz_expect_stdout_has "  head moved $V -> ${P2:0:8}, no production diff; receipt still applies"
    cz_expect_lacks stdout "clean merge"
}
cz_case "staleness: a conflict resolved back to the verified tree keeps the receipt, worded 'no production diff' (pins current behaviour)" case_conflict_keep_pr

# --- git diff fails: the check fails OPEN today -----------------------------------------------

# Pins current behaviour, see plan decision F1. The status of git diff is not
# read. A verified head the repository does not have makes the diff fail, the
# output is empty, and empty reads as "no production diff". The receipt is
# accepted for a head nobody can compare against.
case_diff_fails_open_unknown_head() {
    cz_repo_basic
    cz_git checkout -q -b pr
    cz_write crates/x/src/lib.rs "fn main() { pr_change(); }"; cz_commit pr-work C1
    cz_git checkout -q main
    cz_pr_ref 7 "$C1"; cz_gh_baseline "$C1"
    cz_receipt 7 "0123456789abcdef0123456789abcdef01234567" observed
    cz_mm merge 7
    cz_expect_rc 0
    cz_expect_stdout_has "  head moved 0123456789abcdef0123456789abcdef01234567 -> ${C1:0:8}, no production diff; receipt still applies"
    cz_expect_stderr_empty
    cz_expect_gh_count "pr merge" 1
}
cz_case "staleness F1: a verified head missing from the repository makes git diff fail and the receipt is accepted (pins current behaviour)" case_diff_fails_open_unknown_head

# The same fault in the strict-range call, reached by a pathspec git rejects
# ("bogus" is not a pathspec magic word), with a production change that would
# have been caught.
case_diff_fails_open_strict_range() {
    cz_repo_basic
    cz_write crates/x/src/lib.rs "fn main() { changed(); }"; cz_commit prod C1
    cz_pr_ref 7 "$C1"; cz_gh_baseline "$C1"; cz_receipt 7 "$CZ_C0" observed
    cz_set PROD_GLOBS ':(bogus)x'
    cz_mm merge 7
    cz_expect_rc 0
    cz_expect_stdout_has "  head moved $CZ_C0 -> ${C1:0:8}, no production diff; receipt still applies"
    cz_expect_gh_count "pr merge" 1
}
cz_case "staleness F1: a failing git diff in the strict-range branch lets a production change through (pins current behaviour)" case_diff_fails_open_strict_range

# The same fault in the tree-merge call.
case_diff_fails_open_tree_merge() {
    fixture_update_branch author-push
    cz_set PROD_GLOBS ':(bogus)x'
    cz_mm merge 7
    cz_expect_rc 0
    cz_expect_stdout_has "  head moved $V -> ${P2:0:8}, the tree is the clean merge of the verified head with main; receipt still applies"
    cz_expect_gh_count "pr merge" 1
}
cz_case "staleness F1: a failing git diff in the tree-merge branch lets a production change through (pins current behaviour)" case_diff_fails_open_tree_merge

# Control for the two cases above: the same repository with a pathspec git
# accepts refuses, so the pass above comes from the failing diff and from
# nothing else.
case_diff_control() {
    fixture_update_branch author-push
    cz_mm merge 7
    cz_expect_rc 1
    cz_expect_stderr_first "maintainer-merge: production code changed since the verified head $V:"
}
cz_case "staleness F1 control: the same history with a valid PROD_GLOBS is refused" case_diff_control

cz_finish
