#!/usr/bin/env bash
# run-lease writes the run record with the caller's pid and the epoch second it started.
# The pid is this scenario shell's own, so it differs on every recording.
mx_merge_env
mx_run bin/maintainer run-lease review "$$"
