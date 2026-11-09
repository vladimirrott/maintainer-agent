#!/usr/bin/env bash
# release-check refuses with exit 1 and "no tags" when the repository has no tag at all.
mx_release_fixture
git -C "$MX_REPO" tag -d v0.1.0 >/dev/null
git -C "$MX_REPO" push -q origin main
mx_run bin/maintainer-repo release-check
