#!/usr/bin/env bash
# release-check calls a docs-only history optional and moves the last digit.
mx_release_fixture
mx_commit "$MX_REPO" "docs: explain the receipt" docs/receipt.md "words"
mx_release_push
mx_run bin/maintainer-repo release-check
