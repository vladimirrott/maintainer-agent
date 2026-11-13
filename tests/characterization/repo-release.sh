#!/usr/bin/env bash
# Characterization: `maintainer-repo release-check`. Every verdict and digit
# rule, each count it prints, the warnings for a profile with no PROD_GLOBS or
# SHIPPED_GLOBS, the empty-Unreleased warning, and the three ways the CHANGELOG
# it reads (the working tree) can disagree with origin/main: uncommitted, ahead
# of it, or behind it.
#
# Fixture: a repository with a bare origin, a tag v1.0.0 on a commit whose
# CHANGELOG has an empty Unreleased section, then commits the case adds.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib-dr.sh"
dr_init

CONT="$(printf '%*s' 29 '')"   # the continuation indent of the CHANGELOG-source lines: say's two spaces and 27 more
CL_EMPTY=$'# Changelog\n\n## [Unreleased]\n\n## [1.0.0] - 2026-01-01\n\n- first\n\n## [0.9.0] - 2025-12-01\n\n- older'

rel_base() {
    dr_git_remote
    dr_repo_env
    cz_set SHIPPED_GLOBS 'crates/*'
    cz_write crates/x/src/lib.rs "fn a() {}"
    cz_write CHANGELOG.md "$CL_EMPTY"
    cz_commit "release 1.0.0" CZ_C1
    cz_git tag v1.0.0
    cz_git push -q origin main --tags || { echo "characterization: push failed" >&2; exit 2; }
}
rel_change() {  # $1 = path, $2 = content, $3 = commit message: commit and push main
    cz_write "$1" "$2"
    cz_commit "$3" CZ_LAST
    cz_git push -q origin main || { echo "characterization: push failed" >&2; exit 2; }
}
# rel_changelog UNRELEASED_BODY: a CHANGELOG whose Unreleased section holds the body.
rel_changelog() { printf '# Changelog\n\n## [Unreleased]\n\n%s\n\n## [1.0.0] - 2026-01-01\n\n- first\n' "$1"; }
rel_short() { cz_git rev-parse --short HEAD; }

tail_lines() {  # $1 = docs|worthwhile|due, $2 = last|middle
    printf '%s\n' ""
    case "$1" in
        docs)       printf '%s\n' "  verdict: docs and tests only. A release is optional." ;;
        worthwhile) printf '%s\n' "  verdict: release worthwhile; production code changed." ;;
        due)        printf '%s\n' "  verdict: RELEASE DUE. A fix that removes a capability, or a security" \
                                  "           fix, is sitting unreleased, so every installed copy is still" \
                                  "           affected." ;;
    esac
    case "$2" in
        last)   printf '%s\n' "  digit:   last. Compatible additions and fixes." ;;
        middle) printf '%s\n' "  digit:   middle. Something that used to succeed now refuses, which" \
                              "           docs/release.md counts as a break in the 0.y series." ;;
    esac
    printf '%s\n' "  " "  Cutting one is a human decision: crates.io and npm versions can never be" "  replaced."
}

# --- no tag, nothing to release ------------------------------------------------------

case_no_tags() {
    dr_git_remote
    dr_repo_env
    dr_repo release-check
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr_has "maintainer-repo: no tags"
}
dr_case "release-check: a repository with no tag exits 1 with 'no tags'" case_no_tags

case_nothing() {
    rel_base
    dr_repo release-check
    cz_expect_rc 0
    cz_expect_stdout "  last tag: v1.0.0" "  commits since: 0" "  verdict: nothing to release"
    cz_expect_stderr_empty
}
dr_case "release-check: no commits since the tag prints three lines and 'nothing to release'" case_nothing

case_no_repo() {
    rel_base
    cz_set MAINTAINER_REPO "$CZ_CASE/nowhere"
    dr_repo release-check
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr_has "maintainer-repo: no repo at $CZ_CASE/nowhere"
}
dr_case "release-check: a repository path that does not exist exits 1 with 'no repo at'" case_no_repo

case_latest_tag() {
    rel_base
    rel_change crates/x/src/lib.rs "fn b() {}" "second"
    cz_git tag v1.1.0
    cz_git push -q origin --tags
    rel_change docs/a.md "doc" "third"
    dr_repo release-check
    cz_expect_rc 0
    cz_expect_stdout_has "  last tag: v1.1.0"
    cz_expect_stdout_has "  commits since: 1"
}
dr_case "release-check: with two tags the nearest one to origin/main is the last tag" case_latest_tag

