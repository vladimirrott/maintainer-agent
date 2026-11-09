#!/usr/bin/env bash
# show with no argument lists every receipt as "pr: head proof".
mx_merge_env
mx_receipt 7 abcdef1234 observed "guard mutated, went red"
mx_receipt 31 0123456789ab dependency "lockfile bump, every pin checked"
mx_run bin/maintainer-merge show
