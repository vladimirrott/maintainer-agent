#!/usr/bin/env bash
# release-check warns that an empty Unreleased section leaves the verdict resting on file counts.
mx_release_fixture
mx_commit "$MX_REPO" "fix(lib): handle a blank line" lib/helper "fixed"
mx_release_push
mx_run bin/maintainer-repo release-check
