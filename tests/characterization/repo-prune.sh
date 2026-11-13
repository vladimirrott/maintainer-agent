#!/usr/bin/env bash
# Characterization: bin/maintainer-repo, its command line and `prune`. The usage
# line and the profile refusals (exit 64), the dry run, the real run, POST=off, a
# typo in the flag, branches that must be skipped, a remote that refuses the
# delete, and the open-pull-request guard, which is dead code today (plan
# decision F5): the cases pin the exact output with and without an open PR.
#
# Each case builds a real repository with a bare repository as origin, so
# git's own fetch, push and branch commands run. gh is a stub that answers
# `pr list` from a file.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib-dr.sh"
dr_init

USAGE='usage: maintainer-repo {prune [--dry-run]|release-check|fixup <pr> [--dry-run]}'
PR_LIST_ARGV="$(cz_argv pr list --repo o/r --state open --json headRefName --jq '.[].headRefName')"
REMOTE_HDR="  remote branches merged into main:"
LOCAL_HDR="  local branches fully merged into main:"

prune_setup() {  # a repository with origin, the environment, and no open PRs
    dr_git_remote
    dr_repo_env
    cz_gh pr-list ""
}

# --- the command line ------------------------------------------------------------

case_cli_no_args() {
    prune_setup
    dr_repo
    cz_expect_rc 64
    cz_expect_stdout_empty
    cz_expect_stderr "$USAGE"
    cz_expect_gh_log
}
dr_case "usage: no subcommand prints the usage line on stderr and exits 64" case_cli_no_args

case_cli_unknown() {
    prune_setup
    dr_repo frobnicate
    cz_expect_rc 64
    cz_expect_stdout_empty
    cz_expect_stderr "$USAGE"
}
dr_case "usage: an unknown subcommand prints the usage line and exits 64" case_cli_unknown

case_cli_help() {
    prune_setup
    dr_repo --help
    cz_expect_rc 64
    cz_expect_stderr "$USAGE"
}
dr_case "usage: --help is an unknown subcommand and exits 64 (pins current behaviour)" case_cli_help

case_cli_empty() {
    prune_setup
    dr_repo ""
    cz_expect_rc 64
    cz_expect_stderr "$USAGE"
}
dr_case "usage: an empty subcommand prints the usage line and exits 64" case_cli_empty

case_cli_case() {
    prune_setup
    dr_repo Prune
    cz_expect_rc 64
    cz_expect_stderr "$USAGE"
}
dr_case "usage: subcommand names are case sensitive" case_cli_case

case_cli_no_profile() {
    dr_git_remote
    dr_repo prune
    cz_expect_rc 64
    cz_expect_stdout_empty
    cz_expect_stderr \
        "maintainer: no profile is deployed. Run ./install.sh, or set" \
        "            MAINTAINER_PROFILE, MAINTAINER_SLUG and MAINTAINER_REPO."
}
dr_case "profile: with no environment and no deployed profile the program exits 64 before reading the subcommand" case_cli_no_profile

case_cli_no_profile_usage() {
    dr_git_remote
    dr_repo frobnicate
    cz_expect_rc 64
    cz_expect_stderr_first "maintainer: no profile is deployed. Run ./install.sh, or set"
}
dr_case "profile: a bad subcommand without a profile reports the profile, not the usage line" case_cli_no_profile_usage

case_cli_profile_missing() {
    dr_git_remote
    mkdir -p "$DR_SHARE/profiles/magent"; : > "$DR_SHARE/profiles/magent/profile.env"
    cz_set MAINTAINER_PROFILE ghost
    dr_repo prune
    cz_expect_rc 64
    cz_expect_stderr "maintainer: no deployed profile named ghost (looked in $DR_SHARE/profiles)"
}
dr_case "profile: MAINTAINER_PROFILE naming a profile that is not deployed exits 64" case_cli_profile_missing

case_cli_two_profiles() {
    dr_git_remote
    mkdir -p "$DR_SHARE/profiles/a" "$DR_SHARE/profiles/b"; : > "$DR_SHARE/profiles/a/profile.env"; : > "$DR_SHARE/profiles/b/profile.env"
    dr_repo prune
    cz_expect_rc 64
    cz_expect_stderr \
        "maintainer: 2 profiles are deployed (a b)." \
        "            Set MAINTAINER_PROFILE to say which one you mean."
}
dr_case "profile: two deployed profiles and none named exits 64 on stderr" case_cli_two_profiles

