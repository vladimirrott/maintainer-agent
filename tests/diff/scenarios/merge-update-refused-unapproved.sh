#!/usr/bin/env bash
# update refuses a BEHIND pull request whose reviewDecision is not APPROVED.
mx_merge_env
mx_update_gh 5 BEHIND REVIEW_REQUIRED alice
mx_run bin/maintainer-merge update 5
