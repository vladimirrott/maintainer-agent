#!/usr/bin/env bash
# show prints a signed receipt exactly as it sits on disk.
mx_merge_env
mx_receipt 7 abcdef1234 observed "guard mutated, went red"
mx_run bin/maintainer-merge show 7
