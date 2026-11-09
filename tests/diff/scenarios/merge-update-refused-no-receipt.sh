#!/usr/bin/env bash
# update refuses an approved BEHIND pull request that has no verification receipt.
mx_merge_env
mx_update_gh 5 BEHIND APPROVED alice
mx_run bin/maintainer-merge update 5
