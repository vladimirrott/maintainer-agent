#!/usr/bin/env bash
# A real run in a tree with no rendered settings file fails, notifies, and still writes
# a log whose name carries the minute the run started.
mx_git_repo "$MX_REPO"
mx_commit "$MX_REPO" "init" README.md "checkout"
mx_env MAINTAINER_REPO_PATH "$MX_REPO"
mx_env MAINTAINER_STATE_DIR "$MX_STATE"
mx_env MAINTAINER_POST on
mx_run lib/run.sh magent review
