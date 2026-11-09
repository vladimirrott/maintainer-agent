#!/usr/bin/env bash
# update refuses a fork branch whose author did not allow maintainer edits.
mx_merge_env
mx_git_repo "$MX_REPO"
mx_commit "$MX_REPO" "base" README.md "base"
mx_pr_origin 5
export MX_U_CROSS=true MX_U_MODIFY=false
mx_update_gh 5 BEHIND APPROVED alice
mx_receipt 5 1111111111111111111111111111111111111111 observed "guard mutated, went red"
mx_run bin/maintainer-merge update 5
