#!/usr/bin/env bash
# show of a receipt file that is not JSON: the program reports it and the exit code is data.
mx_merge_env
mkdir -p "$MX_STATE/receipts"
printf 'this is not json\n' > "$MX_STATE/receipts/9.json"
mx_run bin/maintainer-merge show 9
