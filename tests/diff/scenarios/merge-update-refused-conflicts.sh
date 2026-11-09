#!/usr/bin/env bash
# update refuses a pull request whose mergeStateStatus is DIRTY: conflicts are the author's.
mx_merge_env
mx_update_gh 5 DIRTY APPROVED alice
mx_run bin/maintainer-merge update 5
