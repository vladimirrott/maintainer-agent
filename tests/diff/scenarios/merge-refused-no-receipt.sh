#!/usr/bin/env bash
# merge under the right account refuses when no receipt exists for the PR.
mx_merge_env
mx_stub gh <<'STUB'
case "$*" in
  *'auth switch'*) exit 0 ;;
  *'api user'*) echo testuser ;;
esac
STUB
mx_run bin/maintainer-merge merge 12