case_cli_deployed_profile() {
    dr_git_remote
    mkdir -p "$DR_SHARE/profiles/magent"
    printf 'REPO_SLUG=o/r\nREPO_PATH=%s\nSTATE_DIR=%s\nGH_ACCOUNT=testuser\nPOST=on\n' "$CZ_REPO" "$CZ_STATE" > "$DR_SHARE/profiles/magent/profile.env"
    cz_gh pr-list ""
    dr_repo prune --dry-run
    cz_expect_rc 1
    cz_expect_stdout "$REMOTE_HDR" "    none" "$LOCAL_HDR" "    none"
    cz_expect_gh_log "$PR_LIST_ARGV"
}
dr_case "profile: with one deployed profile and no environment the repository and slug come from profile.env" case_cli_deployed_profile

# --- the dry run and the real run -----------------------------------------------
#
# Pins current behaviour: the last command of cmd_prune is
# `[ "$dry" = 0 ] && { ...; }`. On a dry run (or POST=off) the test is false and
# its status 1 becomes the program's exit code, so every dry run exits 1 with
# nothing on stderr. A real run exits 0.-------

prune_branches() {
    dr_branch feat-merged merged
    dr_branch feat-wip open
}

case_dry_run() {
    prune_setup; prune_branches
    dr_repo prune --dry-run
    cz_expect_rc 1
    cz_expect_stdout \
        "$REMOTE_HDR" \
        "    would delete feat-merged" \
        "$LOCAL_HDR" \
        "    would delete feat-merged"
    cz_expect_stderr_empty
    cz_expect_gh_log "$PR_LIST_ARGV"
    cz_check "remote branches after a dry run" "$(dr_ls_remote)" "feat-merged feat-wip main"
    cz_check "local branches after a dry run" "$(dr_local_branches)" "feat-merged feat-wip main"
}
dr_case "prune: --dry-run lists the merged remote and local branches, deletes nothing, and asks gh once for open PRs" case_dry_run

case_real_run() {
    prune_setup; prune_branches
    dr_repo prune
    cz_expect_rc 0
    cz_expect_stdout \
        "$REMOTE_HDR" \
        "    deleted feat-merged" \
        "$LOCAL_HDR" \
        "    deleted feat-merged" \
        "  worktrees and remote refs pruned"
    cz_expect_stderr_empty
    cz_check "remote branches after a real run" "$(dr_ls_remote)" "feat-wip main"
    cz_check "local branches after a real run" "$(dr_local_branches)" "feat-wip main"
}
dr_case "prune: a real run deletes the merged branch on the remote and locally, keeps the unmerged one, and prints the pruned line" case_real_run

case_nothing_dry() {
    prune_setup
    dr_repo prune --dry-run
    cz_expect_rc 1
    cz_expect_stdout "$REMOTE_HDR" "    none" "$LOCAL_HDR" "    none"
}
dr_case "prune: with nothing merged both sections say 'none' (dry run)" case_nothing_dry

case_nothing_real() {
    prune_setup
    dr_repo prune
    cz_expect_rc 0
    cz_expect_stdout "$REMOTE_HDR" "    none" "$LOCAL_HDR" "    none" "  worktrees and remote refs pruned"
}
dr_case "prune: with nothing merged a real run still prints the pruned line" case_nothing_real

case_post_off() {
    prune_setup; prune_branches
    cz_set MAINTAINER_POST off
    dr_repo prune
    cz_expect_rc 1
    cz_expect_stdout \
        "  POST=off: listing only, nothing will be deleted" \
        "$REMOTE_HDR" \
        "    would delete feat-merged" \
        "$LOCAL_HDR" \
        "    would delete feat-merged"
    cz_check "remote branches under POST=off" "$(dr_ls_remote)" "feat-merged feat-wip main"
    cz_check "local branches under POST=off" "$(dr_local_branches)" "feat-merged feat-wip main"
}
dr_case "prune: MAINTAINER_POST=off turns a real run into a listing, says so first, and prints no pruned line" case_post_off

case_post_off_dry() {
    prune_setup; prune_branches
    cz_set MAINTAINER_POST off
    dr_repo prune --dry-run
    cz_expect_rc 1
    cz_expect_stdout_has "  POST=off: listing only, nothing will be deleted"
    cz_expect_stdout_has "    would delete feat-merged"
}
dr_case "prune: POST=off with --dry-run prints the POST=off line too" case_post_off_dry

case_post_uppercase() {
    prune_setup; prune_branches
    cz_set MAINTAINER_POST OFF
    dr_repo prune
    cz_expect_stdout_has "    deleted feat-merged"
    cz_check "remote branches" "$(dr_ls_remote)" "feat-wip main"
}
dr_case "prune: only the exact word 'off' is a rehearsal, so POST=OFF deletes" case_post_uppercase

# Pins current behaviour: with no MAINTAINER_POST in the environment the program
# assumes posting is on, so a real run deletes.
case_post_unset() {
    prune_setup; prune_branches
    cz_unset MAINTAINER_POST
    dr_repo prune
    cz_expect_rc 0
    cz_expect_stdout_has "    deleted feat-merged"
    cz_check "remote branches" "$(dr_ls_remote)" "feat-wip main"
}
dr_case "prune: with MAINTAINER_POST unset the program deletes for real (posting defaults to on)" case_post_unset

