#!/usr/bin/env bash
# show prints a receipt whose signature no longer matches its body exactly as it sits on disk.
mx_merge_env
mx_receipt 8 abcdef1234 observed "guard mutated, went red"
sed -i 's/guard mutated/guard unmutated/' "$MX_STATE/receipts/8.json"
mx_run bin/maintainer-merge show 8
