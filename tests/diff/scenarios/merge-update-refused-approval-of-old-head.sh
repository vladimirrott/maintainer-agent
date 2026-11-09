#!/usr/bin/env bash
# update refuses when this account's approval names an older commit than the head.
mx_merge_env
export MX_U_REVIEW="APPROVED testuser 2222222222222222222222222222222222222222"
mx_update_gh 5 BEHIND APPROVED alice
mx_run bin/maintainer-merge update 5