# Pins current behaviour: only a first argument equal to --dry-run is a dry run.
# A typo or a flag in the second place falls through to a real delete.
case_flag_typo() {
    prune_setup; prune_branches
    dr_repo prune --dryrun
    cz_expect_rc 0
    cz_expect_stdout_has "    deleted feat-merged"
    cz_check "remote branches after a mistyped flag" "$(dr_ls_remote)" "feat-wip main"
}
dr_case "prune: a mistyped --dryrun deletes for real (pins current behaviour)" case_flag_typo

case_flag_second() {
    prune_setup; prune_branches
    dr_repo prune --verbose --dry-run
    cz_expect_stdout_has "    deleted feat-merged"
    cz_check "remote branches" "$(dr_ls_remote)" "feat-wip main"
}
dr_case "prune: --dry-run as the second argument is ignored and the prune is real (pins current behaviour)" case_flag_second

# --- the open-PR guard (plan decision F5) ------------------------------------------------

# Pins current behaviour, see plan decision F5. The guard builds `open_heads` as
# "feat-merged|" and tests it with `grep -qx -F`, which compares whole lines, so
# no branch name can equal "feat-merged|". The guard never fires, and a branch
# with an open pull request is listed as deletable.
case_open_pr_dry() {
    prune_setup; prune_branches
    cz_gh pr-list "feat-merged"
    dr_repo prune --dry-run
    cz_expect_rc 1
    cz_expect_stdout \
        "$REMOTE_HDR" \
        "    would delete feat-merged" \
        "$LOCAL_HDR" \
        "    would delete feat-merged"
    cz_expect_stdout_lacks_keep
}
cz_expect_stdout_lacks_keep() { cz_expect_lacks stdout "keep "; cz_expect_lacks stdout "(open PR)"; }
dr_case "prune: a branch with an open PR is still listed as 'would delete' because the guard is dead code (pins plan decision F5)" case_open_pr_dry

case_open_pr_real() {
    prune_setup; prune_branches
    cz_gh pr-list "feat-merged"
    dr_repo prune
    cz_expect_rc 0
    cz_expect_stdout_has "    deleted feat-merged"
    cz_check "remote branches" "$(dr_ls_remote)" "feat-wip main"
    cz_expect_stdout_lacks_keep
}
dr_case "prune: a real run deletes the remote branch of an open PR (pins plan decision F5)" case_open_pr_real

case_open_pr_two() {
    prune_setup; prune_branches
    cz_gh pr-list "$(printf 'feat-merged\nfeat-wip')"
    dr_repo prune --dry-run
    cz_expect_rc 1
    cz_expect_stdout "$REMOTE_HDR" "    would delete feat-merged" "$LOCAL_HDR" "    would delete feat-merged"
}
dr_case "prune: two open PR heads change nothing either (pins plan decision F5)" case_open_pr_two

case_open_pr_fails() {
    prune_setup; prune_branches
    cz_gh pr-list "" 1
    dr_repo prune --dry-run
    cz_expect_rc 1
    cz_expect_stdout "$REMOTE_HDR" "    would delete feat-merged" "$LOCAL_HDR" "    would delete feat-merged"
    cz_expect_stderr_empty
}
dr_case "prune: a failing gh pr list is ignored and prints nothing" case_open_pr_fails

# --- which branches are skipped ---------------------------------------------------------------

case_skip_names() {
    prune_setup
    dr_branch master merged
    cz_git remote set-head origin main >/dev/null
    dr_repo prune --dry-run
    cz_expect_rc 1
    cz_expect_stdout "$REMOTE_HDR" "    none" "$LOCAL_HDR" "    none"
}
dr_case "prune: main, master and origin/HEAD are never candidates, remote or local" case_skip_names

case_slash_names() {
    prune_setup
    dr_branch feature/login merged
    dr_repo prune --dry-run
    cz_expect_rc 1
    cz_expect_stdout "$REMOTE_HDR" "    would delete feature/login" "$LOCAL_HDR" "    would delete feature/login"
}
dr_case "prune: a branch name with a slash is listed whole" case_slash_names

case_local_only() {
    prune_setup
    cz_git branch local-only
    dr_repo prune --dry-run
    cz_expect_rc 1
    cz_expect_stdout "$REMOTE_HDR" "    none" "$LOCAL_HDR" "    would delete local-only"
}
dr_case "prune: a merged local branch with no remote branch is listed in the local section only" case_local_only