# --- the whole report ------------------------------------------------------------------------

case_full_worthwhile() {
    rel_base
    rel_change crates/x/src/lib.rs "fn a() { 1 }" "feat: a thing"
    cz_write CHANGELOG.md "$(rel_changelog $'### Added\n\n- a thing')"; cz_commit "changelog" CZ_LAST
    cz_git push -q origin main
    local s1 s2; s2="$(rel_short)"; s1="$(cz_git rev-parse --short HEAD~1)"
    dr_repo release-check
    cz_expect_rc 0
    cz_expect_stdout \
        "  last tag: v1.0.0" \
        "  commits since: 2" \
        "" \
        "    $s2 changelog" \
        "    $s1 feat: a thing" \
        "" \
        "  CHANGELOG read from:        the working tree (main)" \
        "  production files touched:  1" \
        "  shipped surface touched:    1" \
        "  CHANGELOG Security section: no" \
        "  CHANGELOG Added section:    yes" \
        "  removed-capability wording: 0 occurrence(s)" \
        "$(tail_lines worthwhile last)"
    cz_expect_stderr_empty
}
dr_case "release-check: production code and an Added section print every line of the report, 'release worthwhile' and digit last" case_full_worthwhile

# --- verdicts and digits -------------------------------------------------------------------------

case_due_security() {
    rel_base
    rel_change crates/x/src/lib.rs "fn a() { 2 }" "fix: gate"
    rel_change CHANGELOG.md "$(rel_changelog $'### Security\n\n- closed a hole')" "changelog"
    dr_repo release-check
    cz_expect_rc 0
    cz_expect_stdout_has "  CHANGELOG Security section: yes"
    cz_expect_stdout_has "  CHANGELOG Added section:    no"
    dr_expect_block stdout "$(tail_lines due middle)"
}
dr_case "release-check: a Security section with production changes is RELEASE DUE and digit middle" case_due_security

case_due_wording() {
    rel_base
    rel_change crates/x/src/lib.rs "fn a() { 3 }" "fix: drop node 18"
    rel_change CHANGELOG.md "$(rel_changelog $'### Changed\n\n- Node 18 is no longer supported\n- a call that used to succeed now fails\n- a call that used to work is gone\n- the gate refuses stale input\n- the gate REFUSES odd input')" "changelog"
    dr_repo release-check
    cz_expect_stdout_has "  removed-capability wording: 5 occurrence(s)"
    cz_expect_stdout_has "  CHANGELOG Security section: no"
    dr_expect_block stdout "$(tail_lines due middle)"
}
dr_case "release-check: 'no longer', 'used to succeed', 'used to work' and 'refuses' (any case) each count their own line and make it RELEASE DUE" case_due_wording

case_wording_counts_lines() {
    rel_base
    rel_change crates/x/src/lib.rs "fn a() { 4 }" "fix"
    rel_change CHANGELOG.md "$(rel_changelog $'- one line says no longer and no longer')" "changelog"
    dr_repo release-check
    cz_expect_stdout_has "  removed-capability wording: 1 occurrence(s)"
}
dr_case "release-check: the wording count is lines, so two phrases on one line count once" case_wording_counts_lines

case_docs_only() {
    rel_base
    rel_change docs/a.md "documentation" "docs: a"
    dr_repo release-check
    cz_expect_rc 0
    cz_expect_stdout_has "  production files touched:  0"
    dr_expect_block stdout "$(tail_lines docs last)"
}
dr_case "release-check: only docs changed is 'docs and tests only' with digit last" case_docs_only

# Pins current behaviour: the digit rule does not look at the production count, so a
# docs-only range with a Security entry says a release is optional and the digit is middle.
case_docs_security() {
    rel_base
    rel_change CHANGELOG.md "$(rel_changelog $'### Security\n\n- note')" "docs: changelog"
    dr_repo release-check
    cz_expect_stdout_has "  production files touched:  0"
    dr_expect_block stdout "$(tail_lines docs middle)"
}
dr_case "release-check: a Security entry with no production file says 'optional' and digit middle (pins current behaviour)" case_docs_security

