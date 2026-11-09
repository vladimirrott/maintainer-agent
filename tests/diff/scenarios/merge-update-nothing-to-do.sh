#!/usr/bin/env bash
# update on a CLEAN pull request says there is nothing to update and exits 0.
mx_merge_env
mx_update_gh 5 CLEAN APPROVED alice
mx_run bin/maintainer-merge update 5