case_unmerged_only() {
    prune_setup
    dr_branch feat-wip open
    dr_repo prune
    cz_expect_stdout "$REMOTE_HDR" "    none" "$LOCAL_HDR" "    none" "  worktrees and remote refs pruned"
    cz_check "remote branches" "$(dr_ls_remote)" "feat-wip main"
}
dr_case "prune: an unmerged branch is skipped silently" case_unmerged_only

# --- failures ---------------------------------------------------------------------------------

case_protected() {
    prune_setup; prune_branches
    cat > "$DR_ORIGIN/hooks/pre-receive" <<'HOOK'
#!/bin/sh
while read old new ref; do
    case "$new" in 0000000000000000000000000000000000000000) exit 1 ;; esac
done
exit 0
HOOK
    chmod +x "$DR_ORIGIN/hooks/pre-receive"
    dr_repo prune
    cz_expect_rc 0
    cz_expect_stdout \
        "$REMOTE_HDR" \
        "    could not delete feat-merged (protected or already gone)" \
        "$LOCAL_HDR" \
        "    deleted feat-merged" \
        "  worktrees and remote refs pruned"
    cz_check "remote branches" "$(dr_ls_remote)" "feat-merged feat-wip main"
}
dr_case "prune: a remote that refuses the delete is reported per branch, the local branch is still deleted, exit 0" case_protected

# Pins current behaviour: a merged branch that is checked out cannot be deleted,
# `git branch -D` fails, and nothing is printed for it. It was counted, so the
# section does not say 'none' either.
case_checked_out() {
    prune_setup; prune_branches
    cz_git checkout -q feat-merged
    dr_repo prune
    cz_expect_rc 0
    cz_expect_stdout \
        "$REMOTE_HDR" \
        "    deleted feat-merged" \
        "$LOCAL_HDR" \
        "  worktrees and remote refs pruned"
    cz_check "local branches" "$(dr_local_branches)" "feat-merged feat-wip main"
}
dr_case "prune: a merged branch that is checked out is silently left, and the section is empty rather than 'none' (pins current behaviour)" case_checked_out

case_fetch_fails() {
    prune_setup
    cz_git remote set-url origin "$CZ_CASE/not-a-repo"
    dr_repo prune --dry-run
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr_has "maintainer-repo: fetch failed"
    cz_expect_gh_log
}
dr_case "prune: a fetch that fails stops with 'fetch failed', exit 1, before any listing or gh call" case_fetch_fails

case_no_repo() {
    prune_setup
    cz_set MAINTAINER_REPO "$CZ_CASE/nowhere"
    dr_repo prune
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr_has "maintainer-repo: no repo at $CZ_CASE/nowhere"
}
dr_case "prune: a repository path that does not exist exits 1 with 'no repo at'" case_no_repo

case_no_repo_post_off() {
    prune_setup
    cz_set MAINTAINER_REPO "$CZ_CASE/nowhere"
    cz_set MAINTAINER_POST off
    dr_repo prune
    cz_expect_rc 1
    cz_expect_stdout "  POST=off: listing only, nothing will be deleted"
    cz_expect_stderr_has "maintainer-repo: no repo at $CZ_CASE/nowhere"
}
dr_case "prune: the POST=off line is printed before the repository is looked for" case_no_repo_post_off

# `git branch -D`, not -d: a branch merged into origin/main is deleted even when the
# local main has not caught up and git itself would call the branch unmerged.
case_local_main_behind() {
    prune_setup
    dr_branch feat-merged merged
    cz_git reset -q --hard HEAD~1
    dr_repo prune
    cz_expect_rc 0
    cz_expect_stdout \
        "$REMOTE_HDR" \
        "    deleted feat-merged" \
        "$LOCAL_HDR" \
        "    deleted feat-merged" \
        "  worktrees and remote refs pruned"
    cz_check "local branches" "$(dr_local_branches)" "main"
}
dr_case "prune: a local branch merged into origin/main is deleted even when the local main is behind it" case_local_main_behind

dr_worktrees() { cz_git worktree list --porcelain | grep -c '^worktree '; }

case_stale_worktree() {
    prune_setup
    cz_git worktree add -q --detach "$CZ_CASE/wt" || exit 2
    rm -rf "$CZ_CASE/wt"
    dr_repo prune
    cz_expect_rc 0
    cz_expect_stdout_has "  worktrees and remote refs pruned"
    cz_check "worktree records after a real run" "$(dr_worktrees)" "1"
}
dr_case "prune: a real run forgets a worktree whose directory is gone" case_stale_worktree

case_stale_worktree_dry() {
    prune_setup
    cz_git worktree add -q --detach "$CZ_CASE/wt" || exit 2
    rm -rf "$CZ_CASE/wt"
    dr_repo prune --dry-run
    cz_expect_rc 1
    cz_check "worktree records after a dry run" "$(dr_worktrees)" "2"
}
dr_case "prune: a dry run leaves the record of a vanished worktree alone" case_stale_worktree_dry

cz_finish