case_prod_count() {
    rel_base
    rel_change crates/x/src/lib.rs "fn a() { 5 }" "one"
    rel_change crates/y/src/lib.rs "fn y() {}" "two"
    rel_change crates/y/src/deep/m.rs "fn m() {}" "three"
    rel_change crates/y/tests/t.rs "fn t() {}" "four"
    dr_repo release-check
    cz_expect_stdout_has "  production files touched:  3"
    cz_expect_stdout_has "  shipped surface touched:    4"
}
dr_case "release-check: PROD_GLOBS and SHIPPED_GLOBS are git pathspecs: * crosses directories and tests/ is outside the first" case_prod_count

case_globs_not_expanded() {
    rel_base
    rel_change crates/x/src/zzz.rs "fn z() {}" "a file that does not exist in the old checkout"
    cz_git reset -q --hard v1.0.0
    dr_repo release-check
    cz_expect_rc 0
    # The pattern is handed to git as text. Expanded by the shell it would have
    # matched only crates/x/src/lib.rs, which is on disk, and counted 0.
    cz_expect_stdout_has "  production files touched:  1"
}
dr_case "release-check: PROD_GLOBS is not expanded by the shell, so a pattern counts files absent from the working tree" case_globs_not_expanded

# --- globs that are not declared ---------------------------------------------------------------------

case_no_prod_globs() {
    rel_base
    rel_change crates/x/src/lib.rs "fn a() { 6 }" "feat"
    cz_unset PROD_GLOBS
    dr_repo release-check
    cz_expect_rc 0
    cz_expect_stdout_has "  WARNING: this profile declares no PROD_GLOBS, so the production-file"
    cz_expect_stdout_has "           count below is meaningless. Set it in profile.env."
    cz_expect_stdout_has "  production files touched:  0"
    dr_expect_block stdout "$(tail_lines docs last)"
}
dr_case "release-check: no PROD_GLOBS warns twice, counts 0 and says 'docs and tests only'" case_no_prod_globs

case_no_shipped_globs() {
    rel_base
    rel_change crates/x/src/lib.rs "fn a() { 7 }" "feat"
    cz_unset SHIPPED_GLOBS
    dr_repo release-check
    cz_expect_rc 0
    cz_expect_stdout_has "  WARNING: this profile declares no SHIPPED_GLOBS, so nothing below can say"
    cz_expect_stdout_has "           whether the change reaches an installed copy. Set it in"
    cz_expect_stdout_has "           profile.env. Unset is not the same as untouched."
    cz_expect_stdout_lacks_shipped
}
cz_expect_stdout_lacks_shipped() { cz_expect_lacks stdout "shipped surface touched"; }
dr_case "release-check: no SHIPPED_GLOBS warns three lines and prints no 'shipped surface' line" case_no_shipped_globs

case_shipped_zero() {
    rel_base
    rel_change crates/x/src/lib.rs "fn a() { 8 }" "feat"
    cz_set SHIPPED_GLOBS 'apps/*'
    dr_repo release-check
    cz_expect_stdout_has "  shipped surface touched:    0"
    cz_expect_stdout_has "${CONT}nothing that installs has changed since v1.0.0, so a"
    cz_expect_stdout_has "${CONT}release would publish byte-identical artifacts and"
    cz_expect_stdout_has "${CONT}any break named below is in CI, not in the product."
}
dr_case "release-check: a shipped surface of 0 prints the three-line byte-identical explanation naming the tag" case_shipped_zero

# --- the CHANGELOG sections ----------------------------------------------------------------------------

case_empty_unreleased() {
    rel_base
    rel_change crates/x/src/lib.rs "fn a() { 9 }" "feat"
    dr_repo release-check
    cz_expect_stdout_has "  CHANGELOG Security section: no"
    cz_expect_stdout_has "  removed-capability wording: 0 occurrence(s)"
    cz_expect_stdout_has "  WARNING: the Unreleased section is empty, so the three lines above read"
    cz_expect_stdout_has "           nothing and this verdict rests on file counts alone."
    cz_expect_stdout_has "           The newest version heading is '[1.0.0] - 2026-01-01'. If you have already"
    cz_expect_stdout_has "           promoted Unreleased into it, read that section instead."
}
dr_case "release-check: an empty Unreleased section warns and names the newest version heading" case_empty_unreleased

