#!/usr/bin/env bash
# update with every condition met and POST=off prints what it would run and changes nothing on GitHub.
mx_merge_env
mx_env MAINTAINER_POST off
mx_git_repo "$MX_REPO"
mx_commit "$MX_REPO" "base" README.md "base"
mx_pr_origin 5
mx_update_gh 5 BEHIND APPROVED alice
mx_receipt 5 1111111111111111111111111111111111111111 observed "guard mutated, went red"
mx_run bin/maintainer-merge update 5
