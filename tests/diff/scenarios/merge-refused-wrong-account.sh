#!/usr/bin/env bash
# merge refuses before reading any receipt when gh answers as another account.
mx_merge_env
mx_receipt 12 abcdef1234 observed "guard mutated, went red"
mx_stub gh <<'STUB'
case "$*" in
  *'auth switch'*) exit 0 ;;
  *'api user'*) echo wronguser ;;
esac
STUB
mx_run bin/maintainer-merge merge 12