case_whitespace_unreleased() {
    rel_base
    rel_change CHANGELOG.md "$(printf '# Changelog\n\n## [Unreleased]\n   \n\t\n\n## [1.0.0] - 2026-01-01\n\n- first')" "changelog"
    rel_change crates/x/src/lib.rs "fn a() { 10 }" "feat"
    dr_repo release-check
    cz_expect_stdout_has "  WARNING: the Unreleased section is empty, so the three lines above read"
}
dr_case "release-check: an Unreleased section of blank lines counts as empty" case_whitespace_unreleased

case_no_changelog() {
    dr_git_remote
    dr_repo_env
    cz_set SHIPPED_GLOBS 'crates/*'
    cz_write crates/x/src/lib.rs "fn a() {}"
    cz_commit "first" CZ_C1
    cz_git tag v1.0.0
    cz_git push -q origin main --tags
    rel_change crates/x/src/lib.rs "fn a() { 11 }" "feat"
    dr_repo release-check
    cz_expect_rc 0
    cz_expect_stdout_has "  WARNING: the Unreleased section is empty, so the three lines above read"
    cz_expect_stdout_has "           nothing and this verdict rests on file counts alone."
    cz_expect_stdout_lacks_heading
    cz_expect_stderr_empty
}
cz_expect_stdout_lacks_heading() { cz_expect_lacks stdout "newest version heading"; }
dr_case "release-check: no CHANGELOG.md at all warns the same way, without a version heading, and stays quiet on stderr" case_no_changelog

case_sections_scope() {
    rel_base
    rel_change CHANGELOG.md "$(printf '# Changelog\n\n## [Unreleased]\n\n### Added\n\n- x\n\n## [1.0.0] - 2026-01-01\n\n### Security\n\n- an old fix that no longer applies\n')" "changelog"
    rel_change crates/x/src/lib.rs "fn a() { 12 }" "feat"
    dr_repo release-check
    cz_expect_stdout_has "  CHANGELOG Security section: no"
    cz_expect_stdout_has "  CHANGELOG Added section:    yes"
    cz_expect_stdout_has "  removed-capability wording: 0 occurrence(s)"
    dr_expect_block stdout "$(tail_lines worthwhile last)"
}
dr_case "release-check: only the Unreleased section is read, so a Security heading under 1.0.0 does not count" case_sections_scope

# --- the CHANGELOG is read from the working tree -------------------------------------------------------------------

case_tree_clean_branch() {
    rel_base
    rel_change crates/x/src/lib.rs "fn a() { 13 }" "feat"
    cz_git checkout -q -b feat/x
    dr_repo release-check
    cz_expect_stdout_has "  CHANGELOG read from:        the working tree (feat/x)"
    cz_expect_stdout_lacks_tree_notes
}
cz_expect_stdout_lacks_tree_notes() {
    cz_expect_lacks stdout "uncommitted, so origin/main"
    cz_expect_lacks stdout "HEAD is not on origin/main"
    cz_expect_lacks stdout "BEHIND origin/main"
}
dr_case "release-check: the report names the checked-out branch and, when it equals origin/main, adds no note" case_tree_clean_branch

case_tree_detached() {
    rel_base
    rel_change crates/x/src/lib.rs "fn a() { 14 }" "feat"
    cz_git checkout -q --detach
    dr_repo release-check
    cz_expect_stdout_has "  CHANGELOG read from:        the working tree (HEAD)"
}
dr_case "release-check: a detached HEAD is named 'HEAD'" case_tree_detached

case_tree_uncommitted() {
    rel_base
    rel_change crates/x/src/lib.rs "fn a() { 15 }" "feat"
    cz_write CHANGELOG.md "$(rel_changelog $'### Added\n\n- not committed yet')"
    dr_repo release-check
    cz_expect_stdout_has "  CHANGELOG read from:        the working tree (main)"
    cz_expect_stdout_has "${CONT}uncommitted, so origin/main does not have it yet"
    # The uncommitted file is the one that is read.
    cz_expect_stdout_has "  CHANGELOG Added section:    yes"
}
dr_case "release-check: a modified CHANGELOG is read from disk and the report says origin/main does not have it" case_tree_uncommitted

