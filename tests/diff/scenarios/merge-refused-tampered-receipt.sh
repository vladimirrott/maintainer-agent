#!/usr/bin/env bash
# merge refuses a receipt whose proof text was edited after it was signed.
mx_merge_env
mx_receipt 12 abcdef1234 observed "guard mutated, went red"
sed -i 's/went red/stayed green/' "$MX_STATE/receipts/12.json"
mx_stub gh <<'STUB'
case "$*" in
  *'auth switch'*) exit 0 ;;
  *'api user'*) echo testuser ;;
esac
STUB
mx_run bin/maintainer-merge merge 12
