#!/usr/bin/env bash
# verify names a suite the profile does not have and refuses before any build.
mx_merge_env
mx_stub gh <<'STUB'
case "$*" in
  *'auth switch'*) exit 0 ;;
  *'api user'*) echo testuser ;;
  *'--json files'*) echo crates/x/src/lib.rs ;;
esac
STUB
mx_run bin/maintainer-merge verify 5 abcdef1234 some_test 's/a/b/' nosuchsuite