case_tree_untracked() {
    dr_git_remote
    dr_repo_env
    cz_set SHIPPED_GLOBS 'crates/*'
    cz_write crates/x/src/lib.rs "fn a() {}"
    cz_commit "first" CZ_C1
    cz_git tag v1.0.0
    cz_git push -q origin main --tags
    rel_change crates/x/src/lib.rs "fn a() { 16 }" "feat"
    cz_write CHANGELOG.md "$(rel_changelog $'### Security\n\n- local only')"
    dr_repo release-check
    cz_expect_stdout_has "${CONT}uncommitted, so origin/main does not have it yet"
    cz_expect_stdout_has "  CHANGELOG Security section: yes"
}
dr_case "release-check: an untracked CHANGELOG counts as uncommitted" case_tree_untracked

case_tree_other_file_dirty() {
    rel_base
    rel_change crates/x/src/lib.rs "fn a() { 21 }" "feat"
    cz_write notes.txt "scratch"
    dr_repo release-check
    cz_expect_rc 0
    cz_expect_stdout_lacks_tree_notes
}
dr_case "release-check: an uncommitted file other than CHANGELOG.md adds no note" case_tree_other_file_dirty

case_tree_ahead() {
    rel_base
    rel_change crates/x/src/lib.rs "fn a() { 17 }" "feat"
    cz_write local.txt "local"; cz_commit "local only" CZ_LAST
    dr_repo release-check
    cz_expect_stdout_has "  CHANGELOG read from:        the working tree (main)"
    cz_expect_stdout_has "${CONT}HEAD is not on origin/main; the counts above are"
    cz_expect_lacks stdout "BEHIND"
}
dr_case "release-check: a HEAD with a commit origin/main lacks is 'not on origin/main'" case_tree_ahead

case_tree_behind() {
    rel_base
    rel_change crates/x/src/lib.rs "fn a() { 18 }" "one"
    rel_change docs/a.md "two" "two"
    cz_git reset -q --hard v1.0.0
    dr_repo release-check
    cz_expect_rc 0
    cz_expect_stdout_has "  commits since: 2"
    cz_expect_stdout_has "    $(cz_git rev-parse --short origin/main) two"
    cz_expect_stdout_has "    $(cz_git rev-parse --short origin/main~1) one"
    cz_expect_stdout_has "  shipped surface touched:    1"
    cz_expect_stdout_has "${CONT}HEAD is 2 commit(s) BEHIND origin/main, so this"
    cz_expect_stdout_has "${CONT}is NOT the CHANGELOG you are about to tag. Pull, then"
    cz_expect_stdout_has "${CONT}run this again; the digit below may be wrong."
}
dr_case "release-check: a checkout 2 commits behind origin/main prints the three-line BEHIND warning with the count" case_tree_behind

case_tree_uncommitted_wins() {
    rel_base
    rel_change crates/x/src/lib.rs "fn a() { 19 }" "one"
    cz_git reset -q --hard v1.0.0
    cz_write CHANGELOG.md "$(rel_changelog $'### Added\n\n- x')"
    dr_repo release-check
    cz_expect_stdout_has "${CONT}uncommitted, so origin/main does not have it yet"
    cz_expect_lacks stdout "BEHIND"
}
dr_case "release-check: an uncommitted CHANGELOG hides the BEHIND warning, because the notes are an if/elif chain" case_tree_uncommitted_wins

# --- fetching ----------------------------------------------------------------------------------------------------------

# Pins current behaviour: the tag fetch is not checked, so an unreachable origin
# prints git's own error and the report is built from the refs already on disk.
case_fetch_fails() {
    rel_base
    rel_change crates/x/src/lib.rs "fn a() { 20 }" "feat"
    cz_git remote set-url origin "$CZ_CASE/not-a-repo"
    dr_repo release-check
    cz_expect_rc 0
    cz_expect_stderr_has "fatal:"
    cz_expect_stdout_has "  last tag: v1.0.0"
    cz_expect_stdout_has "  commits since: 1"
}
dr_case "release-check: an origin that cannot be fetched prints git's error on stderr and the report still prints (pins current behaviour)" case_fetch_fails

cz_finish
