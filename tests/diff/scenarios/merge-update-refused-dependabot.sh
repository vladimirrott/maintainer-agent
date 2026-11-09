#!/usr/bin/env bash
# update refuses a BEHIND Dependabot branch and points at maintainer deps rebase.
mx_merge_env
mx_update_gh 5 BEHIND APPROVED "app/dependabot"
mx_run bin/maintainer-merge update 5
